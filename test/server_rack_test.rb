# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'rack'
require 'rack/mock'
require_relative '../server/lib/dungeon_critters_server'
require_relative '../server/lib/save_upload'

class ServerRackTest < Minitest::Test
  def setup
    @database_url = ENV['DATABASE_URL']
    ENV['DATABASE_URL'] = 'local-test-only'
    store = DungeonCritters::Server::InMemoryStore.new
    @original_store_constructor = DungeonCritters::Server::PostgresStore.method(:new)
    @original_save_store_constructor = DungeonCritters::Server::PostgresSaveStore.method(:new)
    DungeonCritters::Server::PostgresStore.define_singleton_method(:new) { |_url| store }
    DungeonCritters::Server::PostgresSaveStore.define_singleton_method(:new) { Object.new }
    @app, = Rack::Builder.parse_file(File.expand_path('../server/config.ru', __dir__))
    @request = Rack::MockRequest.new(@app)
  end

  def teardown
    DungeonCritters::Server::PostgresStore.define_singleton_method(:new, &@original_store_constructor)
    DungeonCritters::Server::PostgresSaveStore.define_singleton_method(:new, &@original_save_store_constructor)
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

  def test_production_public_api_url_requires_https
    assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::ResendMailer.new(
        api_key: 'test-key', from: 'noreply@example.com', public_api_url: 'http://api.example.test',
        environment: 'production', client: ->(_payload) {}
      )
    end
  end

  def test_production_requires_public_api_url
    assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::ResendMailer.new(
        api_key: 'test-key', from: 'noreply@example.com', public_api_url: nil,
        environment: 'production', client: ->(_payload) {}
      )
    end
  end

  def test_production_requires_versioned_verification_secrets
    previous_secrets = ENV.delete('VERIFICATION_TOKEN_SECRETS')
    previous_version = ENV.delete('VERIFICATION_TOKEN_KEY_VERSION')
    begin
      assert_raises(DungeonCritters::Server::ConfigurationError) do
        DungeonCritters::Server::VerificationTokenCodec.from_env(environment: 'production')
      end
    ensure
      ENV['VERIFICATION_TOKEN_SECRETS'] = previous_secrets if previous_secrets
      ENV['VERIFICATION_TOKEN_KEY_VERSION'] = previous_version if previous_version
    end
  end

  def test_development_uses_localhost_when_public_api_url_is_missing
    payload = nil
    mailer = DungeonCritters::Server::ResendMailer.new(
      api_key: 'test-key', from: 'noreply@example.com', public_api_url: nil,
      environment: 'development', client: ->(value) { payload = value }
    )

    mailer.send_verification(email: 'player@example.com', token: 'a' * 32)

    assert_includes payload[:html], 'http://localhost:9292/v1/accounts/verify-email#token='
  end
end
