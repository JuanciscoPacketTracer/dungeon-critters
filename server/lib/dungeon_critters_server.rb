# frozen_string_literal: true

require 'digest'
require 'base64'
require 'json'
require 'openssl'
require 'securerandom'
require 'time'
require 'uri'

module DungeonCritters
  module Server
    OUTBOX_REQUIRED_ENV = %w[
      DATABASE_URL RESEND_API_KEY RESEND_FROM_EMAIL PUBLIC_API_URL
      VERIFICATION_TOKEN_SECRETS VERIFICATION_TOKEN_KEY_VERSION
    ].freeze

    def self.require_env!(name, env: ENV)
      value = env[name].to_s
      raise ConfigurationError, "#{name} is required" if value.empty?

      value
    end

    ACCESS_TOKEN_TTL = 15 * 60
    REFRESH_TOKEN_TTL = 30 * 24 * 60 * 60
    VERIFICATION_TTL = 24 * 60 * 60
    OUTBOX_CLAIM_TTL = 5 * 60
    MAX_SESSIONS = 5

    class ValidationError < StandardError; end
    class AuthenticationError < StandardError; end
    class ConflictError < StandardError; end
    class ConfigurationError < StandardError; end
    class OutboxPersistenceError < StandardError; end
    class OutboxLeaseLostError < StandardError; end
    class PayloadTooLargeError < StandardError; end
    MAX_BODY_BYTES = 64 * 1024

    User = Struct.new(:id, :email, :password_digest, :verified_at, :created_at, keyword_init: true)
    Session = Struct.new(:id, :user_id, :access_token_digest, :refresh_token_digest,
                         :access_expires_at, :refresh_expires_at, :revoked_at, :created_at, keyword_init: true)
    Verification = Struct.new(:user_id, :token_digest, :expires_at, :used_at, keyword_init: true)
    OutboxMessage = Struct.new(:id, :email, :user_id, :token_digest, :nonce, :expires_at, :key_version,
                               :sent_at, :claimed_at, :claim_token, :attempts, :next_attempt_at, :terminal_at,
                               :created_at, keyword_init: true)

    module TokenCodec
      module_function

      def issue
        SecureRandom.urlsafe_base64(32)
      end

      def digest(token)
        Digest::SHA256.hexdigest(token.to_s)
      end
    end

    class VerificationTokenCodec
      def initialize(secrets:, current_version:)
        @secrets = secrets.transform_keys(&:to_s)
        @current_version = current_version.to_s
        raise ConfigurationError if @secrets.empty? || !@secrets.key?(@current_version)
      end

      def self.from_env(environment: ENV.fetch('RACK_ENV', 'development'))
        configured = ENV['VERIFICATION_TOKEN_SECRETS'].to_s
        if configured.empty?
          raise ConfigurationError if environment == 'production'

          return new(secrets: { 'development' => 'development-only-secret' }, current_version: 'development')
        end

        secrets = JSON.parse(configured)
        new(secrets: secrets, current_version: ENV.fetch('VERIFICATION_TOKEN_KEY_VERSION'))
      rescue JSON::ParserError, KeyError, TypeError
        raise ConfigurationError
      end

      def current_version
        @current_version
      end

      def issue(user_id:, nonce:, expires_at:, key_version: @current_version)
        secret = @secrets.fetch(key_version.to_s)
        payload = [key_version, user_id, nonce, expires_at.to_i].join('|')
        Base64.urlsafe_encode64(OpenSSL::HMAC.digest('SHA256', secret, payload), padding: false)
      rescue KeyError
        raise ConfigurationError
      end
    end

    class PasswordHasher
      PARAMETERS = { m_cost: 19_456, t_cost: 2, parallelism: 1 }.freeze

      def initialize(implementation = nil)
        @implementation = implementation || load_argon2id
        @dummy_digest = @implementation::Password.create('invalid login password', **PARAMETERS).to_s
      end

      def digest(password)
        raise ValidationError, 'invalid password' unless password.is_a?(String) && password.length >= 12

        @implementation::Password.create(password, **PARAMETERS).to_s
      end

      def verify(password, digest)
        @implementation::Password.new(digest).is_password?(password)
      rescue StandardError
        false
      end

      def dummy_digest
        @dummy_digest
      end

      private

      def load_argon2id
        require 'argon2id'
        Argon2id
      rescue LoadError => e
        raise ConfigurationError, "argon2id is required: #{e.message}"
      end
    end

    class InMemoryStore
      attr_reader :users, :sessions, :verifications, :outbox

      def initialize
        @users = {}
        @sessions = {}
        @verifications = {}
        @outbox = {}
        @mutex = Mutex.new
      end

      def transaction
        @mutex.synchronize do
          snapshot = Marshal.dump([@users, @sessions, @verifications, @outbox])
          yield self
        rescue StandardError
          @users, @sessions, @verifications, @outbox = Marshal.load(snapshot)
          raise
        end
      end
    end

    class PostgresStore < InMemoryStore
      REQUIRED_SCHEMA_COLUMNS = {
        'users' => %w[id email password_digest verified_at created_at],
        'email_verifications' => %w[token_digest user_id expires_at used_at],
        'email_outbox' => %w[id email user_id token_digest nonce expires_at key_version sent_at claimed_at claim_token
                              attempts next_attempt_at terminal_at created_at],
        'sessions' => %w[id user_id access_token_digest refresh_token_digest access_expires_at refresh_expires_at
                          revoked_at created_at]
      }.freeze
      REQUIRED_OUTBOX_COLUMNS = %w[
        id email user_id token_digest nonce expires_at key_version sent_at claimed_at claim_token attempts
        next_attempt_at terminal_at created_at
      ].freeze

      def self.validate_outbox_columns(columns)
        names = columns.map(&:to_s)
        if names.empty?
          raise ConfigurationError, 'email_outbox is missing; apply server/db/001_sessions.sql before starting'
        end
        if names.include?('token')
          raise ConfigurationError, 'email_outbox has legacy token column; do not start until the schema is migrated'
        end

        missing = REQUIRED_OUTBOX_COLUMNS - names
        return if missing.empty?

        raise ConfigurationError, "email_outbox schema is incomplete; missing: #{missing.join(', ')}"
      end

      def self.validate_schema(columns_by_table)
        names_by_table = columns_by_table.transform_values { |columns| columns.map(&:to_s) }
        missing_tables = REQUIRED_SCHEMA_COLUMNS.keys - names_by_table.keys
        unless missing_tables.empty?
          raise ConfigurationError, "database schema is missing tables: #{missing_tables.join(', ')}"
        end
        if names_by_table['email_outbox'].include?('token')
          raise ConfigurationError, 'email_outbox has legacy token column; do not start until the schema is migrated'
        end

        missing_columns = REQUIRED_SCHEMA_COLUMNS.each_with_object([]) do |(table, required), missing|
          absent = required - names_by_table.fetch(table)
          missing << "#{table}.#{absent.join(',')}" unless absent.empty?
        end
        return if missing_columns.empty?

        raise ConfigurationError, "database schema is incomplete; missing: #{missing_columns.join('; ')}"
      end

      def initialize(url)
        require 'pg'
        @connection = PG.connect(url)
        super()
        validate_outbox_schema
        load_rows
      rescue LoadError => e
        raise ConfigurationError, "pg is required: #{e.message}"
      end

      def transaction
        @connection.transaction do
          @connection.exec('SELECT pg_advisory_xact_lock(23)')
          load_rows
          super { yield self }.tap { persist }
        end
      end

      private

      def validate_outbox_schema
        rows = @connection.exec(
          "SELECT table_name, column_name FROM information_schema.columns " \
          "WHERE table_schema = current_schema() AND table_name IN " \
          "('users', 'email_verifications', 'email_outbox', 'sessions')"
        )
        columns_by_table = rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, columns|
          columns[row['table_name']] << row['column_name']
        end
        self.class.validate_schema(columns_by_table)
      end

      def load_rows
        @users.clear
        @sessions.clear
        @verifications.clear
        @outbox.clear
        @connection.exec('SELECT id, email, password_digest, verified_at, created_at FROM users').each do |row|
          @users[row['id']] = User.new(id: row['id'], email: row['email'], password_digest: row['password_digest'],
                                       verified_at: time(row['verified_at']), created_at: time(row['created_at']))
        end
        @connection.exec('SELECT id, user_id, access_token_digest, refresh_token_digest, access_expires_at, refresh_expires_at, revoked_at, created_at FROM sessions').each do |row|
          @sessions[row['id']] = Session.new(id: row['id'], user_id: row['user_id'],
            access_token_digest: row['access_token_digest'], refresh_token_digest: row['refresh_token_digest'],
            access_expires_at: time(row['access_expires_at']), refresh_expires_at: time(row['refresh_expires_at']),
            revoked_at: time(row['revoked_at']), created_at: time(row['created_at']))
        end
        @connection.exec('SELECT user_id, token_digest, expires_at, used_at FROM email_verifications').each do |row|
          @verifications[row['token_digest']] = Verification.new(user_id: row['user_id'],
            token_digest: row['token_digest'], expires_at: time(row['expires_at']), used_at: time(row['used_at']))
        end
        @connection.exec('SELECT id, email, user_id, token_digest, nonce, expires_at, key_version, sent_at, claimed_at,
                                 claim_token, attempts, next_attempt_at, terminal_at, created_at FROM email_outbox').each do |row|
          @outbox[row['id']] = OutboxMessage.new(id: row['id'], email: row['email'], user_id: row['user_id'],
            token_digest: row['token_digest'], nonce: row['nonce'], expires_at: time(row['expires_at']),
            key_version: row['key_version'], sent_at: time(row['sent_at']), claimed_at: time(row['claimed_at']),
            claim_token: row['claim_token'], attempts: row['attempts'].to_i, next_attempt_at: time(row['next_attempt_at']),
            terminal_at: time(row['terminal_at']), created_at: time(row['created_at']))
        end
      end

      def persist
        @users.each_value do |user|
          @connection.exec_params(
            'INSERT INTO users (id, email, password_digest, verified_at, created_at) VALUES ($1,$2,$3,$4,$5)
             ON CONFLICT (id) DO UPDATE SET email=$2, password_digest=$3, verified_at=$4',
            [user.id, user.email, user.password_digest, user.verified_at, user.created_at]
          )
        end
        @sessions.each_value do |session|
          @connection.exec_params(
            'INSERT INTO sessions (id, user_id, access_token_digest, refresh_token_digest, access_expires_at,
             refresh_expires_at, revoked_at, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
             ON CONFLICT (id) DO UPDATE SET revoked_at=$7, access_expires_at=$5, refresh_expires_at=$6',
            [session.id, session.user_id, session.access_token_digest, session.refresh_token_digest,
             session.access_expires_at, session.refresh_expires_at, session.revoked_at, session.created_at]
          )
        end
        @verifications.each_value do |verification|
          @connection.exec_params(
            'INSERT INTO email_verifications (token_digest, user_id, expires_at, used_at) VALUES ($1,$2,$3,$4)
             ON CONFLICT (token_digest) DO UPDATE SET used_at=$4',
            [verification.token_digest, verification.user_id, verification.expires_at, verification.used_at]
          )
        end
        @outbox.each_value do |message|
          @connection.exec_params(
            'INSERT INTO email_outbox (id, email, user_id, token_digest, nonce, expires_at, key_version, sent_at,
             claimed_at, claim_token, attempts, next_attempt_at, terminal_at, created_at)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
             ON CONFLICT (id) DO UPDATE SET sent_at=$8, claimed_at=$9, claim_token=$10, attempts=$11,
             next_attempt_at=$12, terminal_at=$13',
            [message.id, message.email, message.user_id, message.token_digest, message.nonce, message.expires_at,
             message.key_version, message.sent_at, message.claimed_at, message.claim_token, message.attempts,
             message.next_attempt_at, message.terminal_at, message.created_at]
          )
        end
      end

      def time(value)
        value && Time.parse(value.to_s)
      end
    end

    class ResendMailer
      def initialize(api_key: ENV['RESEND_API_KEY'], from: ENV['RESEND_FROM_EMAIL'], client: nil,
                     public_api_url: ENV['PUBLIC_API_URL'], environment: ENV.fetch('RACK_ENV', 'development'))
        @api_key = api_key
        @from = from
        @client = client
        @public_api_url = public_api_url
        @environment = environment
        @public_api_base = validated_public_api_base
      end

      def send_verification(email:, token:)
        validate_configuration!

        payload = {
          from: @from,
          to: [email],
          subject: 'Verify your Dungeon Critters account',
          html: "<p><a href=\"#{verification_url(token)}\">Verify email</a></p>"
        }
        return @client.call(payload) if @client

        require 'resend'
        Resend.api_key = @api_key
        Resend::Emails.send(payload)
      end

      def validate_configuration!
        return if @client
        raise ConfigurationError, 'Resend is not configured' if @api_key.to_s.empty? || @from.to_s.empty?
      end

      private

      def verification_url(token)
        "#{@public_api_base}/v1/accounts/verify-email#token=#{URI.encode_www_form_component(token)}"
      end

      def validated_public_api_base
        uri = URI.parse(@public_api_url.to_s.empty? ? 'http://localhost:9292' : @public_api_url)
        if @environment == 'production'
          raise ConfigurationError unless uri.scheme == 'https' && uri.host && uri.userinfo.nil?
        elsif uri.host.nil? || !%w[http https].include?(uri.scheme)
          raise ConfigurationError
        end
        uri.to_s.sub(%r{/+\z}, '')
      rescue URI::InvalidURIError
        raise ConfigurationError
      end
    end

    class OutboxDispatcher
      def initialize(store:, mailer:, verification_tokens:, clock: -> { Time.now.utc })
        @store = store
        @mailer = mailer
        @verification_tokens = verification_tokens
        @clock = clock
      end

      def validate_configuration!
        @mailer.validate_configuration! if @mailer.respond_to?(:validate_configuration!)
      end

      def deliver_pending(limit: 100, max_attempts: nil, on_failure: nil)
        delivered = 0
        limit.times do
          message = claim_pending(max_attempts: max_attempts)
          break unless message

          begin
            token = @verification_tokens.issue(
              user_id: message.user_id, nonce: message.nonce, expires_at: message.expires_at,
              key_version: message.key_version
            )
            @mailer.send_verification(email: message.email, token: token)
          rescue StandardError
            handle_failure(message, on_failure)
            raise
          end

          begin
            mark_delivered(message)
            delivered += 1
          rescue OutboxLeaseLostError
            raise
          rescue StandardError => error
            raise OutboxPersistenceError, "unable to persist delivered outbox message #{message.id}: #{error.class}"
          end
        end
        delivered
      end

      private

      def claim_pending(max_attempts:)
        @store.transaction do
          now = @clock.call
          pending = @store.outbox.values.find do |candidate|
            next false unless candidate.sent_at.nil? &&
                              candidate.terminal_at.nil? &&
                              (candidate.next_attempt_at.nil? || candidate.next_attempt_at <= now) &&
                              (candidate.claimed_at.nil? || candidate.claimed_at <= now - OUTBOX_CLAIM_TTL)

            if max_attempts && candidate.attempts.to_i >= max_attempts
              candidate.terminal_at = now
              candidate.next_attempt_at = nil
              candidate.claimed_at = nil
              candidate.claim_token = nil
              false
            else
              true
            end
          end
          pending&.tap do |candidate|
            candidate.attempts = candidate.attempts.to_i + 1
            candidate.claimed_at = now
            candidate.claim_token = SecureRandom.uuid
          end
        end
      rescue StandardError => error
        raise OutboxPersistenceError, "unable to claim outbox message: #{error.class}"
      end

      def mark_delivered(message)
        @store.transaction do
          current = @store.outbox.fetch(message.id)
          unless current.claim_token == message.claim_token && current.sent_at.nil?
            raise OutboxLeaseLostError, "outbox lease lost for #{message.id}"
          end

          current.sent_at = @clock.call
          current.claimed_at = nil
          current.claim_token = nil
          current.next_attempt_at = nil
        end
      end

      def handle_failure(message, on_failure)
        if on_failure
          on_failure.call(message)
        else
          release_claim(message)
        end
      rescue OutboxPersistenceError
        raise
      rescue OutboxLeaseLostError
        raise
      rescue StandardError => error
        raise OutboxPersistenceError, "unable to persist failed outbox message #{message.id}: #{error.class}"
      end

      def release_claim(message)
        @store.transaction do
          current = @store.outbox.fetch(message.id)
          if current.claim_token == message.claim_token
            current.claimed_at = nil
            current.claim_token = nil
          end
        end
      end
    end

    class OutboxWorker
      DEFAULT_POLL_INTERVAL = 5
      DEFAULT_BACKOFF_BASE = 1
      DEFAULT_BACKOFF_MAX = 60
      DEFAULT_MAX_ATTEMPTS = 5

      def initialize(store:, dispatcher:, poll_interval: DEFAULT_POLL_INTERVAL, backoff_base: DEFAULT_BACKOFF_BASE,
                     backoff_max: DEFAULT_BACKOFF_MAX, max_attempts: DEFAULT_MAX_ATTEMPTS,
                     clock: -> { Time.now.utc },
                     logger: $stderr, sleeper: ->(seconds) { sleep(seconds) })
        @store = store
        @dispatcher = dispatcher
        @poll_interval = positive_number(poll_interval, 'poll interval')
        @backoff_base = positive_number(backoff_base, 'backoff base')
        @backoff_max = positive_number(backoff_max, 'backoff maximum')
        @max_attempts = Integer(max_attempts)
        raise ConfigurationError, 'max attempts must be positive' unless @max_attempts.positive?

        @clock = clock
        @logger = logger
        @sleeper = sleeper
        @next_wait = nil
        @dispatcher.validate_configuration!
      end

      def run_once
        @next_wait = nil
        @dispatcher.deliver_pending(
          max_attempts: @max_attempts,
          on_failure: ->(message) { schedule_failure(message) }
        )
      rescue OutboxLeaseLostError
        log('outbox delivery outcome uncertain; lease ownership changed before acknowledgement')
        0
      rescue OutboxPersistenceError => error
        log("outbox persistence failed error=#{error.class}")
        0
      rescue StandardError => error
        log("outbox delivery failed error=#{error.class}")
        0
      end

      def run(stop: -> { false })
        until stop.call
          run_once
          wait = @next_wait || @poll_interval
          @sleeper.call(wait) unless stop.call
        end
      end

      private

      def schedule_failure(message)
        @store.transaction do
          current = @store.outbox.fetch(message.id)
          unless current.claim_token == message.claim_token && current.sent_at.nil?
            raise OutboxLeaseLostError, "outbox lease lost for #{message.id}"
          end

          now = @clock.call
          if current.attempts >= @max_attempts
            current.terminal_at = now
            current.next_attempt_at = nil
            @next_wait = @poll_interval
          else
            delay = [@backoff_base * (2**(current.attempts - 1)), @backoff_max].min
            current.next_attempt_at = now + delay
            @next_wait = delay
          end
          current.claimed_at = nil
          current.claim_token = nil
        end
      rescue OutboxLeaseLostError
        raise
      rescue StandardError => error
        raise OutboxPersistenceError, "unable to persist retry state for #{message.id}: #{error.class}"
      end

      def positive_number(value, name)
        number = Float(value)
        raise ConfigurationError, "#{name} must be positive" unless number.positive?

        number
      rescue ArgumentError, TypeError
        raise ConfigurationError, "#{name} must be positive"
      end

      def log(message)
        @logger.warn(message)
      end
    end

    class AccountService
      EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      def initialize(store:, hasher:, verification_tokens:, clock: -> { Time.now.utc })
        @store = store
        @hasher = hasher
        @verification_tokens = verification_tokens
        @clock = clock
      end

      def register(email:, password:)
        email = normalize_email(email)
        raise ValidationError, 'invalid email' unless email.match?(EMAIL)
        raise ValidationError, 'invalid password' unless password.is_a?(String) && password.length >= 12

        @store.transaction do
          next if @store.users.values.any? { |candidate| candidate.email == email }

          now = @clock.call
          user = User.new(id: SecureRandom.uuid, email: email, password_digest: @hasher.digest(password),
                          verified_at: nil, created_at: now)
          @store.users[user.id] = user
          nonce = SecureRandom.hex(16)
          key_version = @verification_tokens.current_version
          token = @verification_tokens.issue(
            user_id: user.id, nonce: nonce, expires_at: now + VERIFICATION_TTL, key_version: key_version
          )
          digest = TokenCodec.digest(token)
          @store.verifications[digest] = Verification.new(
            user_id: user.id, token_digest: digest, expires_at: now + VERIFICATION_TTL, used_at: nil
          )
          id = SecureRandom.uuid
          @store.outbox[id] = OutboxMessage.new(
            id: id, email: user.email, user_id: user.id, token_digest: digest, nonce: nonce,
            expires_at: now + VERIFICATION_TTL, key_version: key_version,
            sent_at: nil, claimed_at: nil, claim_token: nil, attempts: 0, next_attempt_at: nil, terminal_at: nil,
            created_at: now
          )
        end
        { 'registration_received' => true }
      end

      def verify_email(token:)
        raise ValidationError, 'invalid verification token' unless token.is_a?(String) && token.length >= 20

        @store.transaction do
          verification = @store.verifications[TokenCodec.digest(token)]
          raise AuthenticationError, 'invalid verification token' unless verification && verification.used_at.nil? &&
            verification.expires_at > @clock.call

          user = @store.users.fetch(verification.user_id)
          now = @clock.call
          verification.used_at = now
          user.verified_at = now
        end
        { 'verified' => true }
      end

      private

      def normalize_email(email)
        raise ValidationError, 'invalid email' unless email.is_a?(String)

        email.strip.downcase
      end
    end

    class SessionService
      def initialize(store:, hasher:, clock: -> { Time.now.utc })
        @store = store
        @hasher = hasher
        @clock = clock
      end

      def login(email:, password:)
        @store.transaction do
          user = @store.users.values.find { |candidate| candidate.email == email.to_s.strip.downcase }
          password_digest = user ? user.password_digest : @hasher.dummy_digest
          password_valid = @hasher.verify(password, password_digest)
          unless user && user.verified_at && password_valid
            raise AuthenticationError, 'invalid credentials'
          end

          issue(user)
        end
      end

      def renew(refresh_token:)
        @store.transaction do
          session = find_active(refresh_token, :refresh)
          user = @store.users.fetch(session.user_id)
          session.revoked_at = @clock.call
          issue(user)
        end
      end

      def revoke(token:, kind: :refresh)
        @store.transaction do
          session = find_active(token, kind)
          session.revoked_at = @clock.call
          { 'revoked' => true }
        end
      end

      def current(access_token:)
        @store.transaction do
          session = find_active(access_token, :access)
          { 'user_id' => session.user_id, 'expires_at' => session.access_expires_at.iso8601 }
        end
      end

      private

      def find_active(token, kind)
        session = @store.sessions.values.find do |candidate|
          candidate.public_send("#{kind}_token_digest") == TokenCodec.digest(token)
        end
        expires_at = session&.public_send("#{kind}_expires_at")
        raise AuthenticationError, 'invalid session' unless session && session.revoked_at.nil? && expires_at > @clock.call

        session
      end

      def issue(user)
        now = @clock.call
        active = @store.sessions.values.select do |session|
          session.user_id == user.id && session.revoked_at.nil? && session.refresh_expires_at > now
        end.sort_by(&:created_at)
        active.first.revoked_at = now if active.length >= MAX_SESSIONS

        access_token = TokenCodec.issue
        refresh_token = TokenCodec.issue
        session = Session.new(id: SecureRandom.uuid, user_id: user.id,
                              access_token_digest: TokenCodec.digest(access_token),
                              refresh_token_digest: TokenCodec.digest(refresh_token),
                              access_expires_at: now + ACCESS_TOKEN_TTL,
                              refresh_expires_at: now + REFRESH_TOKEN_TTL, revoked_at: nil,
                              created_at: now + (@store.sessions.length / 1_000_000.0))
        @store.sessions[session.id] = session
        {
          'access_token' => access_token,
          'refresh_token' => refresh_token,
          'expires_at' => session.access_expires_at.iso8601,
          'access_expires_at' => session.access_expires_at.iso8601,
          'refresh_expires_at' => session.refresh_expires_at.iso8601
        }
      end
    end

    class App
      attr_reader :session_service

      def initialize(account_service: nil, session_service: nil)
        @store = if account_service || session_service
                   InMemoryStore.new
                 elsif ENV['DATABASE_URL'].to_s.empty?
                   raise ConfigurationError, 'DATABASE_URL is required'
                 else
                   PostgresStore.new(ENV['DATABASE_URL'])
                 end
        hasher = PasswordHasher.new
        verification_tokens = VerificationTokenCodec.from_env
        @accounts = account_service || AccountService.new(
          store: @store, hasher: hasher, verification_tokens: verification_tokens
        )
        @sessions = session_service || SessionService.new(store: @store, hasher: hasher)
        @session_service = @sessions
      end

      def call(env)
        request_id = SecureRandom.uuid
        response = route(env['REQUEST_METHOD'], env['PATH_INFO'].to_s, parse_body(env), env)
        return verification_page(request_id) if response['verification_required']

        json(200, response, request_id)
      rescue ValidationError
        problem(400, 'invalid_request', request_id)
      rescue ConflictError
        problem(409, 'account_unavailable', request_id)
      rescue AuthenticationError
        problem(401, 'authentication_failed', request_id)
      rescue ConfigurationError
        problem(503, 'service_unavailable', request_id)
      rescue PayloadTooLargeError
        problem(413, 'payload_too_large', request_id)
      rescue JSON::ParserError
        problem(400, 'invalid_json', request_id)
      rescue KeyError
        problem(400, 'invalid_request', request_id)
      rescue StandardError => error
        warn("internal error request_id=#{request_id} class=#{error.class}")
        problem(500, 'internal_error', request_id)
      end

      private

      def route(method, path, body, env)
        case [method, path]
        when ['POST', '/v1/accounts']
          @accounts.register(email: body.fetch('email'), password: body.fetch('password'))
        when ['POST', '/v1/accounts/verify-email']
          @accounts.verify_email(token: body.fetch('token'))
        when ['GET', '/v1/accounts/verify-email']
          { 'verification_required' => true }
        when ['POST', '/v1/sessions']
          @sessions.login(email: body.fetch('email'), password: body.fetch('password'))
        when ['POST', '/v1/sessions/refresh']
          @sessions.renew(refresh_token: token(env, body, 'refresh_token'))
        when ['DELETE', '/v1/sessions/current']
          @sessions.revoke(token: token(env, body, 'refresh_token'), kind: token_kind(env))
        when ['GET', '/v1/sessions/current']
          @sessions.current(access_token: token(env, body, 'access_token'))
        else
          raise ValidationError, 'not found'
        end
      end

      def token(env, body, key)
        authorization = env['HTTP_AUTHORIZATION'].to_s
        return authorization.delete_prefix('Bearer ').strip if authorization.start_with?('Bearer ')

        body.fetch(key)
      end

      def token_kind(env)
        env['HTTP_AUTHORIZATION'].to_s.start_with?('Bearer ') ? :access : :refresh
      end

      def parse_body(env)
        content_length = env['CONTENT_LENGTH'].to_i
        raise PayloadTooLargeError if content_length > MAX_BODY_BYTES
        return {} unless content_length.positive? || env['HTTP_TRANSFER_ENCODING']

        input = env['rack.input']
        raise ValidationError unless input

        body = input.read(MAX_BODY_BYTES + 1)
        raise PayloadTooLargeError if body.bytesize > MAX_BODY_BYTES

        if env['CONTENT_TYPE'].to_s.start_with?('application/x-www-form-urlencoded')
          URI.decode_www_form(body).to_h
        else
          JSON.parse(body)
        end
      rescue ArgumentError
        raise ValidationError
      end

      def json(status, data, request_id, extra_headers = {})
        headers = { 'Content-Type' => 'application/json', 'X-Request-Id' => request_id }.merge(extra_headers)
        [status, headers, [JSON.generate(data)]]
      end

      def verification_page(request_id)
        html = <<~HTML
          <!doctype html>
          <html><body>
          <h1>Confirm email verification</h1>
          <button id="verify" type="button">Verify email</button>
          <p id="result">Click the button to verify your email.</p>
          <script>
          document.getElementById('verify').addEventListener('click', async () => {
            const token = window.location.hash.startsWith('#token=') ? decodeURIComponent(window.location.hash.slice(7)) : '';
            if (!token) {
              document.getElementById('result').textContent = 'Verification link is incomplete.';
              return;
            }
            const response = await fetch('/v1/accounts/verify-email', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ token })
            });
            document.getElementById('result').textContent = response.ok ? 'Email verified.' : 'Verification failed.';
          });
          </script>
          </body></html>
        HTML
        [
          200,
          {
            'Content-Type' => 'text/html; charset=utf-8',
            'Cache-Control' => 'no-store',
            'Referrer-Policy' => 'no-referrer',
            'X-Request-Id' => request_id
          },
          [html]
        ]
      end

      def problem(status, code, request_id)
        [status, { 'Content-Type' => 'application/problem+json', 'X-Request-Id' => request_id },
         [JSON.generate('code' => code, 'request_id' => request_id)]]
      end
    end
  end
end
