# frozen_string_literal: true

require 'digest'
require 'json'
require 'stringio'
require_relative 'test_helper'
require_relative '../server/lib/save_upload'

class ServerSaveUploadTest < Minitest::Test
  def test_postgres_store_guard_rejects_an_unapplied_save_migration
    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      DungeonCritters::Server::PostgresSaveStore.validate_save_schema(
        table_names: ['users', 'sessions'],
        columns_by_table: {},
        constraints_by_table: {}
      )
    end

    assert_match(/20261119_34_cloud_save_versions\.sql/, error.message)
    assert_match(/cloud_slots, save_versions/, error.message)
  end

  def test_postgres_store_guard_rejects_incomplete_save_columns
    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      DungeonCritters::Server::PostgresSaveStore.validate_save_schema(
        table_names: %w[users cloud_slots save_versions],
        columns_by_table: {
          'cloud_slots' => { 'id' => 'uuid', 'user_id' => 'uuid' },
          'save_versions' => { 'id' => 'uuid', 'user_id' => 'uuid' }
        },
        constraints_by_table: full_constraints
      )
    end

    assert_match(/missing or invalid columns/, error.message)
    assert_includes error.message, 'cloud_slots.local_slot_id'
    assert_includes error.message, 'save_versions.payload'
  end

  def test_postgres_store_guard_rejects_missing_isolation_constraints
    constraints = full_constraints
    constraints['save_versions'].delete('save_versions_parent_owner_fkey')
    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      DungeonCritters::Server::PostgresSaveStore.validate_save_schema(
        table_names: %w[users cloud_slots save_versions],
        columns_by_table: full_columns,
        constraints_by_table: constraints
      )
    end

    assert_match(/missing constraints/, error.message)
    assert_includes error.message, 'save_versions.save_versions_parent_owner_fkey'
  end

  def test_postgres_store_guard_rejects_an_incorrect_column_type
    columns = full_columns
    columns['save_versions']['payload'] = 'text'

    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      validate_schema(columns: columns)
    end

    assert_match(/missing or invalid columns/, error.message)
    assert_includes error.message, 'save_versions.payload'
  end

  def test_postgres_store_guard_accepts_complete_schema
    validate_schema
  end

  def test_postgres_store_guard_rejects_not_valid_constraints
    constraints = full_constraints
    constraints['save_versions']['save_versions_cloud_slot_owner_fkey']['validated'] = false

    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      validate_schema(constraints: constraints)
    end

    assert_match(/missing constraints/, error.message)
    assert_includes error.message, 'save_versions.save_versions_cloud_slot_owner_fkey'
  end

  def test_postgres_store_guard_rejects_incompatible_foreign_key_actions
    constraints = full_constraints
    constraints['save_versions']['save_versions_parent_owner_fkey']['on_delete'] = 'c'

    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      validate_schema(constraints: constraints)
    end

    assert_match(/missing constraints/, error.message)
    assert_includes error.message, 'save_versions.save_versions_parent_owner_fkey'
  end

  def test_postgres_store_guard_rejects_a_foreign_key_from_another_schema
    constraints = full_constraints
    constraints['save_versions']['save_versions_cloud_slot_owner_fkey']['referenced_schema_current'] = false

    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      validate_schema(constraints: constraints)
    end

    assert_match(/missing constraints/, error.message)
    assert_includes error.message, 'save_versions.save_versions_cloud_slot_owner_fkey'
  end

  def test_postgres_store_guard_rejects_missing_or_invalid_checks
    constraints = full_constraints
    constraints['save_versions']['save_versions_status_check']['definition'] = 'CHECK ((status IS NOT NULL))'

    error = assert_raises(DungeonCritters::Server::SaveUploadError) do
      validate_schema(constraints: constraints)
    end

    assert_match(/missing or invalid checks/, error.message)
    assert_includes error.message, 'save_versions.save_versions_status_check'
  end

  def full_columns
    DungeonCritters::Server::PostgresSaveStore::REQUIRED_COLUMN_TYPES.transform_values(&:dup)
  end

  def full_constraints
    DungeonCritters::Server::PostgresSaveStore::REQUIRED_CONSTRAINTS.transform_values do |constraints|
      constraints.transform_values do |expected|
        {
          'type' => expected[:type],
          'columns' => expected[:columns],
          'validated' => true,
          'referenced_table' => expected[:referenced_table],
          'referenced_columns' => expected[:referenced_columns],
          'referenced_schema_current' => expected.fetch(:referenced_schema_current, true),
          'on_delete' => expected[:on_delete],
          'on_update' => expected[:on_update],
          'definition' => nil
        }
      end
    end.tap do |constraints|
      DungeonCritters::Server::PostgresSaveStore::REQUIRED_CHECKS.each do |table, checks|
        checks.each do |name, pattern|
          constraints[table][name] = {
            'type' => 'c',
            'validated' => true,
            'definition' => pattern.source
          }
        end
      end
    end
  end

  def validate_schema(columns: full_columns, constraints: full_constraints)
    DungeonCritters::Server::PostgresSaveStore.validate_save_schema(
      table_names: %w[users cloud_slots save_versions],
      columns_by_table: columns,
      constraints_by_table: constraints
    )
  end

  def setup
    @store = DungeonCritters::Server::InMemorySaveStore.new
    @service = DungeonCritters::Server::SaveUploadService.new(
      store: @store,
      payload_validator: ->(document) {
        raise DungeonCritters::Server::SaveValidationError, 'invalid codec document' unless document['schema_version'] == 1
      },
      clock: -> { Time.utc(2026, 1, 1) }
    )
    @metadata = { codec_schema_version: 1, game_version: 'demo-1', psdk_version: 'psdk-1' }
  end

  def test_accepts_raw_bytes_and_preserves_them
    payload = '{"schema_version":1,"trainer":{},"party":[],"storage":{},"critters":{}}'
    result = upload(payload, account_id: 'account-a', upload_id: 'upload-1')

    version = @store.versions.fetch(result.fetch('version_id'))
    assert_equal payload.b, version.payload_bytes
    assert_equal Digest::SHA256.hexdigest(payload), version.payload_sha256
    assert_equal 'accepted', result['status']
  end

  def test_replays_identical_upload_without_creating_a_second_version
    payload = '{"schema_version":1}'
    first = upload(payload, account_id: 'account-a', upload_id: 'upload-1')
    second = upload(payload, account_id: 'account-a', upload_id: 'upload-1')

    assert_equal first, second
    assert_equal 1, @store.versions.length
  end

  def test_rejects_same_upload_id_for_different_exact_bytes
    upload('{"schema_version":1}', account_id: 'account-a', upload_id: 'upload-1')

    assert_raises(DungeonCritters::Server::SaveConflictError) do
      upload("{\n  \"schema_version\": 1\n}", account_id: 'account-a', upload_id: 'upload-1')
    end
    assert_equal 1, @store.versions.length
  end

  def test_invalid_payload_does_not_persist_anything
    assert_raises(DungeonCritters::Server::SaveValidationError) do
      upload('not-json', account_id: 'account-a', upload_id: 'upload-1')
    end

    assert_empty @store.slots
    assert_empty @store.versions
    assert_empty @store.uploads
  end

  def test_rejects_a_hash_mismatch_without_persisting
    assert_raises(DungeonCritters::Server::SaveValidationError) do
      @service.upload(
        account_id: 'account-a',
        local_slot_id: '1',
        upload_id: 'upload-1',
        parent_version_id: nil,
        metadata: @metadata,
        payload_bytes: '{"schema_version":1}',
        payload_sha256: '0' * 64
      )
    end

    assert_empty @store.slots
    assert_empty @store.versions
    assert_empty @store.uploads
  end

  def test_rejects_changed_metadata_for_an_existing_upload_id
    payload = '{"schema_version":1}'
    upload(payload, account_id: 'account-a', upload_id: 'upload-1')

    assert_raises(DungeonCritters::Server::SaveConflictError) do
      @service.upload(
        account_id: 'account-a',
        local_slot_id: '1',
        upload_id: 'upload-1',
        parent_version_id: nil,
        metadata: @metadata.merge(game_version: 'demo-2'),
        payload_bytes: payload,
        payload_sha256: Digest::SHA256.hexdigest(payload)
      )
    end
    assert_equal 1, @store.versions.length
  end

  def test_same_upload_id_is_isolated_between_accounts
    first = upload('{"schema_version":1}', account_id: 'account-a', upload_id: 'upload-1')
    other = upload('{"schema_version":1}', account_id: 'account-b', upload_id: 'upload-1')

    refute_equal first['version_id'], other['version_id']
    assert_equal 2, @store.versions.length
    assert_equal 1, @store.slots.values.count { |slot| slot.account_id == 'account-a' }
    assert_equal 1, @store.slots.values.count { |slot| slot.account_id == 'account-b' }
  end

  def test_stale_parent_becomes_conflict_without_replacing_current_version
    first = upload('{"schema_version":1}', account_id: 'account-a', upload_id: 'upload-1')
    second = upload('{"schema_version":1}', account_id: 'account-a', upload_id: 'upload-2',
                    parent_version_id: first['version_id'])
    stale = upload('{"schema_version":1}', account_id: 'account-a', upload_id: 'upload-3',
                   parent_version_id: first['version_id'])

    assert_equal 'conflict', stale['status']
    slot = @store.slot('account-a', '1')
    assert_equal second['version_id'], slot.current_version_id
  end

  def test_rejects_a_parent_from_another_account
    first = upload('{"schema_version":1}', account_id: 'account-a', upload_id: 'upload-1')

    assert_raises(DungeonCritters::Server::SaveValidationError) do
      upload('{"schema_version":1}', account_id: 'account-b', upload_id: 'upload-2',
             parent_version_id: first['version_id'])
    end
    assert_equal 1, @store.versions.length
  end

  def test_serializes_concurrent_retries_of_the_same_upload
    payload = '{"schema_version":1}'
    results = 8.times.map do
      Thread.new do
        upload(payload, account_id: 'account-a', upload_id: 'upload-1')
      end
    end.map(&:value)

    assert_equal 1, results.map { |result| result['version_id'] }.uniq.length
    assert_equal 1, @store.versions.length
  end

  def test_session_authenticator_uses_the_authenticated_session_identity
    session_service = Struct.new(:token) do
      def current(access_token:)
        raise 'wrong token' unless access_token == token

        {'user_id' => 'account-a'}
      end
    end.new('access-token')
    authenticator = DungeonCritters::Server::SessionAuthenticator.new(session_service: session_service)

    assert_equal 'account-a', authenticator.call('HTTP_AUTHORIZATION' => 'Bearer access-token')
  end

  def test_http_endpoint_passes_raw_body_and_headers_to_service
    payload = '{"schema_version":1}'
    app = DungeonCritters::Server::SaveUploadApp.new(
      service: @service,
      authenticator: ->(_env) { 'account-a' },
      request_id: -> { 'request-1' }
    )
    status, headers, body = app.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/saves/1/versions',
      'HTTP_UPLOAD_ID' => 'upload-1',
      'HTTP_PAYLOAD_SHA256' => Digest::SHA256.hexdigest(payload),
      'HTTP_CODEC_SCHEMA_VERSION' => '1',
      'HTTP_GAME_VERSION' => 'demo-1',
      'HTTP_PSDK_VERSION' => 'psdk-1',
      'CONTENT_TYPE' => 'application/json; charset=utf-8',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'rack.input' => StringIO.new(payload)
    )

    assert_equal 200, status
    assert_equal 'application/json', headers['Content-Type']
    assert_equal 'request-1', headers['X-Request-Id']
    assert_equal 'accepted', JSON.parse(body.join).fetch('status')
  end

  def test_http_endpoint_rejects_missing_and_malformed_required_headers
    payload = '{"schema_version":1}'
    cases = [
      ->(env) { env.delete('HTTP_UPLOAD_ID') },
      ->(env) { env['HTTP_CODEC_SCHEMA_VERSION'] = '1partial' },
      ->(env) { env.delete('HTTP_GAME_VERSION') },
      ->(env) { env['HTTP_PAYLOAD_SHA256'] = 'a' * 63 },
      ->(env) { env['CONTENT_LENGTH'] = '12partial' }
    ]

    cases.each do |mutate|
      env = valid_http_env(payload)
      mutate.call(env)
      status, = build_app.call(env)
      assert_equal 422, status
    end
    assert_empty @store.versions
  end

  def test_http_endpoint_rejects_non_post_without_reading_body
    app = DungeonCritters::Server::SaveUploadApp.new(
      service: @service,
      authenticator: -> { flunk 'authentication must not run for GET' },
      request_id: -> { 'request-1' }
    )
    input = Class.new do
      def read(*)
        raise 'body must not be read'
      end
    end.new

    status, headers, body = app.call(
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => '/v1/saves/1/versions',
      'rack.input' => input
    )

    assert_equal 405, status
    assert_equal 'POST', headers['Allow']
    assert_equal 'method_not_allowed', JSON.parse(body.join).fetch('code')
  end

  def test_http_endpoint_rejects_a_body_over_the_read_limit
    payload = '{"schema_version":1}'
    app = DungeonCritters::Server::SaveUploadApp.new(
      service: @service,
      authenticator: ->(_env) { 'account-a' },
      request_id: -> { 'request-1' }
    )

    status, = app.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/saves/1/versions',
      'CONTENT_TYPE' => 'application/json; charset=utf-8',
      'CONTENT_LENGTH' => (DungeonCritters::Server::SaveUploadService::MAX_PAYLOAD_BYTES + 1).to_s,
      'rack.input' => StringIO.new(payload)
    )

    assert_equal 422, status
    assert_empty @store.versions
  end

  def test_http_endpoint_limits_a_chunked_body_without_content_length
    payload = 'x' * (DungeonCritters::Server::SaveUploadService::MAX_PAYLOAD_BYTES + 1)
    app = DungeonCritters::Server::SaveUploadApp.new(
      service: @service,
      authenticator: ->(_env) { 'account-a' },
      request_id: -> { 'request-1' }
    )

    status, = app.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/saves/1/versions',
      'CONTENT_TYPE' => 'application/json; charset=utf-8',
      'rack.input' => StringIO.new(payload)
    )

    assert_equal 422, status
    assert_empty @store.versions
  end
  private

  def build_app
    DungeonCritters::Server::SaveUploadApp.new(
      service: @service,
      authenticator: ->(_env) { 'account-a' },
      request_id: -> { 'request-1' }
    )
  end

  def valid_http_env(payload)
    {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/v1/saves/1/versions',
      'HTTP_UPLOAD_ID' => 'upload-1',
      'HTTP_PAYLOAD_SHA256' => Digest::SHA256.hexdigest(payload),
      'HTTP_CODEC_SCHEMA_VERSION' => '1',
      'HTTP_GAME_VERSION' => 'demo-1',
      'HTTP_PSDK_VERSION' => 'psdk-1',
      'CONTENT_TYPE' => 'application/json; charset=utf-8',
      'CONTENT_LENGTH' => payload.bytesize.to_s,
      'rack.input' => StringIO.new(payload)
    }
  end

  def upload(payload, account_id:, upload_id:, parent_version_id: nil)
    @service.upload(
      account_id: account_id,
      local_slot_id: '1',
      upload_id: upload_id,
      parent_version_id: parent_version_id,
      metadata: @metadata,
      payload_bytes: payload,
      payload_sha256: Digest::SHA256.hexdigest(payload)
    )
  end
end
