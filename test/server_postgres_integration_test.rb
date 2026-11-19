# frozen_string_literal: true

require 'minitest/autorun'
require 'pg'
require 'uri'
require_relative '../server/lib/dungeon_critters_server'

class ServerPostgresIntegrationTest < Minitest::Test
  MIGRATION_PATH = File.expand_path('../server/db/001_sessions.sql', __dir__)
  RETRY_MIGRATION_PATH = File.expand_path('../server/db/002_outbox_retry_state.sql', __dir__)
  TEST_DATABASE_NAME = 'dungeon_critters_test'
  TEST_DATABASE_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  NOW = Time.utc(2026, 1, 1, 12, 0, 0)

  FakeHasher = Struct.new(:digests) do
    def digest(password)
      "digest:#{password}"
    end

    def verify(password, digest)
      digests << digest
      digest == "digest:#{password}"
    end

    def dummy_digest
      'digest:invalid login password'
    end
  end

  class RecordingMailer
    attr_reader :messages

    def initialize
      @messages = []
      @mutex = Mutex.new
    end

    def send_verification(email:, token:)
      @mutex.synchronize { @messages << { email: email, token: token } }
    end
  end

  def setup
    @database_url = ENV['DATABASE_URL'].to_s
    skip 'DATABASE_URL is not set' if @database_url.empty?

    assert_safe_test_database(@database_url)
    @connection = PG.connect(@database_url)
    @stores = []
    reset_database
  end

  def teardown
    @stores.each do |store|
      connection = store.instance_variable_get(:@connection)
      connection.close unless connection.nil? || connection.finished?
    end
    @connection&.close unless @connection.nil? || @connection.finished?
  end

  def test_empty_database_rejects_startup_without_writing
    error = assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::PostgresStore.new(@database_url)
    end

    assert_includes error.message, 'database schema is missing tables'
    assert_empty table_names
  end

  def test_initial_migration_is_idempotent_and_starts
    apply_migration
    apply_migration

    store = new_store
    assert_empty store.users
    assert_empty store.outbox
    assert_includes table_names, 'email_outbox'
  end

  def test_current_schema_persists_registration_without_raw_token
    apply_migration
    store = new_store
    tokens = verification_tokens
    accounts = DungeonCritters::Server::AccountService.new(
      store: store, hasher: FakeHasher.new([]), verification_tokens: tokens, clock: -> { NOW }
    )

    assert_equal({ 'registration_received' => true },
                 accounts.register(email: 'player@example.test', password: 'a secure password'))

    row = @connection.exec('SELECT * FROM email_outbox').first
    refute_nil row
    refute row.key?('token')
    assert_match(/\A[0-9a-f]{64}\z/, row.fetch('token_digest'))
    assert_equal 'v1', row.fetch('key_version')
    assert_equal %w[attempts claimed_at claim_token created_at email expires_at id key_version next_attempt_at nonce
                    sent_at terminal_at token_digest user_id].sort,
                 row.keys.sort
  end

  def test_retry_migration_is_idempotent_and_adds_persistent_state
    apply_migration
    apply_retry_migration
    apply_retry_migration

    columns = @connection.exec(
      "SELECT column_name FROM information_schema.columns " \
      "WHERE table_schema = current_schema() AND table_name = 'email_outbox'"
    ).map { |row| row.fetch('column_name') }

    assert_includes columns, 'attempts'
    assert_includes columns, 'next_attempt_at'
    assert_includes columns, 'terminal_at'
    assert_includes columns, 'claim_token'
    assert_equal 0, @connection.exec("SELECT column_default FROM information_schema.columns " \
                                     "WHERE table_name = 'email_outbox' AND column_name = 'attempts'")
                        .first.fetch('column_default').to_i
  end

  def test_worker_persists_backoff_after_postgres_delivery_failure
    apply_migration
    apply_retry_migration
    insert_pending_message
    observed_attempts = []
    observer = PG.connect(@database_url)
    mailer = Object.new
    mailer.define_singleton_method(:send_verification) do |**|
      observed_attempts << observer.exec('SELECT attempts FROM email_outbox').first.fetch('attempts').to_i
      raise 'synthetic delivery failure'
    end
    worker = build_worker(store: new_store, mailer: mailer, backoff_base: 7, backoff_max: 20)

    begin
      assert_equal 0, worker.run_once
    ensure
      observer.close unless observer.finished?
    end

    row = @connection.exec(
      'SELECT attempts, claimed_at, claim_token, next_attempt_at, terminal_at FROM email_outbox'
    ).first
    assert_equal 1, row.fetch('attempts').to_i
    assert_equal [1], observed_attempts
    assert_nil row.fetch('claimed_at')
    assert_nil row.fetch('claim_token')
    assert_equal NOW + 7, Time.parse(row.fetch('next_attempt_at'))
    assert_nil row.fetch('terminal_at')
  end

  def test_worker_restart_respects_persisted_backoff_and_delivers_when_due
    apply_migration
    apply_retry_migration
    insert_pending_message
    now = NOW
    sends = 0
    mailer = Object.new
    mailer.define_singleton_method(:send_verification) do |**|
      sends += 1
      raise 'temporary failure' if sends == 1
    end

    first_worker = build_worker(store: new_store, mailer: mailer, clock: -> { now }, backoff_base: 10)
    assert_equal 0, first_worker.run_once

    restarted_worker = build_worker(store: new_store, mailer: mailer, clock: -> { now }, backoff_base: 10)
    assert_equal 0, restarted_worker.run_once
    assert_equal 1, sends

    now += 10
    assert_equal 1, restarted_worker.run_once
    assert_equal 2, sends
    row = @connection.exec(
      'SELECT attempts, sent_at, claim_token, next_attempt_at, terminal_at FROM email_outbox'
    ).first
    assert_equal 2, row.fetch('attempts').to_i
    refute_nil row.fetch('sent_at')
    assert_nil row.fetch('claim_token')
    assert_nil row.fetch('next_attempt_at')
    assert_nil row.fetch('terminal_at')
  end

  def test_worker_applies_exponential_backoff_with_maximum_in_postgres
    apply_migration
    apply_retry_migration
    insert_pending_message
    now = NOW
    sends = 0
    mailer = Object.new
    mailer.define_singleton_method(:send_verification) do |**|
      sends += 1
      raise 'temporary failure'
    end
    worker = build_worker(store: new_store, mailer: mailer, clock: -> { now },
                          backoff_base: 3, backoff_max: 5, max_attempts: 4)

    assert_equal 0, worker.run_once
    assert_equal 3, (outbox_timestamp('next_attempt_at') - now).to_i

    now += 3
    assert_equal 0, worker.run_once
    assert_equal 5, (outbox_timestamp('next_attempt_at') - now).to_i

    now += 5
    assert_equal 0, worker.run_once
    assert_equal 5, (outbox_timestamp('next_attempt_at') - now).to_i
    assert_equal 3, sends
  end

  def test_worker_marks_terminal_after_max_attempts_in_postgres
    apply_migration
    apply_retry_migration
    insert_pending_message
    now = NOW
    sends = 0
    mailer = Object.new
    mailer.define_singleton_method(:send_verification) do |**|
      sends += 1
      raise 'permanent delivery failure'
    end
    worker = build_worker(store: new_store, mailer: mailer, clock: -> { now }, max_attempts: 2)

    assert_equal 0, worker.run_once
    now += 1
    assert_equal 0, worker.run_once

    row = @connection.exec(
      'SELECT attempts, sent_at, claim_token, next_attempt_at, terminal_at FROM email_outbox'
    ).first
    assert_equal 2, row.fetch('attempts').to_i
    assert_nil row.fetch('sent_at')
    assert_nil row.fetch('claim_token')
    assert_nil row.fetch('next_attempt_at')
    refute_nil row.fetch('terminal_at')
    now += 100
    assert_equal 0, worker.run_once
    assert_equal 2, sends
  end

  def test_legacy_schema_rejects_startup_and_preserves_raw_token
    create_supporting_schema
    @connection.exec <<~SQL
      CREATE TABLE email_outbox (
        id uuid PRIMARY KEY,
        email text NOT NULL,
        token text NOT NULL,
        sent_at timestamptz,
        claimed_at timestamptz,
        created_at timestamptz NOT NULL
      )
    SQL
    @connection.exec_params(
      'INSERT INTO email_outbox (id, email, token, created_at) VALUES ($1, $2, $3, $4)',
      ['00000000-0000-0000-0000-000000000001', 'player@example.test', 'synthetic-legacy-token', NOW]
    )

    error = assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::PostgresStore.new(@database_url)
    end

    assert_includes error.message, 'legacy token column'
    row = @connection.exec('SELECT token FROM email_outbox').first
    assert_equal 'synthetic-legacy-token', row.fetch('token')
  end

  def test_partial_schema_rejects_startup_and_reports_missing_columns
    create_supporting_schema
    @connection.exec <<~SQL
      CREATE TABLE email_outbox (
        id uuid,
        email text,
        user_id uuid,
        token_digest text,
        nonce text,
        expires_at timestamptz,
        sent_at timestamptz,
        claimed_at timestamptz,
        created_at timestamptz
      )
    SQL

    error = assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::PostgresStore.new(@database_url)
    end

    assert_includes error.message, 'email_outbox.key_version'
    assert_equal 1, @connection.exec("SELECT 1 FROM pg_class WHERE relname = 'email_outbox'").ntuples
  end

  def test_concurrent_dispatchers_claim_one_message
    apply_migration
    insert_pending_message
    mailer = RecordingMailer.new
    dispatchers = 2.times.map do
      DungeonCritters::Server::OutboxDispatcher.new(
        store: new_store, mailer: mailer, verification_tokens: verification_tokens, clock: -> { NOW }
      )
    end
    ready = Queue.new
    start = Queue.new
    threads = dispatchers.map do |dispatcher|
      Thread.new do
        ready << true
        start.pop
        dispatcher.deliver_pending
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)

    assert_equal [0, 1], results.sort
    assert_equal 1, mailer.messages.length
    assert_equal 1, @connection.exec('SELECT 1 FROM email_outbox WHERE sent_at IS NOT NULL').ntuples
  end

  def test_reclaimed_lease_cannot_be_acknowledged_by_stale_dispatcher
    apply_migration
    insert_pending_message
    now = NOW
    first_started = Queue.new
    release_first = Queue.new
    sent = Queue.new
    first_mailer = Object.new
    first_mailer.define_singleton_method(:send_verification) do |**|
      sent << :first
      first_started << true
      release_first.pop
    end
    second_mailer = Object.new
    second_mailer.define_singleton_method(:send_verification) { |**| sent << :second }
    first_dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: new_store, mailer: first_mailer, verification_tokens: verification_tokens, clock: -> { now }
    )
    second_dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: new_store, mailer: second_mailer, verification_tokens: verification_tokens, clock: -> { now }
    )

    first_error = nil
    first = Thread.new do
      begin
        first_dispatcher.deliver_pending
      rescue StandardError => error
        first_error = error
      end
    end
    first_started.pop
    now += DungeonCritters::Server::OUTBOX_CLAIM_TTL + 1

    assert_equal 1, second_dispatcher.deliver_pending
    release_first << true
    first.join

    assert_instance_of DungeonCritters::Server::OutboxLeaseLostError, first_error
    assert_equal %i[first second], 2.times.map { sent.pop }
    row = @connection.exec(
      'SELECT attempts, sent_at, claimed_at, claim_token FROM email_outbox'
    ).first
    assert_equal 2, row.fetch('attempts').to_i
    refute_nil row.fetch('sent_at')
    assert_nil row.fetch('claimed_at')
    assert_nil row.fetch('claim_token')
  end

  def test_active_lease_is_not_reclaimed
    apply_migration
    insert_pending_message(claimed_at: NOW)
    mailer = RecordingMailer.new
    delivered = dispatcher(store: new_store, mailer: mailer).deliver_pending

    assert_equal 0, delivered
    assert_empty mailer.messages
  end

  def test_expired_lease_is_reclaimed
    apply_migration
    insert_pending_message(claimed_at: NOW - DungeonCritters::Server::OUTBOX_CLAIM_TTL - 1)
    mailer = RecordingMailer.new
    delivered = dispatcher(store: new_store, mailer: mailer).deliver_pending

    assert_equal 1, delivered
    assert_equal 1, mailer.messages.length
    assert_equal 1, @connection.exec('SELECT 1 FROM email_outbox WHERE sent_at IS NOT NULL').ntuples
  end

  def test_failed_delivery_releases_lease_for_retry
    apply_migration
    insert_pending_message
    attempts = 0
    mailer = Object.new
    mailer.define_singleton_method(:send_verification) do |email:, token:|
      attempts += 1
      raise 'synthetic delivery failure' if attempts == 1

      [email, token]
    end
    dispatcher = dispatcher(store: new_store, mailer: mailer)

    assert_raises(RuntimeError) { dispatcher.deliver_pending }
    assert_equal 1, @connection.exec('SELECT 1 FROM email_outbox WHERE claimed_at IS NULL').ntuples
    assert_nil @connection.exec('SELECT sent_at FROM email_outbox').first.fetch('sent_at')

    assert_equal 1, dispatcher.deliver_pending
    assert_equal 2, attempts
    assert_equal 1, @connection.exec('SELECT 1 FROM email_outbox WHERE sent_at IS NOT NULL').ntuples
  end

  private

  def assert_safe_test_database(url)
    uri = URI.parse(url)
    assert_includes TEST_DATABASE_HOSTS, uri.host,
                    'DATABASE_URL must point to a local CI/test PostgreSQL instance'
    assert_equal "/#{TEST_DATABASE_NAME}", uri.path,
                 "DATABASE_URL must target #{TEST_DATABASE_NAME}"
  rescue URI::InvalidURIError => error
    flunk "DATABASE_URL is invalid: #{error.message}"
  end

  def reset_database
    @connection.exec('DROP TABLE IF EXISTS email_outbox, email_verifications, sessions, users CASCADE')
  end

  def apply_migration
    @connection.exec(File.read(MIGRATION_PATH))
    apply_retry_migration
  end

  def apply_retry_migration
    @connection.exec(File.read(RETRY_MIGRATION_PATH))
  end

  def create_supporting_schema
    @connection.exec <<~SQL
      CREATE TABLE users (
        id uuid PRIMARY KEY,
        email text NOT NULL UNIQUE,
        password_digest text NOT NULL,
        verified_at timestamptz,
        created_at timestamptz NOT NULL DEFAULT now()
      );

      CREATE TABLE email_verifications (
        token_digest text PRIMARY KEY,
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        expires_at timestamptz NOT NULL,
        used_at timestamptz
      );

      CREATE TABLE sessions (
        id uuid PRIMARY KEY,
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        access_token_digest text NOT NULL UNIQUE,
        refresh_token_digest text NOT NULL UNIQUE,
        access_expires_at timestamptz NOT NULL,
        refresh_expires_at timestamptz NOT NULL,
        revoked_at timestamptz,
        created_at timestamptz NOT NULL DEFAULT now()
      );
    SQL
  end

  def table_names
    @connection.exec(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = current_schema()"
    ).map { |row| row.fetch('tablename') }
  end

  def new_store
    store = DungeonCritters::Server::PostgresStore.new(@database_url)
    @stores << store
    store
  end

  def verification_tokens
    DungeonCritters::Server::VerificationTokenCodec.new(
      secrets: { 'v1' => 'ci-only-test-secret' }, current_version: 'v1'
    )
  end

  def dispatcher(store:, mailer:)
    DungeonCritters::Server::OutboxDispatcher.new(
      store: store, mailer: mailer, verification_tokens: verification_tokens, clock: -> { NOW }
    )
  end

  def insert_pending_message(claimed_at: nil)
    user_id = '00000000-0000-0000-0000-000000000001'
    outbox_id = '00000000-0000-0000-0000-000000000002'
    @connection.exec_params(
      'INSERT INTO users (id, email, password_digest, created_at) VALUES ($1, $2, $3, $4)',
      [user_id, 'player@example.test', 'synthetic-password-digest', NOW]
    )
    @connection.exec_params(
      'INSERT INTO email_outbox
       (id, email, user_id, token_digest, nonce, expires_at, key_version, sent_at, claimed_at, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)',
      [outbox_id, 'player@example.test', user_id, 'a' * 64, 'synthetic-nonce',
       NOW + DungeonCritters::Server::VERIFICATION_TTL, 'v1', nil, claimed_at, NOW]
    )
  end

  def outbox_timestamp(column)
    value = @connection.exec("SELECT #{column} FROM email_outbox").first.fetch(column)
    Time.parse(value)
  end

  def build_worker(store:, mailer:, clock: -> { NOW }, backoff_base: 1, backoff_max: 60, max_attempts: 5)
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: store, mailer: mailer, verification_tokens: verification_tokens, clock: clock
    )
    DungeonCritters::Server::OutboxWorker.new(
      store: store,
      dispatcher: dispatcher,
      poll_interval: 5,
      backoff_base: backoff_base,
      backoff_max: backoff_max,
      max_attempts: max_attempts,
      clock: clock,
      logger: Object.new.tap { |logger| logger.define_singleton_method(:warn) { |_message| } },
      sleeper: ->(_seconds) {}
    )
  end
end
