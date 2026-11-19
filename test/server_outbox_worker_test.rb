# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../server/lib/dungeon_critters_server'

class ServerOutboxWorkerTest < Minitest::Test
  FakeLogger = Struct.new(:messages) do
    def warn(message)
      messages << message
    end
  end

  def test_worker_delivers_pending_messages
    sent = []
    dispatcher = build_dispatcher do |mailer|
      mailer.define_singleton_method(:send_verification) { |**message| sent << message }
    end

    worker = build_worker(dispatcher: dispatcher)

    dispatcher.store.outbox['message-1'] = outbox_message

    assert_equal 1, worker.run_once
    assert_equal 1, sent.length
  end

  def test_worker_retries_failures_with_bounded_backoff
    attempts = 0
    sent = []
    dispatcher = build_dispatcher do |mailer|
      mailer.define_singleton_method(:send_verification) do |**|
        attempts += 1
        raise 'transport secret=hidden' if attempts == 1
        sent << true
      end
    end
    dispatcher.store.outbox['message-1'] = outbox_message

    worker = build_worker(dispatcher: dispatcher, backoff_base: 2, backoff_max: 4)

    assert_equal 0, worker.run_once
    assert_equal 1, dispatcher.store.outbox['message-1'].attempts
    assert_in_delta Time.utc(2026, 1, 1, 0, 0, 2), dispatcher.store.outbox['message-1'].next_attempt_at
  end

  def test_worker_stops_after_retry_limit_and_does_not_log_error_details
    logger = FakeLogger.new([])
    dispatcher = build_dispatcher do |mailer|
      mailer.define_singleton_method(:send_verification) do |**|
        raise 'RESEND_API_KEY=secret'
      end
    end
    dispatcher.store.outbox['message-1'] = outbox_message

    worker = build_worker(dispatcher: dispatcher, max_attempts: 2, logger: logger)

    assert_equal 0, worker.run_once
    assert_nil dispatcher.store.outbox['message-1'].terminal_at
    dispatcher.clock.call
    dispatcher.store.outbox['message-1'].next_attempt_at = Time.utc(2026, 1, 1)
    assert_equal 0, worker.run_once
    refute_nil dispatcher.store.outbox['message-1'].terminal_at
    assert_equal 2, dispatcher.store.outbox['message-1'].attempts
    assert_equal 2, logger.messages.length
    assert_includes logger.messages.first, 'RuntimeError'
    refute_includes logger.messages.first, 'RESEND_API_KEY'
    refute_includes logger.messages.first, 'secret'
  end

  def test_worker_restart_respects_persisted_backoff_and_retries_after_due
    now = Time.utc(2026, 1, 1)
    sent = 0
    dispatcher = build_dispatcher(clock: -> { now }) do |mailer|
      mailer.define_singleton_method(:send_verification) do |**|
        sent += 1
        raise 'temporary failure' if sent == 1
      end
    end
    dispatcher.store.outbox['message-1'] = outbox_message

    first_worker = build_worker(dispatcher: dispatcher, clock: -> { now }, backoff_base: 10, backoff_max: 20)
    assert_equal 0, first_worker.run_once
    assert_equal 1, dispatcher.store.outbox['message-1'].attempts
    assert_equal now + 10, dispatcher.store.outbox['message-1'].next_attempt_at

    restarted_worker = build_worker(dispatcher: dispatcher, clock: -> { now }, backoff_base: 10, backoff_max: 20)
    assert_equal 0, restarted_worker.run_once
    assert_equal 1, sent

    now += 10
    assert_equal 1, restarted_worker.run_once
    assert_equal 2, sent
    assert_equal 2, dispatcher.store.outbox['message-1'].attempts
    assert_nil dispatcher.store.outbox['message-1'].next_attempt_at
  end

  def test_worker_stops_during_backoff_without_starting_another_attempt
    sleeps = []
    sent = 0
    dispatcher = build_dispatcher do |mailer|
      mailer.define_singleton_method(:send_verification) do |**|
        sent += 1
        raise 'temporary failure'
      end
    end
    dispatcher.store.outbox['message-1'] = outbox_message
    stopping = false
    sleeper = lambda do |seconds|
      sleeps << seconds
      stopping = true
    end

    worker = build_worker(dispatcher: dispatcher, sleeper: sleeper, backoff_base: 7, backoff_max: 20)
    worker.run(stop: -> { stopping })

    assert_equal 1, sent
    assert_equal [7], sleeps
    assert_equal 1, dispatcher.store.outbox['message-1'].attempts
  end

  def test_crash_on_attempt_before_failure_transition_still_consumes_last_attempt
    now = Time.utc(2026, 1, 1)
    dispatcher = build_dispatcher(clock: -> { now }) do |mailer|
      mailer.define_singleton_method(:send_verification) { |**| raise 'transport failure' }
    end
    dispatcher.store.outbox['message-1'] = outbox_message

    assert_raises(SystemExit) do
      dispatcher.deliver_pending(on_failure: ->(_) { raise SystemExit })
    end
    assert_equal 1, dispatcher.store.outbox['message-1'].attempts

    now += DungeonCritters::Server::OUTBOX_CLAIM_TTL + 1
    worker = build_worker(dispatcher: dispatcher, clock: -> { now }, max_attempts: 1)
    assert_equal 0, worker.run_once
    assert_equal 1, dispatcher.store.outbox['message-1'].attempts
    refute_nil dispatcher.store.outbox['message-1'].terminal_at
  end

  def test_concurrent_workers_do_not_overwrite_a_reclaimed_lease
    now = Time.utc(2026, 1, 1)
    first_started = Queue.new
    release_first = Queue.new
    sent = []
    store = DungeonCritters::Server::InMemoryStore.new
    dispatcher_one = build_dispatcher_for_store(store, clock: -> { now }) do |mailer|
      mailer.define_singleton_method(:send_verification) do |**|
        sent << :first
        first_started << true
        release_first.pop
      end
    end
    dispatcher_two = build_dispatcher_for_store(store, clock: -> { now }) do |mailer|
      mailer.define_singleton_method(:send_verification) { |**| sent << :second }
    end
    store.outbox['message-1'] = outbox_message

    first_error = nil
    first = Thread.new do
      begin
        dispatcher_one.deliver_pending
      rescue StandardError => error
        first_error = error
      end
    end
    first_started.pop
    now += DungeonCritters::Server::OUTBOX_CLAIM_TTL + 1
    assert_equal 1, dispatcher_two.deliver_pending
    release_first << true

    first.join
    assert_instance_of DungeonCritters::Server::OutboxLeaseLostError, first_error
    assert_equal %i[first second], sent
    assert_equal 2, store.outbox['message-1'].attempts
    assert_nil store.outbox['message-1'].claim_token
    refute_nil store.outbox['message-1'].sent_at
  end

  def test_worker_validates_resend_configuration_before_claiming
    store = DungeonCritters::Server::InMemoryStore.new
    mailer = DungeonCritters::Server::ResendMailer.new(
      api_key: nil, from: nil, public_api_url: 'http://localhost:9292', client: nil
    )
    dispatcher = build_dispatcher_for_store(store, mailer: mailer)
    store.outbox['message-1'] = outbox_message

    assert_raises(DungeonCritters::Server::ConfigurationError) do
      build_worker(dispatcher: dispatcher)
    end
    assert_equal 0, store.outbox['message-1'].attempts
  end

  def test_worker_bootstrap_rejects_missing_url_and_token_secret_environment
    assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server.require_env!('PUBLIC_API_URL', env: {})
    end
    assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server.require_env!('VERIFICATION_TOKEN_SECRETS', env: {})
    end
  end

  def test_worker_keeps_lease_loss_distinct_from_persistence_failure
    logger = FakeLogger.new([])
    dispatcher = build_dispatcher do |mailer|
      mailer.define_singleton_method(:send_verification) do |**|
        dispatcher_store = instance_variable_get(:@store)
        replacement = dispatcher_store.outbox['message-1'].dup
        replacement.claim_token = 'another-worker'
        dispatcher_store.outbox['message-1'] = replacement
        raise 'transport failure'
      end
    end
    dispatcher.store.outbox['message-1'] = outbox_message
    dispatcher.instance_variable_get(:@mailer).instance_variable_set(:@store, dispatcher.store)
    worker = build_worker(dispatcher: dispatcher, logger: logger)

    assert_equal 0, worker.run_once
    assert_includes logger.messages.last, 'outcome uncertain'
    refute_includes logger.messages.last, 'persistence failed'
  end

  def test_worker_reports_persistence_failure_without_releasing_lease
    logger = FakeLogger.new([])
    store_class = Class.new(DungeonCritters::Server::InMemoryStore) do
      attr_accessor :fail_on_transaction
      attr_reader :transaction_count

      def transaction
        @transaction_count = (@transaction_count || 0) + 1
        if @transaction_count == fail_on_transaction
          raise IOError, 'database unavailable'
        end
        super
      end
    end
    store = store_class.new
    dispatcher = build_dispatcher_for_store(store) do |mailer|
      mailer.define_singleton_method(:send_verification) { |**| raise 'transport failure' }
    end
    store.outbox['message-1'] = outbox_message
    worker = build_worker(dispatcher: dispatcher, logger: logger)
    store.fail_on_transaction = 2

    assert_equal 0, worker.run_once
    assert_equal 1, store.outbox['message-1'].attempts
    refute_nil store.outbox['message-1'].claim_token
    assert_includes logger.messages.last, 'persistence failed'
  end

  def test_worker_entrypoint_configures_retry_runtime
    entrypoint = File.read(File.expand_path('../server/bin/outbox_worker.rb', __dir__))

    assert_includes entrypoint, 'Server::OutboxWorker.new'
    assert_includes entrypoint, "ENV.fetch('OUTBOX_POLL_INTERVAL'"
    assert_includes entrypoint, "ENV.fetch('OUTBOX_BACKOFF_BASE'"
    assert_includes entrypoint, "ENV.fetch('OUTBOX_BACKOFF_MAX'"
    assert_includes entrypoint, "ENV.fetch('OUTBOX_MAX_ATTEMPTS'"
    assert_includes entrypoint, 'worker.run(stop: -> { stopping })'
  end

  private

  def build_worker(dispatcher:, sleeper: ->(_seconds) {}, max_attempts: 3, logger: FakeLogger.new([]),
                  clock: -> { Time.utc(2026, 1, 1) }, backoff_base: 1, backoff_max: 4)
    DungeonCritters::Server::OutboxWorker.new(
      store: dispatcher.store,
      dispatcher: dispatcher,
      poll_interval: 5,
      backoff_base: backoff_base,
      backoff_max: backoff_max,
      max_attempts: max_attempts,
      clock: clock,
      logger: logger,
      sleeper: sleeper
    )
  end

  def build_dispatcher(clock: -> { Time.utc(2026, 1, 1) })
    store = DungeonCritters::Server::InMemoryStore.new
    build_dispatcher_for_store(store, clock: clock) { |mailer| yield mailer }
  end

  def build_dispatcher_for_store(store, mailer: nil, clock: -> { Time.utc(2026, 1, 1) })
    mailer ||= Object.new
    yield mailer if block_given?
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: store,
      mailer: mailer,
      verification_tokens: DungeonCritters::Server::VerificationTokenCodec.new(
        secrets: { 'v1' => 'worker-test-secret' }, current_version: 'v1'
      ),
      clock: clock
    )
    dispatcher.define_singleton_method(:store) { store }
    dispatcher.define_singleton_method(:clock) { clock }
    dispatcher
  end

  def outbox_message
    now = Time.utc(2026, 1, 1)
    DungeonCritters::Server::OutboxMessage.new(
      id: 'message-1',
      email: 'player@example.com',
      user_id: 'user-1',
      token_digest: '0' * 64,
      nonce: 'nonce',
      expires_at: now + 3600,
      key_version: 'v1',
      sent_at: nil,
      claimed_at: nil,
      claim_token: nil,
      attempts: 0,
      next_attempt_at: nil,
      terminal_at: nil,
      created_at: now
    )
  end
end
