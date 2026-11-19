# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/mock'
require 'stringio'
require 'timeout'
require_relative '../server/lib/dungeon_critters_server'

class ServerAuthTest < Minitest::Test
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

  FakeMailer = Struct.new(:messages) do
    def send_verification(email:, token:)
      messages << { email: email, token: token }
    end
  end

  def setup
    @store = DungeonCritters::Server::InMemoryStore.new
    @hasher = FakeHasher.new([])
    @mailer = FakeMailer.new([])
    @now = Time.utc(2026, 1, 1)
    @clock = -> { @now }
    @verification_tokens = DungeonCritters::Server::VerificationTokenCodec.new(
      secrets: { 'v1' => 'test-secret' }, current_version: 'v1'
    )
    @dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: @mailer, verification_tokens: @verification_tokens, clock: @clock
    )
    @accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, verification_tokens: @verification_tokens, clock: @clock
    )
    @sessions = DungeonCritters::Server::SessionService.new(store: @store, hasher: @hasher, clock: @clock)
  end

  def register_account(email:, password:)
    result = @accounts.register(email: email, password: password)
    @dispatcher.deliver_pending
    result
  end

  def test_unverified_account_cannot_login
    register_account(email: 'Player@Example.com', password: 'a secure password')
    assert_raises(DungeonCritters::Server::AuthenticationError) do
      @sessions.login(email: 'player@example.com', password: 'a secure password')
    end

  end

  def test_unknown_account_verifies_against_dummy_digest
    assert_raises(DungeonCritters::Server::AuthenticationError) do
      @sessions.login(email: 'missing@example.com', password: 'a secure password')
    end
    assert_includes @hasher.digests, @hasher.dummy_digest
  end

  def test_verification_enables_login
    register_account(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    refute_empty @sessions.login(email: 'player@example.com', password: 'a secure password')['refresh_token']
  end

  def test_duplicate_registration_has_uniform_response
    first = register_account(email: 'player@example.com', password: 'a secure password')
    second = @accounts.register(email: 'player@example.com', password: 'a secure password')

    assert_equal first, second
    assert_equal({ 'registration_received' => true }, first)
    assert_equal 1, @mailer.messages.length
  end

  def test_verification_token_rotation_keeps_old_outbox_tokens_regenerable
    old = DungeonCritters::Server::VerificationTokenCodec.new(
      secrets: { 'v1' => 'old-secret' }, current_version: 'v1'
    )
    rotated = DungeonCritters::Server::VerificationTokenCodec.new(
      secrets: { 'v1' => 'old-secret', 'v2' => 'new-secret' }, current_version: 'v2'
    )
    attributes = { user_id: 'user-1', nonce: 'nonce', expires_at: @now + 60 }

    assert_equal old.issue(**attributes), rotated.issue(**attributes, key_version: 'v1')
    refute_equal old.issue(**attributes), rotated.issue(**attributes, key_version: 'v2')
  end

  def test_verification_link_reaches_end_to_end_get_flow
    sent = []
    mailer = DungeonCritters::Server::ResendMailer.new(
      api_key: 'test-key', from: 'noreply@example.com', public_api_url: 'https://api.example.test',
      environment: 'test', client: ->(payload) { sent << payload }
    )
    accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, verification_tokens: @verification_tokens, clock: @clock
    )
    sessions = DungeonCritters::Server::SessionService.new(store: @store, hasher: @hasher, clock: @clock)
    app = DungeonCritters::Server::App.new(account_service: accounts, session_service: sessions)
    rack_app = ->(env) { app.call(env) }

    accounts.register(email: 'player@example.com', password: 'a secure password')
    DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: mailer, verification_tokens: @verification_tokens, clock: @clock
    ).deliver_pending
    verification_url = URI.parse(sent.first[:html][/href="([^"]+)"/, 1])
    response = Rack::MockRequest.new(rack_app).get(verification_url.request_uri)

    assert_equal 200, response.status
    assert_equal 'text/html; charset=utf-8', response['Content-Type']
    assert_includes response.body, 'window.location.hash'
    token = URI.decode_www_form_component(verification_url.fragment.delete_prefix('token='))
    refute_includes response.body, token
    assert_equal 'no-store', response['Cache-Control']
    assert_nil @store.users.values.first.verified_at
    response = Rack::MockRequest.new(rack_app).post(
      '/v1/accounts/verify-email',
      'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
      input: URI.encode_www_form('token' => token)
    )
    assert_equal 200, response.status
    assert_equal({ 'verified' => true }, JSON.parse(response.body))
    refute_empty sessions.login(email: 'player@example.com', password: 'a secure password')['access_token']
  end

  def test_only_five_sessions_remain_and_oldest_is_revoked
    register_account(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    tokens = 6.times.map { @sessions.login(email: 'player@example.com', password: 'a secure password') }
    assert_equal 5, @store.sessions.values.count { |session| session.revoked_at.nil? }
    assert_raises(DungeonCritters::Server::AuthenticationError) { @sessions.renew(refresh_token: tokens.first['refresh_token']) }
  end

  def test_concurrent_in_memory_logins_keep_five_active_sessions
    register_account(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    threads = 10.times.map do
      Thread.new { @sessions.login(email: 'player@example.com', password: 'a secure password') }
    end
    threads.each(&:value)
    assert_equal 5, @store.sessions.values.count { |session| session.revoked_at.nil? }
  end

  def test_refresh_rotates_and_revokes_old_token
    register_account(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    old = @sessions.login(email: 'player@example.com', password: 'a secure password')
    renewed = @sessions.renew(refresh_token: old['refresh_token'])
    refute_equal old['refresh_token'], renewed['refresh_token']
    assert_raises(DungeonCritters::Server::AuthenticationError) { @sessions.renew(refresh_token: old['refresh_token']) }
  end

  def test_expired_access_token_cannot_be_used_but_refresh_token_remains_valid
    register_account(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    tokens = @sessions.login(email: 'player@example.com', password: 'a secure password')
    @now += DungeonCritters::Server::ACCESS_TOKEN_TTL + 1

    assert_raises(DungeonCritters::Server::AuthenticationError) do
      @sessions.current(access_token: tokens['access_token'])
    end
    refute_empty @sessions.renew(refresh_token: tokens['refresh_token'])['access_token']
  end

  def test_verification_token_is_single_use
    register_account(email: 'player@example.com', password: 'a secure password')
    token = @mailer.messages.first[:token]
    @accounts.verify_email(token: token)
    assert_raises(DungeonCritters::Server::AuthenticationError) { @accounts.verify_email(token: token) }
  end

  def test_access_token_can_read_and_revoke_current_session
    register_account(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    tokens = @sessions.login(email: 'player@example.com', password: 'a secure password')
    assert_equal @store.users.keys.first, @sessions.current(access_token: tokens['access_token'])['user_id']
    @sessions.revoke(token: tokens['access_token'], kind: :access)
    assert_raises(DungeonCritters::Server::AuthenticationError) do
      @sessions.current(access_token: tokens['access_token'])
    end
  end

  def test_http_errors_are_versioned_and_do_not_echo_credentials
    app = DungeonCritters::Server::App.new(account_service: @accounts, session_service: @sessions)
    payload = JSON.generate('email' => 'player@example.com', 'password' => 'wrong secret')
    status, headers, body = app.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/sessions',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'rack.input' => StringIO.new(payload)
    )
    assert_equal 401, status
    assert_equal 'application/problem+json', headers['Content-Type']
    refute_includes body.join, 'wrong secret'
    refute_includes body.join, 'player@example.com'
    refute_empty headers['X-Request-Id']
  end

  def test_unexpected_store_error_returns_safe_internal_problem
    accounts = Object.new
    accounts.define_singleton_method(:register) { |**| raise 'password=secret' }
    sessions = Object.new
    app = DungeonCritters::Server::App.new(account_service: accounts, session_service: sessions)
    payload = JSON.generate('email' => 'player@example.com', 'password' => 'a secure password')

    _status, _headers, body = app.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/accounts',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'rack.input' => StringIO.new(payload)
    )

    assert_equal 500, _status
    assert_equal 'application/problem+json', _headers['Content-Type']
    problem = JSON.parse(body.join)
    assert_equal 'internal_error', problem['code']
    assert_equal _headers['X-Request-Id'], problem['request_id']
    refute_includes body.join, 'password=secret'
    refute_includes body.join, 'a secure password'
  end

  def test_resend_failure_does_not_change_uniform_registration_response
    failing_mailer = Class.new { def send_verification(**); raise 'RESEND_API_KEY=secret'; end }.new
    accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, verification_tokens: @verification_tokens, clock: @clock
    )
    app = DungeonCritters::Server::App.new(account_service: accounts, session_service: @sessions)
    payload = JSON.generate('email' => 'player@example.com', 'password' => 'a secure password')

    _status, _headers, body = app.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/accounts',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'rack.input' => StringIO.new(payload)
    )

    assert_equal 200, _status
    assert_equal 'application/json', _headers['Content-Type']
    assert_equal({ 'registration_received' => true }, JSON.parse(body.join))
    refute_includes body.join, 'RESEND_API_KEY=secret'
    refute_includes body.join, 'a secure password'
    duplicate_status, _duplicate_headers, duplicate_body = app.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/accounts',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'rack.input' => StringIO.new(payload)
    )
    assert_equal 200, duplicate_status
    assert_equal body.join, duplicate_body.join
    message = @store.outbox.values.first
    refute_nil message
    assert_nil message.sent_at
    assert_nil message.claimed_at
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: failing_mailer, verification_tokens: @verification_tokens, clock: @clock
    )
    assert_raises(RuntimeError) { dispatcher.deliver_pending }
  end

  def test_pending_message_can_be_retried_without_client_request
    attempts = 0
    mailer = Class.new do
      define_method(:send_verification) do |**|
        attempts += 1
        raise 'temporary failure' if attempts == 1
      end
    end.new
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: mailer, verification_tokens: @verification_tokens, clock: @clock
    )
    accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, verification_tokens: @verification_tokens, clock: @clock
    )
    accounts.register(email: 'player@example.com', password: 'a secure password')
    assert_raises(RuntimeError) { dispatcher.deliver_pending }
    assert_nil @store.outbox.values.first.sent_at

    assert_equal 1, dispatcher.deliver_pending
    refute_nil @store.outbox.values.first.sent_at
    assert_equal 2, attempts
  end

  def test_dispatcher_reclaims_an_expired_outbox_lease
    sent = []
    mailer = Class.new do
      define_method(:send_verification) { |**value| sent << value }
    end.new
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: mailer, verification_tokens: @verification_tokens, clock: @clock
    )
    accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, verification_tokens: @verification_tokens, clock: @clock
    )
    accounts.register(email: 'player@example.com', password: 'a secure password')
    message = @store.outbox.values.first
    message.claimed_at = @now

    @now += DungeonCritters::Server::OUTBOX_CLAIM_TTL + 1
    assert_equal 1, dispatcher.deliver_pending
    assert_equal 1, sent.length
    refute_nil message.sent_at
  end

  def test_mailer_call_happens_outside_store_lock
    lock_was_available = false
    mailer = Class.new do
      define_method(:send_verification) do |**|
        store.transaction { lock_was_available = true }
      end
    end.new
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: mailer, verification_tokens: @verification_tokens, clock: @clock
    )
    accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, verification_tokens: @verification_tokens, clock: @clock
    )
    mailer.instance_variable_set(:@store, @store)
    mailer.define_singleton_method(:store) { @store }

    accounts.register(email: 'player@example.com', password: 'a secure password')
    Timeout.timeout(2) { dispatcher.deliver_pending }

    assert lock_was_available
  end

  def test_mailer_failure_preserves_account_and_pending_outbox
    failing_mailer = Class.new { def send_verification(**); raise 'transport failed'; end }.new
    accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, verification_tokens: @verification_tokens, clock: @clock
    )
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: failing_mailer, verification_tokens: @verification_tokens, clock: @clock
    )
    accounts.register(email: 'player@example.com', password: 'a secure password')
    assert_raises(RuntimeError) { dispatcher.deliver_pending }
    refute_empty @store.users
    refute_empty @store.verifications
    refute_empty @store.outbox
    assert_nil @store.outbox.values.first.sent_at
  end

  def test_outbox_persists_digest_and_metadata_but_not_raw_token
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    message = @store.outbox.values.first

    refute message.to_h.key?(:token)
    assert_match(/\A[0-9a-f]{64}\z/, message.token_digest)
    refute_nil message.nonce
    refute_nil message.key_version
  end

  def test_sent_token_is_not_retained_in_outbox
    sent = []
    mailer = Class.new do
      define_method(:send_verification) { |**value| sent << value[:token] }
    end.new
    dispatcher = DungeonCritters::Server::OutboxDispatcher.new(
      store: @store, mailer: mailer, verification_tokens: @verification_tokens, clock: @clock
    )
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    dispatcher.deliver_pending

    refute_empty sent
    refute_includes @store.outbox.values.map(&:inspect).join, sent.first
  end
end
