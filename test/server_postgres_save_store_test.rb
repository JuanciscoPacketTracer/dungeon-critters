# frozen_string_literal: true

require 'digest'
require 'delegate'
require 'json'
require 'minitest/autorun'
require 'pg'
require 'securerandom'
require 'uri'
require_relative '../server/lib/save_upload'

class ServerPostgresSaveStoreTest < Minitest::Test
  SESSIONS_MIGRATION = File.expand_path('../server/db/001_sessions.sql', __dir__)
  RETRY_MIGRATION = File.expand_path('../server/db/002_outbox_retry_state.sql', __dir__)
  SAVE_MIGRATION = File.expand_path('../server/db/20261119_34_cloud_save_versions.sql', __dir__)
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
    @connection.exec(File.read(SESSIONS_MIGRATION))
    @account_id = SecureRandom.uuid
    @connection.exec_params(
      'INSERT INTO users (id, email, password_digest) VALUES ($1, $2, $3)',
      [@account_id, "#{@account_id}@example.test", 'test-digest']
    )
  end

  def teardown
    @connection&.exec("DROP SCHEMA IF EXISTS #{@connection.quote_ident(@schema)} CASCADE") if @schema
    @connection&.close
  end

  def test_applies_migration_twice
    @connection.exec(File.read(RETRY_MIGRATION))
    @connection.exec(File.read(SAVE_MIGRATION))
    @connection.exec(File.read(SAVE_MIGRATION))

    assert_equal 1, scalar('SELECT count(*) FROM pg_tables WHERE tablename = $1', ['cloud_slots'])
    assert_equal 1, scalar('SELECT count(*) FROM pg_tables WHERE tablename = $1', ['save_versions'])
    assert_final_schema(@connection)
  end

  def test_new_installation_applies_all_migrations_and_validates_final_schema
    with_temporary_schema('issue34_new') do |connection|
      connection.exec(File.read(SESSIONS_MIGRATION))
      connection.exec(File.read(RETRY_MIGRATION))
      connection.exec(File.read(SAVE_MIGRATION))

      assert_final_schema(connection)
      DungeonCritters::Server::PostgresSaveStore.new(connection: connection)
    end
  end

  def test_upgrade_from_issue23_applies_retry_then_save_migration
    assert_equal 0, scalar('SELECT count(*) FROM pg_tables WHERE tablename IN ($1, $2)',
                            ['cloud_slots', 'save_versions'])
    @connection.exec(File.read(RETRY_MIGRATION))
    @connection.exec(File.read(SAVE_MIGRATION))

    assert_final_schema(@connection)
    DungeonCritters::Server::PostgresSaveStore.new(connection: @connection)
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
        { result: service.upload(**upload_arguments(payload)) }
      rescue StandardError => error
        { error: error.class.name }
      ensure
        connection&.close
      end
    end

    outcomes = threads.map(&:value)
    errors = outcomes.filter_map { |outcome| outcome[:error] }
    unless errors.empty?
      diagnostic = same_upload_diagnostic(payload)
      flunk JSON.generate(
        'concurrent_errors' => errors,
        'same_upload_mismatches' => diagnostic.fetch(:mismatches),
        'persisted_versions' => diagnostic.fetch(:version_count),
        'persisted_slots' => diagnostic.fetch(:slot_count)
      )
    end

    results = outcomes.map { |outcome| outcome.fetch(:result) }

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

  def test_round_trips_utf8_and_escaped_json_bytes_through_postgres
    apply_migration
    payload = '{"schema_version":1,"text":"é \u2603","slash":"\\\\","quote":"\\""}'
    digest = Digest::SHA256.hexdigest(payload.b)
    slot_id = SecureRandom.uuid
    version_id = SecureRandom.uuid
    @connection.exec_params(
      'INSERT INTO cloud_slots (id, user_id, local_slot_id) VALUES ($1, $2, $3)',
      [slot_id, @account_id, '1']
    )
    @connection.exec_params(
      <<~SQL,
        INSERT INTO save_versions
          (id, user_id, cloud_slot_id, upload_id, sequence, status, payload,
           payload_sha256, payload_length, codec_schema_version, game_version, psdk_version)
        VALUES ($1, $2, $3, $4, 1, 'accepted', decode($5, 'hex'), $6, $7, 1, $8, $9)
      SQL
      [version_id, @account_id, slot_id, 'upload-1', payload.unpack1('H*'), digest,
       payload.bytesize, 'game', 'psdk']
    )
    @connection.exec_params(
      'UPDATE cloud_slots SET current_version_id = $1, next_sequence = 1 WHERE id = $2',
      [version_id, slot_id]
    )

    store = DungeonCritters::Server::PostgresSaveStore.new(connection: @connection)
    service = service_for(store)

    version = store.find_upload(@account_id, 'upload-1')
    replay = service.upload(**upload_arguments(payload))

    assert_equal payload.b, version.payload_bytes
    assert_equal version_id, replay.fetch('version_id')
    assert_equal 1, scalar('SELECT count(*) FROM save_versions')
    assert_equal "é ☃", JSON.parse(version.payload_bytes).fetch('text')
    assert_includes version.payload_bytes, '\\u2603'
    assert_includes version.payload_bytes, '\\\\'
  end

  private

  def set_search_path(connection)
    connection.exec("SET search_path TO #{connection.quote_ident(@schema)}")
  end

  def apply_migration
    @connection.exec(File.read(RETRY_MIGRATION))
    @connection.exec(File.read(SAVE_MIGRATION))
  end

  def with_temporary_schema(prefix)
    connection = PG.connect(DATABASE_URL)
    schema = "#{prefix}_#{SecureRandom.hex(8)}"
    connection.exec("CREATE SCHEMA #{connection.quote_ident(schema)}")
    connection.exec("SET search_path TO #{connection.quote_ident(schema)}")
    yield connection
  ensure
    if connection
      connection.exec("DROP SCHEMA IF EXISTS #{connection.quote_ident(schema)} CASCADE")
      connection.close
    end
  end

  def assert_final_schema(connection)
    columns = connection.exec(
      "SELECT table_name, column_name FROM information_schema.columns " \
      "WHERE table_schema = current_schema() AND table_name IN ('cloud_slots', 'save_versions')"
    ).group_by { |row| row['table_name'] }
    expected_types = DungeonCritters::Server::PostgresSaveStore::REQUIRED_COLUMN_TYPES
    assert_equal expected_types['cloud_slots'].keys.sort,
                 columns.fetch('cloud_slots').map { |row| row['column_name'] }.sort
    assert_equal expected_types['save_versions'].keys.sort,
                 columns.fetch('save_versions').map { |row| row['column_name'] }.sort
    expected_types.each do |table, required|
      actual = columns.fetch(table).to_h { |row| [row['column_name'], row['data_type']] }
      required.each { |column, type| assert_equal type, actual.fetch(column) }
    end

    constraints = connection.exec(
      "SELECT t.relname AS table_name, c.conname, c.contype, c.convalidated, " \
      "c.confdeltype, c.confupdtype, rt.relname AS referenced_table, " \
      "to_json(ARRAY(SELECT a.attname FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) " \
      "JOIN pg_attribute AS a ON a.attrelid = c.conrelid AND a.attnum = k.attnum " \
      "ORDER BY k.ord)) AS columns, " \
      "to_json(ARRAY(SELECT a.attname FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, ord) " \
      "JOIN pg_attribute AS a ON a.attrelid = c.confrelid AND a.attnum = k.attnum " \
      "ORDER BY k.ord)) AS referenced_columns " \
      "FROM pg_constraint AS c " \
      "JOIN pg_class AS t ON t.oid = c.conrelid " \
      "JOIN pg_namespace AS n ON n.oid = t.relnamespace " \
      "LEFT JOIN pg_class AS rt ON rt.oid = c.confrelid " \
      "WHERE n.nspname = current_schema() AND t.relname IN ('cloud_slots', 'save_versions')"
    ).group_by { |row| row['table_name'] }
    DungeonCritters::Server::PostgresSaveStore::REQUIRED_CONSTRAINTS.each do |table, required|
      actual = constraints.fetch(table).to_h do |row|
        [row['conname'], {
          'type' => row['contype'],
          'columns' => JSON.parse(row['columns']),
          'validated' => row['convalidated'] == 't',
          'referenced_table' => row['referenced_table'],
          'referenced_columns' => JSON.parse(row['referenced_columns'] || '[]'),
          'on_delete' => row['confdeltype'],
          'on_update' => row['confupdtype']
        }]
      end
      required.each do |name, expected|
        observed = actual.fetch(name)
        assert_equal expected[:type], observed['type']
        assert_equal expected[:columns], observed['columns']
        assert observed['validated']
        next unless expected[:type] == 'f'

        assert_equal expected[:referenced_table], observed['referenced_table']
        assert_equal expected[:referenced_columns], observed['referenced_columns']
        assert_equal expected[:on_delete], observed['on_delete']
        assert_equal expected[:on_update], observed['on_update']
      end
    end
  end

  def scalar(sql, params = [])
    @connection.exec_params(sql, params).first.values.first.to_i
  end

  def same_upload_diagnostic(payload)
    store = DungeonCritters::Server::PostgresSaveStore.new(connection: @connection)
    existing = store.find_upload(@account_id, 'upload-1')
    slot = @connection.exec_params(
      'SELECT id FROM cloud_slots WHERE user_id = $1 AND local_slot_id = $2',
      [@account_id, '1']
    ).first
    return { mismatches: ['missing_existing_version'], version_count: 0, slot_count: slot ? 1 : 0 } unless existing

    slot_id = slot && slot['id']
    expected_hash = Digest::SHA256.hexdigest(payload)
    checks = {
      cloud_slot_id: existing.cloud_slot_id == slot_id,
      parent_version_id: existing.parent_version_id.nil?,
      codec_schema_version: existing.codec_schema_version == 1,
      game_version: existing.game_version == 'game',
      psdk_version: existing.psdk_version == 'psdk',
      payload_length: existing.payload_length == payload.bytesize,
      payload_sha256: existing.payload_sha256 == expected_hash,
      payload_bytes: existing.payload_bytes == payload.b
    }
    {
      mismatches: checks.filter_map { |field, matches| field.to_s unless matches },
      version_count: scalar('SELECT count(*) FROM save_versions'),
      slot_count: scalar('SELECT count(*) FROM cloud_slots')
    }
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
