# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'rack/mock'
require_relative '../../server/lib/dungeon_critters_server'

class ProfileRackTest < Minitest::Test
  def setup
    @store = DungeonCritters::Server::InMemoryStore.new
    @session_service = Class.new do
      def current(access_token:)
        raise DungeonCritters::Server::AuthenticationError unless access_token == 'access-token'

        { 'user_id' => 'account-a' }
      end
    end.new
    @profile_service = DungeonCritters::Server::ProfileService.new(
      store: @store,
      clock: -> { Time.utc(2026, 1, 1) }
    )
    @app = DungeonCritters::Server::App.new(
      account_service: Class.new { def register(**); {}; end }.new,
      session_service: @session_service,
      profile_service: @profile_service
    )
  end

  def test_put_and_get_profile_expose_only_public_alias
    request = Rack::MockRequest.new(@app)
    response = request.put(
      '/v1/profile',
      'CONTENT_TYPE' => 'application/json',
      'HTTP_AUTHORIZATION' => 'Bearer access-token',
      input: JSON.generate('alias' => 'Public_Name')
    )

    assert_equal 200, response.status
    assert_equal({ 'alias' => 'public_name' }, JSON.parse(response.body))
    refute_includes response.body, 'email'
    refute_includes response.body, 'trainer'

    response = request.get(
      '/v1/profile',
      'HTTP_AUTHORIZATION' => 'Bearer access-token'
    )
    assert_equal 200, response.status
    assert_equal 'public_name', JSON.parse(response.body).fetch('alias')
  end

  def test_profile_requires_authentication
    response = Rack::MockRequest.new(@app).get('/v1/profile')

    assert_equal 401, response.status
    assert_equal 'authentication_failed', JSON.parse(response.body).fetch('code')
  end

  def test_profile_reports_alias_uniqueness_as_a_conflict
    @profile_service.set_alias(user_id: 'account-b', public_alias: 'TakenAlias')

    response = Rack::MockRequest.new(@app).put(
      '/v1/profile',
      'CONTENT_TYPE' => 'application/json',
      'HTTP_AUTHORIZATION' => 'Bearer access-token',
      input: JSON.generate('alias' => 'takenalias')
    )

    assert_equal 409, response.status
    assert_equal 'account_unavailable', JSON.parse(response.body).fetch('code')
  end
end
