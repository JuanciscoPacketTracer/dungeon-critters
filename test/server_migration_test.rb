# frozen_string_literal: true

require 'minitest/autorun'

class ServerMigrationTest < Minitest::Test
  def setup
    @migration = File.read(File.expand_path('../server/db/001_sessions.sql', __dir__))
  end

  def test_schema_creation_is_idempotent
    assert_equal 3, @migration.scan(/CREATE TABLE IF NOT EXISTS/).length
    assert_includes @migration, 'CREATE INDEX IF NOT EXISTS sessions_user_active_idx'
  end

  def test_session_columns_match_token_storage_contract
    assert_includes @migration, 'access_token_digest text NOT NULL UNIQUE'
    assert_includes @migration, 'refresh_token_digest text NOT NULL UNIQUE'
    assert_includes @migration, 'access_expires_at timestamptz NOT NULL'
    assert_includes @migration, 'refresh_expires_at timestamptz NOT NULL'
    refute_match(/^\s+token_digest text NOT NULL UNIQUE$/m, @migration)
  end
end
