# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../server/lib/dungeon_critters_server'

class ServerMigrationTest < Minitest::Test
  def setup
    @migration = File.read(File.expand_path('../server/db/001_sessions.sql', __dir__))
    @retry_migration = File.read(File.expand_path('../server/db/002_outbox_retry_state.sql', __dir__))
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
    assert_includes @migration, 'attempts integer NOT NULL DEFAULT 0'
    assert_includes @migration, 'next_attempt_at timestamptz'
    assert_includes @migration, 'terminal_at timestamptz'
    assert_includes @migration, 'claim_token uuid'
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
    columns = %w[id email user_id token_digest nonce expires_at key_version sent_at claimed_at claim_token attempts
                  next_attempt_at terminal_at created_at]

    assert_nil DungeonCritters::Server::PostgresStore.validate_outbox_columns(columns)
  end

  def test_startup_guard_rejects_outbox_without_retry_state
    error = assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::PostgresStore.validate_outbox_columns(
        %w[id email user_id token_digest nonce expires_at key_version sent_at claimed_at created_at]
      )
    end

    assert_includes error.message, 'attempts'
  end

  def test_retry_migration_is_explicit_and_does_not_rewrite_messages
    assert_includes @retry_migration, 'ALTER TABLE email_outbox'
    assert_includes @retry_migration, 'ADD COLUMN IF NOT EXISTS attempts'
    assert_includes @retry_migration, 'ADD COLUMN IF NOT EXISTS next_attempt_at'
    assert_includes @retry_migration, 'ADD COLUMN IF NOT EXISTS terminal_at'
    assert_includes @retry_migration, 'ADD COLUMN IF NOT EXISTS claim_token'
    refute_match(/UPDATE\s+email_outbox/i, @retry_migration)
  end

  def test_startup_guard_rejects_partial_database_schema
    error = assert_raises(DungeonCritters::Server::ConfigurationError) do
      DungeonCritters::Server::PostgresStore.validate_schema('users' => %w[id email])
    end

    assert_includes error.message, 'missing tables'
  end
end
