# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../server/lib/dungeon_critters_server'

class ServerMigrationTest < Minitest::Test
  def setup
    @migration = File.read(File.expand_path('../server/db/001_sessions.sql', __dir__))
  end

  def test_schema_creation_is_idempotent
    assert_equal 4, @migration.scan(/CREATE TABLE IF NOT EXISTS/).length
    assert_includes @migration, 'CREATE INDEX IF NOT EXISTS sessions_user_active_idx'
  end

  def test_session_columns_match_token_storage_contract
    assert_includes @migration, 'access_token_digest text NOT NULL UNIQUE'
    assert_includes @migration, 'refresh_token_digest text NOT NULL UNIQUE'
    assert_includes @migration, 'access_expires_at timestamptz NOT NULL'
    assert_includes @migration, 'refresh_expires_at timestamptz NOT NULL'
    assert_includes @migration, 'token_digest text NOT NULL'
    assert_includes @migration, 'nonce text NOT NULL'
    assert_includes @migration, 'key_version text NOT NULL'
    refute_includes @migration, 'token text NOT NULL'
    refute_match(/^\s+token_digest text NOT NULL UNIQUE$/m, @migration)
  end

  def test_startup_guard_rejects_legacy_outbox_columns
    error = assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::PostgresStore.validate_outbox_columns(
        %w[id email token sent_at claimed_at created_at]
      )
    end

    assert_includes error.message, 'legacy token column'
  end

  def test_startup_guard_accepts_initial_outbox_columns
    columns = %w[id email user_id token_digest nonce expires_at key_version sent_at claimed_at created_at]

    assert_nil DungeonCritters::Server::PostgresStore.validate_outbox_columns(columns)
  end

  def test_startup_guard_rejects_partial_database_schema
    error = assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::PostgresStore.validate_schema('users' => %w[id email])
    end

    assert_includes error.message, 'missing tables'
  end
end
