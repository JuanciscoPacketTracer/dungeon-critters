# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'rack'
require 'rack/mock'
require_relative '../server/lib/dungeon_critters_server'

class ServerRackTest < Minitest::Test
  def setup
    @database_url = ENV['DATABASE_URL']
    ENV['DATABASE_URL'] = 'local-test-only'
    store = DungeonCritters::Server::InMemoryStore.new
    @original_store_constructor = DungeonCritters::Server::PostgresStore.method(:new)
    DungeonCritters::Server::PostgresStore.define_singleton_method(:new) { |_url| store }
    @app, = Rack::Builder.parse_file(File.expand_path('../server/config.ru', __dir__))
    @request = Rack::MockRequest.new(@app)
  end

  def teardown
    DungeonCritters::Server::PostgresStore.define_singleton_method(:new, &@original_store_constructor)
    ENV['DATABASE_URL'] = @database_url
  end

  def test_config_ru_preserves_problem_response_status_headers_and_body
    response = @request.post(
      '/v1/sessions',
      'CONTENT_TYPE' => 'application/json',
      input: JSON.generate('email' => 'player@example.com', 'password' => 'wrong secret')
    )

    assert_equal 401, response.status
    assert_equal 'application/problem+json', response['Content-Type']
    refute_includes response.body, 'wrong secret'
    refute_includes response.body, 'player@example.com'
    refute_empty response['X-Request-Id']
  end

  def test_config_ru_rejects_oversized_request_body
    response = @request.post(
      '/v1/sessions',
      'CONTENT_TYPE' => 'application/json',
      input: 'x' * (DungeonCritters::Server::MAX_BODY_BYTES + 1)
    )

    assert_equal 413, response.status
    assert_equal 'application/problem+json', response['Content-Type']
    refute_includes response.body, 'x' * 100
  end
end
