# frozen_string_literal: true

require 'digest'
require 'json'
require 'minitest/autorun'
require 'pg'
require 'securerandom'
require 'uri'

require_relative 'test_helper'
require_relative '../server/lib/save_upload'

class ServerPostgresByteaTest < Minitest::Test
  def test_text_bytea_decoder_round_trips_exact_utf8_and_escaped_json_bytes
    payload = '{"schema_version":1,"text":"é \u2603","slash":"\\\\","quote":"\\""}'
    row = version_row(payload)
    store = DungeonCritters::Server::PostgresSaveStore.new(
      connection: FakeConnection.new(row)
    )

    version = store.find_upload('account-a', 'upload-1')

    assert_equal payload.b, version.payload_bytes
    assert_equal Digest::SHA256.hexdigest(payload.b), version.payload_sha256
    assert_equal "é ☃", JSON.parse(version.payload_bytes).fetch('text')
    assert_includes version.payload_bytes, '\\u2603'
    assert_includes version.payload_bytes, '\\\\'
  end

  class ServerPostgresByteaIntegrationTest < Minitest::Test
    MIGRATIONS = [
      File.expand_path('../server/db/001_sessions.sql', __dir__),
      File.expand_path('../server/db/20261119_34_cloud_save_versions.sql', __dir__)
    ].freeze

    def setup
      url = ENV['DATABASE_URL'].to_s
      skip 'DATABASE_URL is not set' if url.empty?

      uri = URI.parse(url)
      database_name = uri.path.to_s.delete_prefix('/')
      skip 'DATABASE_URL must target a test database' unless uri.host.to_s.match?(/\A(?:localhost|127\.0\.0\.1|::1)\z/) &&
        database_name.match?(/test/i)

      @connection = PG.connect(url)
      @schema = "save_upload_test_#{SecureRandom.hex(6)}"
      @connection.exec("CREATE SCHEMA #{@connection.quote_ident(@schema)}")
      @connection.exec("SET search_path TO #{@connection.quote_ident(@schema)}")
      MIGRATIONS.each { |path| @connection.exec(File.read(path)) }
    end

    def teardown
      return unless @connection

      @connection.exec("DROP SCHEMA #{@connection.quote_ident(@schema)} CASCADE")
      @connection.close
    end

    def test_real_postgres_read_preserves_bytes_and_replay_is_idempotent
      user_id = SecureRandom.uuid
      slot_id = SecureRandom.uuid
      version_id = SecureRandom.uuid
      payload = '{"schema_version":1,"text":"é \u2603","slash":"\\\\","quote":"\\""}'
      digest = Digest::SHA256.hexdigest(payload.b)

      @connection.exec_params(
        'INSERT INTO users (id, email, password_digest) VALUES ($1, $2, $3)',
        [user_id, "#{user_id}@example.test", 'test-digest']
      )
      @connection.exec_params(
        'INSERT INTO cloud_slots (id, user_id, local_slot_id) VALUES ($1, $2, $3)',
        [slot_id, user_id, '1']
      )
      @connection.exec_params(
        'INSERT INTO save_versions
           (id, user_id, cloud_slot_id, upload_id, sequence, status, payload,
            payload_sha256, payload_length, codec_schema_version, game_version, psdk_version)
         VALUES ($1, $2, $3, $4, 1, $5, decode($6, $7), $8, $9, 1, $10, $11)',
        [version_id, user_id, slot_id, 'upload-1', 'accepted', payload.unpack1('H*'), 'hex',
         digest, payload.bytesize, 'demo-1', 'psdk-1']
      )
      @connection.exec_params(
        'UPDATE cloud_slots SET current_version_id = $1, next_sequence = 1 WHERE id = $2',
        [version_id, slot_id]
      )

      store = DungeonCritters::Server::PostgresSaveStore.new(connection: @connection)
      version = store.find_upload(user_id, 'upload-1')
      assert_equal payload.b, version.payload_bytes

      service = DungeonCritters::Server::SaveUploadService.new(
        store: store,
        payload_validator: ->(document) {
          raise DungeonCritters::Server::SaveValidationError unless document['schema_version'] == 1
        }
      )
      result = service.upload(
        account_id: user_id,
        local_slot_id: '1',
        upload_id: 'upload-1',
        parent_version_id: nil,
        metadata: { codec_schema_version: 1, game_version: 'demo-1', psdk_version: 'psdk-1' },
        payload_bytes: payload,
        payload_sha256: digest
      )

      assert_equal version_id, result.fetch('version_id')
      assert_equal 1, @connection.exec('SELECT count(*) FROM save_versions').first.fetch('count').to_i
    end
  end

  def test_idempotency_replays_a_version_after_postgres_bytea_decode
    payload = '{"schema_version":1,"text":"é \u2603","slash":"\\\\","quote":"\\""}'
    connection = FakeConnection.new(version_row(payload))
    store = DungeonCritters::Server::PostgresSaveStore.new(connection: connection)
    service = DungeonCritters::Server::SaveUploadService.new(
      store: store,
      payload_validator: ->(document) {
        raise DungeonCritters::Server::SaveValidationError unless document['schema_version'] == 1
      }
    )

    result = service.upload(
      account_id: 'account-a',
      local_slot_id: '1',
      upload_id: 'upload-1',
      parent_version_id: nil,
      metadata: { codec_schema_version: 1, game_version: 'demo-1', psdk_version: 'psdk-1' },
      payload_bytes: payload,
      payload_sha256: Digest::SHA256.hexdigest(payload.b)
    )

    assert_equal 'version-1', result.fetch('version_id')
    assert_equal 'accepted', result.fetch('status')
    assert_equal 0, connection.insert_count
  end

  private

  def version_row(payload)
    {
      'id' => 'version-1',
      'user_id' => 'account-a',
      'cloud_slot_id' => 'slot-1',
      'upload_id' => 'upload-1',
      'parent_version_id' => nil,
      'payload' => PG::TextEncoder::Bytea.new.encode(payload.b),
      'payload_sha256' => Digest::SHA256.hexdigest(payload.b),
      'payload_length' => payload.bytesize.to_s,
      'codec_schema_version' => '1',
      'game_version' => 'demo-1',
      'psdk_version' => 'psdk-1',
      'sequence' => '1',
      'status' => 'accepted',
      'created_at' => '2026-01-01 00:00:00+00'
    }
  end

  class FakeConnection
    attr_reader :insert_count

    def initialize(version)
      @version = version
      @insert_count = 0
    end

    def exec(sql)
      if sql.include?('FROM pg_constraint')
        constraints_by_table = DungeonCritters::Server::PostgresSaveStore::REQUIRED_CONSTRAINTS
        checks_by_table = DungeonCritters::Server::PostgresSaveStore::REQUIRED_CHECKS
        rows = constraints_by_table.flat_map do |table, constraints|
          constraints.map do |name, definition|
            {
              'table_name' => table, 'conname' => name, 'contype' => definition[:type],
              'convalidated' => 't', 'confdeltype' => definition[:on_delete],
              'confupdtype' => definition[:on_update],
              'columns' => JSON.generate(definition[:columns]),
              'referenced_table' => definition[:referenced_table],
              'referenced_columns' => JSON.generate(definition[:referenced_columns] || []),
              'referenced_schema_current' => 't',
              'definition' => nil
            }
          end
        end
        return rows + checks_by_table.flat_map do |table, checks|
          checks.map do |name, pattern|
            {
              'table_name' => table, 'conname' => name, 'contype' => 'c',
              'convalidated' => 't', 'confdeltype' => 'a', 'confupdtype' => 'a',
              'columns' => '[]', 'referenced_table' => nil, 'referenced_columns' => '[]',
              'referenced_schema_current' => 't', 'definition' => pattern.source
            }
          end
        end
      end
      if sql.include?('pg_attribute')
        return DungeonCritters::Server::PostgresSaveStore::REQUIRED_COLUMN_TYPES.flat_map do |table, columns|
          columns.map { |column, type| {'table_name' => table, 'column_name' => column, 'data_type' => type} }
        end
      end
      if sql.include?('c.relname AS table_name')
        return [
          {'table_name' => 'users'},
          {'table_name' => 'cloud_slots'},
          {'table_name' => 'save_versions'}
        ]
      end

      []
    end

    def exec_params(sql, _params)
      return [@version] if sql.include?('FROM save_versions')
      return [{
        'id' => 'slot-1',
        'user_id' => 'account-a',
        'local_slot_id' => '1',
        'current_version_id' => 'version-1',
        'next_sequence' => '1'
      }] if sql.include?('FROM cloud_slots')

      @insert_count += 1 if sql.start_with?('INSERT INTO save_versions')
      []
    end

    def transaction
      yield
    end
  end
end
