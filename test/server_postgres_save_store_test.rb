# frozen_string_literal: true

require 'digest'
require 'delegate'
require 'minitest/autorun'
require 'pg'
require 'securerandom'
require 'uri'
require_relative '../server/lib/save_upload'

class ServerPostgresSaveStoreTest < Minitest::Test
  MIGRATION = File.expand_path('../server/db/20261119_34_cloud_save_versions.sql', __dir__)
  ISOLATED_DATABASE = 'dungeon_critters_issue34_test'
  DATABASE_URL = ENV['POSTGRES_TEST_DATABASE_URL']

  def setup
    skip 'POSTGRES_TEST_DATABASE_URL is not configured' unless DATABASE_URL
    uri = URI.parse(DATABASE_URL)
    skip 'refusing to run against a non-isolated database' unless
      uri.host == 'localhost' && uri.path == "/#{ISOLATED_DATABASE}"

    @connection = PG.connect(DATABASE_URL)
    @schema = "issue34_test_#{SecureRandom.hex(8)}"
    @connection.exec("CREATE SCHEMA #{@connection.quote_ident(@schema)}")
    set_search_path(@connection)
    @connection.exec('CREATE TABLE users (id uuid PRIMARY KEY)')
    @account_id = SecureRandom.uuid
    @connection.exec_params('INSERT INTO users (id) VALUES ($1)', [@account_id])
  end

  def teardown
    @connection&.exec("DROP SCHEMA IF EXISTS #{@connection.quote_ident(@schema)} CASCADE") if @schema
    @connection&.close
  end

  def test_applies_migration_twice
    sql = File.read(MIGRATION)

    @connection.exec(sql)
    @connection.exec(sql)

    assert_equal 1, scalar('SELECT count(*) FROM pg_tables WHERE tablename = $1', ['cloud_slots'])
    assert_equal 1, scalar('SELECT count(*) FROM pg_tables WHERE tablename = $1', ['save_versions'])
    assert_equal 1, scalar(<<~SQL, ['save_versions_user_upload_key'])
      SELECT count(*)
        FROM pg_constraint
       WHERE conname = $1
    SQL
  end

  def test_enforces_account_and_slot_foreign_keys
    apply_migration
    unknown_account = SecureRandom.uuid

    assert_raises(PG::ForeignKeyViolation) do
      @connection.exec_params(
        'INSERT INTO cloud_slots (id, user_id, local_slot_id) VALUES ($1, $2, $3)',
        [SecureRandom.uuid, unknown_account, '1']
      )
    end

    slot_id = SecureRandom.uuid
    @connection.exec_params(
      'INSERT INTO cloud_slots (id, user_id, local_slot_id) VALUES ($1, $2, $3)',
      [slot_id, @account_id, '1']
    )
    assert_raises(PG::ForeignKeyViolation) do
      @connection.exec_params(
        <<~SQL,
          INSERT INTO save_versions
            (id, user_id, cloud_slot_id, upload_id, sequence, status, payload,
             payload_sha256, payload_length, codec_schema_version, game_version, psdk_version)
          VALUES ($1, $2, $3, $4, 1, 'accepted', $5, $6, 1, 1, 'game', 'psdk')
        SQL
        [SecureRandom.uuid, unknown_account, slot_id, 'upload-1', 'x', Digest::SHA256.hexdigest('x')]
      )
    end
  end

  def test_serializes_concurrent_retries_of_one_upload
    apply_migration
    payload = '{"schema_version":1}'
    threads = 8.times.map do
      Thread.new do
        connection = PG.connect(DATABASE_URL)
        set_search_path(connection)
        service = service_for(DungeonCritters::Server::PostgresSaveStore.new(connection: connection))
        service.upload(**upload_arguments(payload))
      ensure
        connection&.close
      end
    end

    results = threads.map(&:value)

    assert_equal 1, results.map { |result| result.fetch('version_id') }.uniq.length
    assert_equal 1, scalar('SELECT count(*) FROM save_versions')
    assert_equal 1, scalar('SELECT count(*) FROM cloud_slots')
  end

  def test_rolls_back_store_transaction_when_persisting_current_version_fails
    apply_migration
    inner_store = DungeonCritters::Server::PostgresSaveStore.new(connection: @connection)
    failing_store = Class.new(SimpleDelegator) do
      def set_current(*)
        raise 'injected current-version failure'
      end
    end.new(inner_store)
    service = service_for(failing_store)

    assert_raises(RuntimeError) { service.upload(**upload_arguments('{"schema_version":1}')) }

    assert_equal 0, scalar('SELECT count(*) FROM save_versions')
    assert_equal 0, scalar('SELECT count(*) FROM cloud_slots')
  end

  private

  def set_search_path(connection)
    connection.exec("SET search_path TO #{connection.quote_ident(@schema)}")
  end

  def apply_migration
    @connection.exec(File.read(MIGRATION))
  end

  def scalar(sql, params = [])
    @connection.exec_params(sql, params).first.values.first.to_i
  end

  def service_for(store)
    DungeonCritters::Server::SaveUploadService.new(
      store: store,
      payload_validator: ->(document) {
        raise DungeonCritters::Server::SaveValidationError unless document['schema_version'] == 1
      },
      clock: -> { Time.utc(2026, 1, 1) }
    )
  end

  def upload_arguments(payload)
    {
      account_id: @account_id,
      local_slot_id: '1',
      upload_id: 'upload-1',
      parent_version_id: nil,
      metadata: { codec_schema_version: 1, game_version: 'game', psdk_version: 'psdk' },
      payload_bytes: payload,
      payload_sha256: Digest::SHA256.hexdigest(payload)
    }
  end
end
