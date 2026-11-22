# frozen_string_literal: true

require 'digest'
require 'json'
require 'minitest/autorun'
require 'pg'
require 'rack'
require 'rack/mock'
require 'securerandom'
require 'timeout'
require 'uri'

require_relative '../server/lib/dungeon_critters_server'

class ServerPostgresRackIntegrationTest < Minitest::Test
  DATABASE_URL = ENV['POSTGRES_TEST_DATABASE_URL']
  ISOLATED_DATABASE = 'dungeon_critters_issue34_test'
  ACCESS_TOKEN = 'synthetic-access-token'

  def setup
    skip 'POSTGRES_TEST_DATABASE_URL is not configured' unless DATABASE_URL
    uri = URI.parse(DATABASE_URL)
    skip 'refusing to run against a non-isolated database' unless
      uri.host == 'localhost' && uri.path == "/#{ISOLATED_DATABASE}"

    @connection = PG.connect(DATABASE_URL)
    @schema = "issue34_rack_#{SecureRandom.hex(8)}"
    @connection.exec("CREATE SCHEMA #{@connection.quote_ident(@schema)}")
    @connection.exec("SET search_path TO #{@connection.quote_ident(@schema)}")
    apply_schema
    seed_account_and_session

    @previous_database_url = ENV['DATABASE_URL']
    @previous_catalog = ENV['SAVE_REFERENCE_CATALOG_JSON']
    @previous_pgoptions = ENV['PGOPTIONS']
    @database_url = database_url_for_schema
    ENV['DATABASE_URL'] = @database_url
    ENV['PGOPTIONS'] = nil
    ENV['SAVE_REFERENCE_CATALOG_JSON'] = JSON.generate(reference_catalog)
    @app, = Rack::Builder.parse_file(File.expand_path('../server/config.ru', __dir__))
    @request = Rack::MockRequest.new(@app)
  end

  def teardown
    ENV['DATABASE_URL'] = @previous_database_url
    ENV['SAVE_REFERENCE_CATALOG_JSON'] = @previous_catalog
    ENV['PGOPTIONS'] = @previous_pgoptions
    @connection&.exec("DROP SCHEMA IF EXISTS #{@connection.quote_ident(@schema)} CASCADE") if @schema
    @connection&.close
  end

  def test_real_rack_upload_replays_exact_bytes_and_rejects_invalid_payload_without_writes
    payload = valid_payload
    headers = upload_headers(payload, upload_id: 'upload-1')

    first = @request.post(
      '/v1/saves/1/versions',
      headers.merge('HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}", input: payload)
    )
    second = @request.post(
      '/v1/saves/1/versions',
      headers.merge('HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}", input: payload)
    )

    assert_equal 200, first.status
    assert_equal JSON.parse(first.body), JSON.parse(second.body)
    assert_equal payload.unpack1('H*'), query_value('SELECT encode(payload, $1) FROM save_versions', ['hex'])
    assert_equal 1, scalar('SELECT count(*) FROM save_versions')
    assert_equal 1, scalar('SELECT count(*) FROM cloud_slots')

    invalid = 'not-json'
    response = @request.post(
      '/v1/saves/1/versions',
      upload_headers(invalid, upload_id: 'invalid-upload').merge(
        'HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}",
        input: invalid
      )
    )

    assert_equal 422, response.status
    assert_equal 1, scalar('SELECT count(*) FROM save_versions')
    assert_equal 1, scalar('SELECT count(*) FROM cloud_slots')
  end

  def test_same_authenticated_app_serves_profile_and_upload
    profile = @request.put(
      '/v1/profile',
      {
        'CONTENT_TYPE' => 'application/json',
        'HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}",
        input: JSON.generate('alias' => 'Public_Name')
      }
    )

    assert_equal 200, profile.status
    assert_equal({ 'alias' => 'public_name' }, JSON.parse(profile.body))
    assert_equal 1, scalar('SELECT count(*) FROM public_profiles')

    payload = valid_payload
    upload = @request.post(
      '/v1/saves/1/versions',
      upload_headers(payload, upload_id: 'profile-upload-1').merge(
        'HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}",
        input: payload
      )
    )

    assert_equal 200, upload.status
    assert_equal 1, scalar('SELECT count(*) FROM save_versions')
  end

  def test_reusing_an_expired_alias_deletes_its_postgres_reservation
    first = @request.put(
      '/v1/profile',
      {
        'CONTENT_TYPE' => 'application/json',
        'HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}",
        input: JSON.generate('alias' => 'FirstAlias')
      }
    )
    assert_equal 200, first.status

    @connection.exec("UPDATE public_profiles SET alias_changed_at = now() - interval '31 days'")
    second = @request.put(
      '/v1/profile',
      {
        'CONTENT_TYPE' => 'application/json',
        'HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}",
        input: JSON.generate('alias' => 'SecondAlias')
      }
    )
    assert_equal 200, second.status
    assert_equal 1, scalar('SELECT count(*) FROM public_alias_reservations WHERE alias_normalized = $1',
                           ['firstalias'])

    @connection.exec("UPDATE public_alias_reservations SET released_at = now() - interval '91 days'")
    @connection.exec("UPDATE public_profiles SET alias_changed_at = now() - interval '31 days'")
    reused = @request.put(
      '/v1/profile',
      {
        'CONTENT_TYPE' => 'application/json',
        'HTTP_AUTHORIZATION' => "Bearer #{ACCESS_TOKEN}",
        input: JSON.generate('alias' => 'FirstAlias')
      }
    )

    assert_equal 200, reused.status
    assert_equal 0, scalar('SELECT count(*) FROM public_alias_reservations WHERE alias_normalized = $1',
                           ['firstalias'])
  end

  def test_postgres_read_observes_one_snapshot_while_another_connection_writes
    user_id = @connection.exec('SELECT user_id FROM sessions LIMIT 1').getvalue(0, 0)
    now = Time.now.utc
    @connection.exec_params(
      'INSERT INTO public_profiles (user_id, public_alias, alias_normalized, alias_changed_at, created_at)
       VALUES ($1, $2, $3, $4, $5)',
      [user_id, 'old_alias', 'old_alias', now, now]
    )

    writer = PG.connect(@database_url)
    writer.exec("SET search_path TO #{@connection.quote_ident(@schema)}")
    store = DungeonCritters::Server::PostgresStore.new(@database_url)
    writer_ready = Queue.new
    reader_started = Queue.new
    release_writer = Queue.new
    observed = Queue.new

    writer_thread = Thread.new do
      writer.transaction do
        writer.exec('SELECT pg_advisory_xact_lock(23)')
        writer.exec_params('UPDATE users SET email = $1 WHERE id = $2', ['new@example.test', user_id])
        writer.exec('LOCK TABLE public_profiles IN ACCESS EXCLUSIVE MODE')
        writer.exec_params(
          'UPDATE public_profiles SET public_alias = $1, alias_normalized = $2 WHERE user_id = $3',
          ['new_alias', 'new_alias', user_id]
        )
        writer_ready << true
        release_writer.pop
      end
    end
    writer_ready.pop

    reader_thread = Thread.new do
      reader_started << true
      observed << store.read do
        [store.users.fetch(user_id).email, store.profiles.fetch(user_id).public_alias]
      end
    end
    reader_started.pop

    reader_pid = store.instance_variable_get(:@connection).backend_pid
    Timeout.timeout(5) do
      loop do
        waiting = @connection.exec_params(
          'SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1',
          [reader_pid]
        ).values.dig(0, 0)
        break if waiting == 'Lock'

        sleep 0.01
      end
    end

    release_writer << true
    writer_thread.join
    assert_equal ['new@example.test', 'new_alias'], observed.pop
    reader_thread.join
  ensure
    release_writer << true if release_writer
    writer_thread&.join
    reader_thread&.join
    writer&.close
    store&.instance_variable_get(:@connection)&.close
  end

  private

  def apply_schema
    [
      File.expand_path('../server/db/001_sessions.sql', __dir__),
      File.expand_path('../server/db/002_outbox_retry_state.sql', __dir__),
      File.expand_path('../server/db/20261119_34_cloud_save_versions.sql', __dir__),
      File.expand_path('../server/db/20261120_25_public_profiles.sql', __dir__)
    ].each { |path| @connection.exec(File.read(path)) }
  end

  def database_url_for_schema
    uri = URI.parse(DATABASE_URL)
    options = "options=-c%20search_path%3D#{URI.encode_www_form_component(@schema)}"
    uri.query = [uri.query, options].compact.join('&')
    uri.to_s
  end

  def seed_account_and_session
    user_id = SecureRandom.uuid
    now = Time.now.utc
    @connection.exec_params(
      'INSERT INTO users (id, email, password_digest, verified_at, created_at) VALUES ($1, $2, $3, $4, $5)',
      [user_id, "#{user_id}@example.test", 'synthetic-digest', now, now]
    )
    @connection.exec_params(
      <<~SQL,
        INSERT INTO sessions
          (id, user_id, access_token_digest, refresh_token_digest, access_expires_at,
           refresh_expires_at, revoked_at, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, NULL, $7)
      SQL
      [SecureRandom.uuid, user_id, Digest::SHA256.hexdigest(ACCESS_TOKEN),
       Digest::SHA256.hexdigest('synthetic-refresh-token'), now + 900, now + 86_400, now]
    )
  end

  def scalar(sql, params = [])
    @connection.exec_params(sql, params).first.values.first.to_i
  end

  def query_value(sql, params = [])
    @connection.exec_params(sql, params).first.values.first
  end

  def reference_catalog
    {
      'species' => ['bunli'],
      'natures' => ['brave'],
      'moves' => ['tackle'],
      'items' => ['poke_ball'],
      'abilities' => ['run_away']
    }
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
        'boxes' => [{ 'name' => 'Box 1', 'theme' => 1, 'slots' => ['c1'] }],
        'battle_boxes' => [{ 'name' => '#1', 'slots' => ['c1'] }],
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

  def upload_headers(payload, upload_id:)
    {
      'CONTENT_TYPE' => 'application/json; charset=utf-8',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'HTTP_UPLOAD_ID' => upload_id,
      'HTTP_PAYLOAD_SHA256' => Digest::SHA256.hexdigest(payload),
      'HTTP_CODEC_SCHEMA_VERSION' => '1',
      'HTTP_GAME_VERSION' => 'demo-1',
      'HTTP_PSDK_VERSION' => 'psdk-1'
    }
  end
end
