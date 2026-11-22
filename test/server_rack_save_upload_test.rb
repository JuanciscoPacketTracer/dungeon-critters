# frozen_string_literal: true

require 'digest'
require 'json'
require 'minitest/autorun'
require 'rack'
require 'rack/mock'

require_relative '../server/lib/dungeon_critters_server'
require_relative '../server/lib/save_upload'

class ServerRackSaveUploadTest < Minitest::Test
  def setup
    @session_store = DungeonCritters::Server::InMemoryStore.new
    @save_store = DungeonCritters::Server::InMemorySaveStore.new
    session_store = @session_store
    @postgres_store_constructor = DungeonCritters::Server::PostgresStore.method(:new)
    DungeonCritters::Server::PostgresStore.define_singleton_method(:new) { |_url| session_store }
    @save_store_constructor = DungeonCritters::Server::PostgresSaveStore.method(:new)
    save_store = @save_store
    DungeonCritters::Server::PostgresSaveStore.define_singleton_method(:new) { save_store }
    @previous_database_url = ENV['DATABASE_URL']
    @previous_catalog = ENV['SAVE_REFERENCE_CATALOG_JSON']
    ENV['DATABASE_URL'] = 'test-only'
    ENV['SAVE_REFERENCE_CATALOG_JSON'] = JSON.generate(
      'species' => ['bunli'],
      'natures' => ['brave'],
      'moves' => ['tackle'],
      'items' => ['poke_ball'],
      'abilities' => ['run_away']
    )
    @hasher = DungeonCritters::Server::PasswordHasher.new
    @session_service = DungeonCritters::Server::SessionService.new(
      store: @session_store, hasher: @hasher, clock: -> { Time.now.utc }
    )
    add_verified_user('account-a', 'player-a@example.com', 'account-a-password')
    add_verified_user('account-b', 'player-b@example.com', 'account-b-password')
    @app, = Rack::Builder.parse_file(File.expand_path('../server/config.ru', __dir__))
    @request = Rack::MockRequest.new(@app)
  end

  def teardown
    DungeonCritters::Server::PostgresStore.define_singleton_method(:new, &@postgres_store_constructor)
    DungeonCritters::Server::PostgresSaveStore.define_singleton_method(:new, &@save_store_constructor)
    ENV['DATABASE_URL'] = @previous_database_url
    ENV['SAVE_REFERENCE_CATALOG_JSON'] = @previous_catalog
  end

  def test_real_roda_mount_authenticates_and_persists_idempotently
    payload = valid_payload
    headers = upload_headers(payload)

    first = @request.post(
      '/v1/saves/1/versions',
      headers.merge('HTTP_AUTHORIZATION' => bearer_token('account-a'), input: payload)
    )
    second = @request.post(
      '/v1/saves/1/versions',
      headers.merge('HTTP_AUTHORIZATION' => bearer_token('account-a'), input: payload)
    )

    assert_equal 200, first.status
    assert_equal JSON.parse(first.body), JSON.parse(second.body)
    assert_equal 1, @save_store.versions.length
  end

  def test_same_roda_app_serves_profile_and_upload_for_authenticated_account
    profile = @request.put(
      '/v1/profile',
      'CONTENT_TYPE' => 'application/json',
      'HTTP_AUTHORIZATION' => bearer_token('account-a'),
      input: JSON.generate('alias' => 'Synthetic_Player')
    )

    assert_equal 200, profile.status
    assert_equal({ 'alias' => 'synthetic_player' }, JSON.parse(profile.body))

    payload = valid_payload
    upload = @request.post(
      '/v1/saves/1/versions',
      upload_headers(payload).merge(
        'HTTP_AUTHORIZATION' => bearer_token('account-a'),
        input: payload
      )
    )

    assert_equal 200, upload.status
    assert_equal 1, @save_store.versions.length
  end

  def test_real_roda_mount_rejects_missing_authentication_without_persisting
    payload = valid_payload
    response = @request.post(
      '/v1/saves/1/versions',
      upload_headers(payload).merge(input: payload)
    )

    assert_equal 401, response.status
    assert_empty_save_store
  end

  def test_real_roda_mount_rejects_invalid_authentication_without_persisting
    payload = valid_payload
    response = @request.post(
      '/v1/saves/1/versions',
      upload_headers(payload).merge(
        'HTTP_AUTHORIZATION' => 'Bearer invalid-access-token',
        input: payload
      )
    )

    assert_equal 401, response.status
    assert_empty_save_store
  end

  def test_upload_uses_the_authenticated_session_identity
    payload = valid_payload
    response = @request.post(
      '/v1/saves/1/versions',
      upload_headers(payload).merge(
        'HTTP_AUTHORIZATION' => bearer_token('account-b'),
        input: payload
      )
    )

    assert_equal 200, response.status
    assert_equal 'account-b', @save_store.versions.values.first.account_id
    assert_equal 'account-b', @save_store.slots.values.first.account_id
  end

  def test_account_cannot_upload_with_another_accounts_parent_version
    payload = valid_payload
    first = @request.post(
      '/v1/saves/1/versions',
      upload_headers(payload).merge(
        'HTTP_AUTHORIZATION' => bearer_token('account-a'),
        input: payload
      )
    )
    parent_version_id = JSON.parse(first.body).fetch('version_id')

    response = @request.post(
      '/v1/saves/1/versions',
      upload_headers(payload).merge(
        'HTTP_AUTHORIZATION' => bearer_token('account-b'),
        'HTTP_UPLOAD_ID' => 'upload-from-account-b',
        'HTTP_PARENT_VERSION_ID' => parent_version_id,
        input: payload
      )
    )

    assert_equal 422, response.status
    assert_equal 1, @save_store.versions.length
    assert_equal 1, @save_store.slots.length
    assert_empty @save_store.uploads.values.reject { |version| version.account_id == 'account-a' }
  end

  private

  def add_verified_user(id, email, password)
    @session_store.users[id] = DungeonCritters::Server::User.new(
      id: id,
      email: email,
      password_digest: @hasher.digest(password),
      verified_at: Time.utc(2026, 1, 1),
      created_at: Time.utc(2026, 1, 1)
    )
  end

  def bearer_token(account_id)
    credentials = {
      'account-a' => ['player-a@example.com', 'account-a-password'],
      'account-b' => ['player-b@example.com', 'account-b-password']
    }.fetch(account_id)
    "Bearer #{@session_service.login(email: credentials[0], password: credentials[1])['access_token']}"
  end

  def assert_empty_save_store
    assert_empty @save_store.slots
    assert_empty @save_store.versions
    assert_empty @save_store.uploads
  end

  def valid_payload
    JSON.generate(
      'schema_version' => 1,
      'trainer' => {
        'name_boy' => 'Ash', 'name_girl' => 'Misty', 'playing_girl' => false,
        'id_boy' => 10, 'id_girl' => 20, 'start_time' => 100, 'play_time' => 3600,
        'badges' => [true, false], 'region' => 0, 'game_version' => 1,
        'current_version' => 1, 'friend_code' => nil
      },
      'party' => ['c1'],
      'storage' => {
        'current_box' => 0, 'current_battle_box' => 0,
        'boxes' => [{'name' => 'Box 1', 'theme' => 1, 'slots' => ['c1']}],
        'battle_boxes' => [{'name' => '#1', 'slots' => ['c1']}],
        'other_party' => [], 'lets_go_follower' => 'c1'
      },
      'critters' => {
        'c1' => {
          'species' => 'bunli', 'level' => 5, 'exp' => 125, 'hp' => 20, 'code' => 99,
          'form' => 0, 'gender' => 1, 'nature' => 'brave', 'shiny' => false,
          'loyalty' => 40, 'ivs' => [1, 2, 3, 4, 5, 6], 'evs' => [0, 1, 2, 3, 4, 5],
          'moves' => ['tackle'], 'held_item' => 'poke_ball', 'ability' => 'run_away',
          'alpha' => true, 'height_scalar' => 17, 'weight_scalar' => 231
        }
      }
    )
  end

  def upload_headers(payload)
    {
      'CONTENT_TYPE' => 'application/json; charset=utf-8',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'HTTP_UPLOAD_ID' => 'upload-1',
      'HTTP_PAYLOAD_SHA256' => Digest::SHA256.hexdigest(payload),
      'HTTP_CODEC_SCHEMA_VERSION' => '1',
      'HTTP_GAME_VERSION' => 'demo-1',
      'HTTP_PSDK_VERSION' => 'psdk-1'
    }
  end
end
