# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
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
    @accounts = DungeonCritters::Server::AccountService.new(store: @store, hasher: @hasher, mailer: @mailer, clock: @clock)
    @sessions = DungeonCritters::Server::SessionService.new(store: @store, hasher: @hasher, clock: @clock)
  end

  def test_unverified_account_cannot_login
    @accounts.register(email: 'Player@Example.com', password: 'a secure password')
    assert_raises(DungeonCritters::Server::AuthenticationError) do
      @sessions.login(email: 'player@example.com', password: 'a secure password')
    end

    def test_unknown_account_verifies_against_dummy_digest
      assert_raises(DungeonCritters::Server::AuthenticationError) do
        @sessions.login(email: 'missing@example.com', password: 'a secure password')
      end
      assert_includes @hasher.digests, @hasher.dummy_digest
    end
  end

  def test_verification_enables_login
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    refute_empty @sessions.login(email: 'player@example.com', password: 'a secure password')['refresh_token']
  end

  def test_only_five_sessions_remain_and_oldest_is_revoked
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    tokens = 6.times.map { @sessions.login(email: 'player@example.com', password: 'a secure password') }
    assert_equal 5, @store.sessions.values.count { |session| session.revoked_at.nil? }
    assert_raises(DungeonCritters::Server::AuthenticationError) { @sessions.renew(refresh_token: tokens.first['refresh_token']) }
  end

  def test_concurrent_in_memory_logins_keep_five_active_sessions
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    threads = 10.times.map do
      Thread.new { @sessions.login(email: 'player@example.com', password: 'a secure password') }
    end
    threads.each(&:value)
    assert_equal 5, @store.sessions.values.count { |session| session.revoked_at.nil? }
  end

  def test_refresh_rotates_and_revokes_old_token
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    old = @sessions.login(email: 'player@example.com', password: 'a secure password')
    renewed = @sessions.renew(refresh_token: old['refresh_token'])
    refute_equal old['refresh_token'], renewed['refresh_token']
    assert_raises(DungeonCritters::Server::AuthenticationError) { @sessions.renew(refresh_token: old['refresh_token']) }
  end

  def test_expired_access_token_cannot_be_used_but_refresh_token_remains_valid
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    @accounts.verify_email(token: @mailer.messages.first[:token])
    tokens = @sessions.login(email: 'player@example.com', password: 'a secure password')
    @now += DungeonCritters::Server::ACCESS_TOKEN_TTL + 1

    assert_raises(DungeonCritters::Server::AuthenticationError) do
      @sessions.current(access_token: tokens['access_token'])
    end
    refute_empty @sessions.renew(refresh_token: tokens['refresh_token'])['access_token']
  end

  def test_verification_token_is_single_use
    @accounts.register(email: 'player@example.com', password: 'a secure password')
    token = @mailer.messages.first[:token]
    @accounts.verify_email(token: token)
    assert_raises(DungeonCritters::Server::AuthenticationError) { @accounts.verify_email(token: token) }
  end

  def test_access_token_can_read_and_revoke_current_session
    @accounts.register(email: 'player@example.com', password: 'a secure password')
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

  def test_unexpected_resend_error_returns_safe_internal_problem
    failing_mailer = Class.new { def send_verification(**); raise 'RESEND_API_KEY=secret'; end }.new
    accounts = DungeonCritters::Server::AccountService.new(
      store: @store, hasher: @hasher, mailer: failing_mailer, clock: @clock
    )
    app = DungeonCritters::Server::App.new(account_service: accounts, session_service: @sessions)
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
    refute_includes body.join, 'RESEND_API_KEY=secret'
    refute_includes body.join, 'a secure password'
  end

  def test_mailer_failure_rolls_back_account
    failing_mailer = Class.new { def send_verification(**); raise 'transport failed'; end }.new
    accounts = DungeonCritters::Server::AccountService.new(store: @store, hasher: @hasher, mailer: failing_mailer, clock: @clock)
    assert_raises(RuntimeError) { accounts.register(email: 'player@example.com', password: 'a secure password') }
    assert_empty @store.users
    assert_empty @store.verifications
  end
end
