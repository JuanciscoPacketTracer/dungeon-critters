# frozen_string_literal: true

require 'digest'
require 'base64'
require 'json'
require 'securerandom'
require 'time'
require 'uri'

module DungeonCritters
  module Server
    ACCESS_TOKEN_TTL = 15 * 60
    REFRESH_TOKEN_TTL = 30 * 24 * 60 * 60
    VERIFICATION_TTL = 24 * 60 * 60
    MAX_SESSIONS = 5

    class ValidationError < StandardError; end
    class AuthenticationError < StandardError; end
    class ConflictError < StandardError; end
    class ConfigurationError < StandardError; end
    class PayloadTooLargeError < StandardError; end
    MAX_BODY_BYTES = 64 * 1024

    User = Struct.new(:id, :email, :password_digest, :verified_at, :created_at, keyword_init: true)
    Session = Struct.new(:id, :user_id, :access_token_digest, :refresh_token_digest,
                         :access_expires_at, :refresh_expires_at, :revoked_at, :created_at, keyword_init: true)
    Verification = Struct.new(:user_id, :token_digest, :expires_at, :used_at, keyword_init: true)

    module TokenCodec
      module_function

      def issue
        SecureRandom.urlsafe_base64(32)
      end

      def digest(token)
        Digest::SHA256.hexdigest(token.to_s)
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
      attr_reader :users, :sessions, :verifications

      def initialize
        @users = {}
        @sessions = {}
        @verifications = {}
        @mutex = Mutex.new
      end

      def transaction
        @mutex.synchronize do
          snapshot = Marshal.dump([@users, @sessions, @verifications])
          yield self
        rescue StandardError
          @users, @sessions, @verifications = Marshal.load(snapshot)
          raise
        end
      end
    end

    class PostgresStore < InMemoryStore
      def initialize(url)
        require 'pg'
        @connection = PG.connect(url)
        super()
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

      def load_rows
        @users.clear
        @sessions.clear
        @verifications.clear
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
      end

      def time(value)
        value && Time.parse(value.to_s)
      end
    end

    class ResendMailer
      def initialize(api_key: ENV['RESEND_API_KEY'], from: ENV['RESEND_FROM_EMAIL'], client: nil)
        @api_key = api_key
        @from = from
        @client = client
      end

      def send_verification(email:, token:)
        raise ConfigurationError, 'Resend is not configured' if @client.nil? && (@api_key.to_s.empty? || @from.to_s.empty?)

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

      private

      def verification_url(token)
        base = ENV.fetch('PUBLIC_API_URL', 'http://localhost:9292')
        "#{base}/v1/accounts/verify-email?token=#{URI.encode_www_form_component(token)}"
      end
    end

    class AccountService
      EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      def initialize(store:, hasher:, mailer:, clock: -> { Time.now.utc })
        @store = store
        @hasher = hasher
        @mailer = mailer
        @clock = clock
      end

      def register(email:, password:)
        email = normalize_email(email)
        raise ValidationError, 'invalid email' unless email.match?(EMAIL)
        raise ValidationError, 'invalid password' unless password.is_a?(String) && password.length >= 12

        token = TokenCodec.issue
        result = @store.transaction do
          raise ConflictError, 'account unavailable' if @store.users.values.any? { |candidate| candidate.email == email }

          now = @clock.call
          user = User.new(id: SecureRandom.uuid, email: email, password_digest: @hasher.digest(password),
                          verified_at: nil, created_at: now)
          @store.users[user.id] = user
          digest = TokenCodec.digest(token)
          @store.verifications[digest] = Verification.new(
            user_id: user.id, token_digest: digest, expires_at: now + VERIFICATION_TTL, used_at: nil
          )
          @mailer.send_verification(email: user.email, token: token)
          user
        end
        { 'id' => result.id, 'email_verified' => false }
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
      def initialize(account_service: nil, session_service: nil)
        @store = if account_service || session_service
                   InMemoryStore.new
                 elsif ENV['DATABASE_URL'].to_s.empty?
                   raise ConfigurationError, 'DATABASE_URL is required'
                 else
                   PostgresStore.new(ENV['DATABASE_URL'])
                 end
        hasher = PasswordHasher.new
        @accounts = account_service || AccountService.new(store: @store, hasher: hasher, mailer: ResendMailer.new)
        @sessions = session_service || SessionService.new(store: @store, hasher: hasher)
      end

      def call(env)
        request_id = SecureRandom.uuid
        response = route(env['REQUEST_METHOD'], env['PATH_INFO'].to_s, parse_body(env), env)
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

        JSON.parse(body)
      end

      def json(status, data, request_id)
        [status, { 'Content-Type' => 'application/json', 'X-Request-Id' => request_id }, [JSON.generate(data)]]
      end

      def problem(status, code, request_id)
        [status, { 'Content-Type' => 'application/problem+json', 'X-Request-Id' => request_id },
         [JSON.generate('code' => code, 'request_id' => request_id)]]
      end
    end
  end
end
