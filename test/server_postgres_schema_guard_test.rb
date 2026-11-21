# frozen_string_literal: true

require 'minitest/autorun'
require 'pg'
require 'securerandom'
require 'uri'

require_relative '../server/lib/save_upload'

class ServerPostgresSchemaGuardTest < Minitest::Test
  DATABASE_URL = ENV['POSTGRES_TEST_DATABASE_URL']
  ISOLATED_DATABASE = 'dungeon_critters_issue34_test'
  SESSIONS_MIGRATION = File.expand_path('../server/db/001_sessions.sql', __dir__)
  RETRY_MIGRATION = File.expand_path('../server/db/002_outbox_retry_state.sql', __dir__)
  SAVE_MIGRATION = File.expand_path('../server/db/20261119_34_cloud_save_versions.sql', __dir__)

  def setup
    skip 'POSTGRES_TEST_DATABASE_URL is not configured' unless DATABASE_URL
    uri = URI.parse(DATABASE_URL)
    skip 'refusing to run against a non-isolated database' unless
      uri.host == 'localhost' && uri.path == "/#{ISOLATED_DATABASE}"

    @connection = PG.connect(DATABASE_URL)
    @schema = "issue34_guard_#{SecureRandom.hex(8)}"
    @connection.exec("CREATE SCHEMA #{@connection.quote_ident(@schema)}")
    @connection.exec("SET search_path TO #{@connection.quote_ident(@schema)}")
    [SESSIONS_MIGRATION, RETRY_MIGRATION, SAVE_MIGRATION].each do |path|
      @connection.exec(File.read(path))
    end
  end

  def teardown
    @connection&.exec("DROP SCHEMA IF EXISTS #{@connection.quote_ident(@schema)} CASCADE") if @schema
    @connection&.exec("DROP SCHEMA IF EXISTS #{@decoy_schema} CASCADE") if @decoy_schema
    @connection&.close
  end

  def test_rejects_incorrect_column_type
    @connection.exec('ALTER TABLE save_versions ALTER COLUMN payload_length TYPE bigint')

    assert_guard_rejects(/missing or invalid columns: save_versions\.payload_length/)
  end

  def test_rejects_missing_check_constraint
    @connection.exec('ALTER TABLE save_versions DROP CONSTRAINT save_versions_payload_length_check')

    assert_guard_rejects(/missing or invalid checks: save_versions\.save_versions_payload_length_check/)
  end

  def test_rejects_altered_check_constraint
    @connection.exec('ALTER TABLE save_versions DROP CONSTRAINT save_versions_payload_length_check')
    @connection.exec(
      'ALTER TABLE save_versions ADD CONSTRAINT save_versions_payload_length_check CHECK (payload_length > 0)'
    )

    assert_guard_rejects(/missing or invalid checks: save_versions\.save_versions_payload_length_check/)
  end

  def test_rejects_not_valid_foreign_key
    @connection.exec('ALTER TABLE save_versions DROP CONSTRAINT save_versions_user_fkey')
    @connection.exec(
      'ALTER TABLE save_versions ADD CONSTRAINT save_versions_user_fkey ' \
      'FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE NOT VALID'
    )

    assert_guard_rejects(/missing constraints: save_versions\.save_versions_user_fkey/)
  end

  def test_rejects_incompatible_foreign_key_actions
    @connection.exec('ALTER TABLE cloud_slots DROP CONSTRAINT cloud_slots_user_fkey')
    @connection.exec(
      'ALTER TABLE cloud_slots ADD CONSTRAINT cloud_slots_user_fkey ' \
      'FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT ON UPDATE CASCADE'
    )

    assert_guard_rejects(/missing constraints: cloud_slots\.cloud_slots_user_fkey/)
  end

  def test_rejects_foreign_key_to_homonymous_table_in_another_schema
    @decoy_schema = "issue34_decoy_#{SecureRandom.hex(8)}"
    @connection.exec("CREATE SCHEMA #{@connection.quote_ident(@decoy_schema)}")
    @connection.exec(
      "CREATE TABLE #{@connection.quote_ident(@decoy_schema)}.users (id uuid PRIMARY KEY)"
    )
    @connection.exec('ALTER TABLE cloud_slots DROP CONSTRAINT cloud_slots_user_fkey')
    @connection.exec(
      "ALTER TABLE cloud_slots ADD CONSTRAINT cloud_slots_user_fkey " \
      "FOREIGN KEY (user_id) REFERENCES #{@connection.quote_ident(@decoy_schema)}.users(id) " \
      'ON DELETE CASCADE'
    )

    assert_guard_rejects(/missing constraints: cloud_slots\.cloud_slots_user_fkey/)
  end

  private

  def assert_guard_rejects(message)
    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      DungeonCritters::Server::PostgresSaveStore.new(connection: @connection)
    end
    assert_match message, error.message
  end
end
