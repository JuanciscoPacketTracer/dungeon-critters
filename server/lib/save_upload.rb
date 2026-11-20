# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require 'time'
require_relative '../../scripts/00001 LocalSave/00001 TrainerCodec'

module DungeonCritters
  module Server
    class SaveUploadError < StandardError; end
    class SaveValidationError < SaveUploadError; end
    class SaveAuthenticationError < SaveUploadError; end
    class SaveConflictError < SaveUploadError; end

    SaveVersion = Struct.new(
      :id, :account_id, :cloud_slot_id, :upload_id, :parent_version_id,
      :payload_bytes, :payload_sha256, :payload_length, :codec_schema_version,
      :game_version, :psdk_version, :sequence, :status, :created_at,
      keyword_init: true
    )

    class TrainerCodecValidator
      def initialize(reference_catalog:)
        @codec = DungeonCritters::Persistence::TrainerCodec.new(reference_catalog: reference_catalog)
      end

      def call(document)
        @codec.normalize(document)
      rescue DungeonCritters::Persistence::TrainerCodec::ValidationError => error
        raise SaveValidationError, error.message
      end
    end

    class InMemorySaveStore
      Slot = Struct.new(:id, :account_id, :local_slot_id, :current_version_id, :next_sequence,
                        keyword_init: true)

      attr_reader :slots, :versions, :uploads

      def initialize
        @slots = {}
        @versions = {}
        @uploads = {}
        @mutex = Mutex.new
      end

      def transaction
        @mutex.synchronize do
          snapshot = Marshal.dump([@slots, @versions, @uploads])
          yield
        rescue StandardError
          @slots, @versions, @uploads = Marshal.load(snapshot)
          raise
        end
      end

      def find_upload(account_id, upload_id)
        @uploads[[account_id, upload_id]]
      end

      def lock_upload(_account_id, _upload_id); end

      def lock_slot(account_id, local_slot_id)
        key = [account_id, local_slot_id]
        @slots[key] ||= Slot.new(
          id: SecureRandom.uuid,
          account_id: account_id,
          local_slot_id: local_slot_id,
          current_version_id: nil,
          next_sequence: 0
        )
      end

      def find_version(version_id)
        @versions[version_id]
      end

      def insert_version(version)
        @versions[version.id] = version
        @uploads[[version.account_id, version.upload_id]] = version
      end

      def persist_sequence(_slot); end

      def set_current(slot, version)
        slot.current_version_id = version.id
      end

      def slot(account_id, local_slot_id)
        @slots[[account_id, local_slot_id]]
      end
    end

    class PostgresSaveStore
      Slot = Struct.new(:id, :account_id, :local_slot_id, :current_version_id, :next_sequence,
                        keyword_init: true)
      REQUIRED_TABLES = %w[users cloud_slots save_versions].freeze
      REQUIRED_COLUMNS = {
        'cloud_slots' => %w[id user_id local_slot_id current_version_id next_sequence created_at],
        'save_versions' => %w[
          id user_id cloud_slot_id upload_id parent_version_id sequence status payload
          payload_sha256 payload_length codec_schema_version game_version psdk_version created_at
        ]
      }.freeze
      REQUIRED_CONSTRAINTS = {
        'cloud_slots' => {
          'cloud_slots_user_local_slot_key' => 'UNIQUE (user_id, local_slot_id)',
          'cloud_slots_user_id_key' => 'UNIQUE (user_id, id)',
          'cloud_slots_user_fkey' => 'FOREIGN KEY (user_id) REFERENCES users(id)',
          'cloud_slots_current_version_owner_fkey' =>
            'FOREIGN KEY (current_version_id, user_id, id) ' \
            'REFERENCES save_versions(id, user_id, cloud_slot_id)'
        },
        'save_versions' => {
          'save_versions_user_upload_key' => 'UNIQUE (user_id, upload_id)',
          'save_versions_user_slot_id_key' => 'UNIQUE (id, user_id, cloud_slot_id)',
          'save_versions_user_fkey' => 'FOREIGN KEY (user_id) REFERENCES users(id)',
          'save_versions_cloud_slot_owner_fkey' =>
            'FOREIGN KEY (user_id, cloud_slot_id) REFERENCES cloud_slots(user_id, id)',
          'save_versions_parent_owner_fkey' =>
            'FOREIGN KEY (parent_version_id, user_id, cloud_slot_id) ' \
            'REFERENCES save_versions(id, user_id, cloud_slot_id)'
        }
      }.freeze

      def initialize(connection: nil, url: ENV['DATABASE_URL'])
        require 'pg'
        @connection = connection || PG.connect(url.to_s)
        @bytea_decoder = PG::TextDecoder::Bytea.new
        validate_save_schema
      rescue LoadError => error
        raise SaveUploadError, "pg is required: #{error.message}"
      end

      def self.validate_save_schema(table_names:, columns_by_table:, constraints_by_table:)
        names = table_names.map(&:to_s).uniq
        missing_tables = REQUIRED_TABLES - names
        unless missing_tables.empty?
          raise SaveUploadError,
                "save schema is missing tables: #{missing_tables.join(', ')}; apply " \
                'server/db/001_sessions.sql and server/db/20261119_34_cloud_save_versions.sql'
        end

        missing_columns = REQUIRED_COLUMNS.each_with_object([]) do |(table, required), missing|
          absent = required - columns_by_table.fetch(table, []).map(&:to_s)
          absent.each { |column| missing << "#{table}.#{column}" }
        end
        unless missing_columns.empty?
          raise SaveUploadError, "save schema is missing columns: #{missing_columns.join('; ')}"
        end

        missing_constraints = REQUIRED_CONSTRAINTS.each_with_object([]) do |(table, required), missing|
          actual = constraints_by_table.fetch(table, {})
          required.each do |name, definition|
            actual_definition = actual[name]
            missing << "#{table}.#{name}" unless actual_definition&.include?(definition)
          end
        end
        return if missing_constraints.empty?

        raise SaveUploadError,
              "save schema is missing constraints: #{missing_constraints.join(', ')}; apply " \
              'server/db/20261119_34_cloud_save_versions.sql'
      end

      def transaction
        @connection.transaction { yield }
      end

      def find_upload(account_id, upload_id)
        row = @connection.exec_params(
          'SELECT id, user_id, cloud_slot_id, upload_id, parent_version_id, payload,
                  payload_sha256, payload_length, codec_schema_version, game_version,
                  psdk_version, sequence, status, created_at
             FROM save_versions
            WHERE user_id = $1 AND upload_id = $2',
          [account_id, upload_id]
        ).first
        version_from_row(row) if row
      end

      def lock_upload(account_id, upload_id)
        @connection.exec_params(
          'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
          ["#{account_id}:#{upload_id}"]
        )
      end

      def lock_slot(account_id, local_slot_id)
        @connection.exec_params(
          'INSERT INTO cloud_slots (id, user_id, local_slot_id)
           VALUES ($1, $2, $3)
           ON CONFLICT (user_id, local_slot_id) DO NOTHING',
          [SecureRandom.uuid, account_id, local_slot_id]
        )
        row = @connection.exec_params(
          'SELECT id, user_id, local_slot_id, current_version_id, next_sequence
             FROM cloud_slots
            WHERE user_id = $1 AND local_slot_id = $2
            FOR UPDATE',
          [account_id, local_slot_id]
        ).first
        raise SaveUploadError, 'cloud slot was not created' unless row

        Slot.new(
          id: row['id'],
          account_id: row['user_id'],
          local_slot_id: row['local_slot_id'],
          current_version_id: row['current_version_id'],
          next_sequence: Integer(row['next_sequence'])
        )
      end

      def find_version(version_id)
        row = @connection.exec_params(
          'SELECT id, user_id, cloud_slot_id, upload_id, parent_version_id, payload,
                  payload_sha256, payload_length, codec_schema_version, game_version,
                  psdk_version, sequence, status, created_at
             FROM save_versions
            WHERE id = $1',
          [version_id]
        ).first
        version_from_row(row) if row
      end

      def insert_version(version)
        @connection.exec_params(
          'INSERT INTO save_versions
             (id, user_id, cloud_slot_id, upload_id, parent_version_id, sequence, status,
              payload, payload_sha256, payload_length, codec_schema_version, game_version,
              psdk_version, created_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)',
          [
            version.id, version.account_id, version.cloud_slot_id, version.upload_id,
            version.parent_version_id, version.sequence, version.status, version.payload_bytes,
            version.payload_sha256, version.payload_length, version.codec_schema_version,
            version.game_version, version.psdk_version, version.created_at
          ]
        )
      end

      def persist_sequence(slot)
        @connection.exec_params(
          'UPDATE cloud_slots SET next_sequence = $1 WHERE id = $2 AND user_id = $3',
          [slot.next_sequence, slot.id, slot.account_id]
        )
      end

      def set_current(slot, version)
        @connection.exec_params(
          'UPDATE cloud_slots SET current_version_id = $1 WHERE id = $2 AND user_id = $3',
          [version.id, slot.id, slot.account_id]
        )
      end

      private

      def validate_save_schema
        table_rows = @connection.exec(
          "SELECT table_name FROM information_schema.tables " \
          "WHERE table_schema = current_schema() AND table_name IN " \
          "('users', 'cloud_slots', 'save_versions')"
        )
        column_rows = @connection.exec(
          "SELECT table_name, column_name FROM information_schema.columns " \
          "WHERE table_schema = current_schema() AND table_name IN " \
          "('cloud_slots', 'save_versions')"
        )
        constraint_rows = @connection.exec(
          "SELECT t.relname AS table_name, c.conname, pg_get_constraintdef(c.oid) AS definition " \
          "FROM pg_constraint AS c " \
          "JOIN pg_class AS t ON t.oid = c.conrelid " \
          "JOIN pg_namespace AS n ON n.oid = t.relnamespace " \
          "WHERE n.nspname = current_schema() " \
          "AND t.relname IN ('cloud_slots', 'save_versions')"
        )
        columns_by_table = column_rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, columns|
          columns[row['table_name']] << row['column_name']
        end
        constraints_by_table = constraint_rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, constraints|
          constraints[row['table_name']][row['conname']] = row['definition']
        end
        self.class.validate_save_schema(
          table_names: table_rows.map { |row| row['table_name'] },
          columns_by_table: columns_by_table,
          constraints_by_table: constraints_by_table
        )
      end

      def version_from_row(row)
        SaveVersion.new(
          id: row['id'],
          account_id: row['user_id'],
          cloud_slot_id: row['cloud_slot_id'],
          upload_id: row['upload_id'],
          parent_version_id: row['parent_version_id'],
          payload_bytes: @bytea_decoder.decode(row.fetch('payload')),
          payload_sha256: row['payload_sha256'],
          payload_length: Integer(row['payload_length']),
          codec_schema_version: Integer(row['codec_schema_version']),
          game_version: row['game_version'],
          psdk_version: row['psdk_version'],
          sequence: Integer(row['sequence']),
          status: row['status'],
          created_at: Time.parse(row['created_at'].to_s)
        )
      end
    end

    class SessionAuthenticator
      def initialize(session_service:)
        @session_service = session_service
      end

      def call(env)
        authorization = env['HTTP_AUTHORIZATION'].to_s
        token = authorization.delete_prefix('Bearer ').strip
        raise SaveAuthenticationError, 'authentication required' if token.empty?

        current = @session_service.current(access_token: token)
        account_id = current.fetch('user_id')
        raise SaveAuthenticationError, 'invalid account identity' unless account_id.is_a?(String) && !account_id.empty?

        account_id
      rescue SaveAuthenticationError
        raise
      rescue StandardError => error
        raise SaveAuthenticationError, "authentication failed: #{error.class}"
      end
    end

    class SaveUploadService
      MAX_PAYLOAD_BYTES = 10 * 1024 * 1024
      MAX_UPLOAD_ID_LENGTH = 128
      MAX_SLOT_LENGTH = 64
      MAX_VERSION_LENGTH = 128
      MAX_METADATA_LENGTH = 128
      METADATA_KEYS = %i[codec_schema_version game_version psdk_version].freeze

      def initialize(store:, payload_validator:, clock: -> { Time.now.utc })
        @store = store
        @payload_validator = payload_validator
        @clock = clock
      end

      def upload(account_id:, local_slot_id:, upload_id:, parent_version_id:, metadata:, payload_bytes:, payload_sha256:)
        validate_identity(account_id, local_slot_id, upload_id, parent_version_id)
        raw = exact_bytes(payload_bytes)
        actual_hash = Digest::SHA256.hexdigest(raw)
        reject_unless(payload_sha256 == actual_hash, 'payload hash mismatch')

        document = parse_payload(raw)
        validate_metadata(metadata, document)
        @payload_validator.call(document)

        @store.transaction do
          @store.lock_upload(account_id, upload_id)
          slot = @store.lock_slot(account_id, local_slot_id)
          existing = @store.find_upload(account_id, upload_id)
          if existing
            return result(existing) if same_upload?(existing, slot, parent_version_id, metadata, raw, actual_hash)

            raise SaveConflictError, 'upload_id was already used for a different upload'
          end

          current = slot.current_version_id && @store.find_version(slot.current_version_id)
          validate_parent!(parent_version_id, account_id, slot, current)
          status = parent_matches?(current, parent_version_id) ? 'accepted' : 'conflict'

          slot.next_sequence += 1
          version = SaveVersion.new(
            id: SecureRandom.uuid,
            account_id: account_id,
            cloud_slot_id: slot.id,
            upload_id: upload_id,
            parent_version_id: parent_version_id,
            payload_bytes: raw,
            payload_sha256: actual_hash,
            payload_length: raw.bytesize,
            codec_schema_version: metadata.fetch(:codec_schema_version),
            game_version: metadata.fetch(:game_version),
            psdk_version: metadata.fetch(:psdk_version),
            sequence: slot.next_sequence,
            status: status,
            created_at: @clock.call
          )
          @store.insert_version(version)
          @store.persist_sequence(slot)
          @store.set_current(slot, version) if status == 'accepted'
          result(version)
        end
      end

      private

      def validate_identity(account_id, local_slot_id, upload_id, parent_version_id)
        reject_unless(account_id.is_a?(String) && !account_id.empty?, 'account is required')
        reject_unless(local_slot_id.is_a?(String) && local_slot_id.length.between?(1, MAX_SLOT_LENGTH),
                      'invalid local slot')
        reject_unless(upload_id.is_a?(String) && upload_id.length.between?(1, MAX_UPLOAD_ID_LENGTH),
                      'invalid upload_id')
        reject_unless(parent_version_id.nil? || valid_version_id?(parent_version_id), 'invalid parent_version_id')
      end

      def exact_bytes(payload_bytes)
        reject_unless(payload_bytes.is_a?(String), 'payload is required')
        raw = payload_bytes.dup.force_encoding(Encoding::BINARY)
        reject_unless(raw.bytesize <= MAX_PAYLOAD_BYTES, 'payload is too large')
        utf8 = raw.dup.force_encoding(Encoding::UTF_8)
        reject_unless(utf8.valid_encoding?, 'payload must be UTF-8')
        raw.freeze
      end

      def parse_payload(raw)
        JSON.parse(raw.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError => error
        raise SaveValidationError, "invalid JSON: #{error.message}"
      end

      def validate_metadata(metadata, document)
        reject_unless(metadata.is_a?(Hash) && metadata.keys.sort == METADATA_KEYS.sort, 'invalid metadata')
        schema_version = metadata.fetch(:codec_schema_version)
        reject_unless(schema_version.is_a?(Integer) && schema_version == document['schema_version'],
                      'schema version mismatch')
        %i[game_version psdk_version].each do |key|
          value = metadata.fetch(key)
          reject_unless(value.is_a?(String) && value.length.between?(1, MAX_METADATA_LENGTH),
                        "invalid #{key}")
        end
      end

      def validate_parent!(parent_version_id, account_id, slot, current)
        return if parent_version_id.nil?

        parent = @store.find_version(parent_version_id)
        reject_unless(parent && parent.account_id == account_id && parent.cloud_slot_id == slot.id,
                      'parent version does not belong to this cloud slot')
        return if current && current.id == parent.id
      end

      def same_upload?(version, slot, parent_version_id, metadata, raw, actual_hash)
        version.cloud_slot_id == slot.id &&
          version.parent_version_id == parent_version_id &&
          version.codec_schema_version == metadata[:codec_schema_version] &&
          version.game_version == metadata[:game_version] &&
          version.psdk_version == metadata[:psdk_version] &&
          version.payload_length == raw.bytesize &&
          version.payload_sha256 == actual_hash &&
          version.payload_bytes == raw
      end

      def parent_matches?(current, parent_version_id)
        current.nil? ? parent_version_id.nil? : current.id == parent_version_id
      end

      def valid_version_id?(value)
        value.is_a?(String) && value.length.between?(1, MAX_VERSION_LENGTH)
      end

      def result(version)
        {
          'version_id' => version.id,
          'parent_version_id' => version.parent_version_id,
          'sequence' => version.sequence,
          'status' => version.status,
          'payload_sha256' => version.payload_sha256
        }
      end

      def reject_unless(condition, message)
        raise SaveValidationError, message unless condition
      end
    end

    class SaveUploadApp
      def initialize(service:, authenticator:, request_id: -> { SecureRandom.uuid })
        @service = service
        @authenticator = authenticator
        @request_id = request_id
      end

      def call(env)
        request_id = @request_id.call
        return method_not_allowed(request_id) unless env['REQUEST_METHOD'] == 'POST'

        account_id = @authenticator.call(env)
        content_type = env.fetch('CONTENT_TYPE', '')
        raise SaveValidationError, 'invalid content type' unless content_type.is_a?(String)

        content_type = content_type.downcase
        raise SaveValidationError, 'content type must be application/json UTF-8' unless
          content_type.start_with?('application/json') && content_type.include?('utf-8')

        local_slot_id = route_slot(env.fetch('PATH_INFO', ''))
        upload_id = required_header(env, 'UPLOAD_ID')
        payload_sha256 = required_sha256_header(env, 'PAYLOAD_SHA256')
        codec_schema_version = required_integer_header(env, 'CODEC_SCHEMA_VERSION')
        game_version = required_text_header(env, 'GAME_VERSION')
        psdk_version = required_text_header(env, 'PSDK_VERSION')
        payload = read_limited(
          env.fetch('rack.input'),
          SaveUploadService::MAX_PAYLOAD_BYTES,
          content_length: env.fetch('CONTENT_LENGTH', '')
        )
        metadata = {
          codec_schema_version: codec_schema_version,
          game_version: game_version,
          psdk_version: psdk_version
        }
        result = @service.upload(
          account_id: account_id,
          local_slot_id: local_slot_id,
          upload_id: upload_id,
          parent_version_id: optional_header(env, 'PARENT_VERSION_ID'),
          metadata: metadata,
          payload_bytes: payload,
          payload_sha256: payload_sha256
        )
        json(200, result, request_id)
      rescue SaveAuthenticationError
        problem(401, 'authentication_failed', request_id)
      rescue SaveConflictError
        problem(409, 'upload_conflict', request_id)
      rescue SaveValidationError
        problem(422, 'invalid_upload', request_id)
      rescue KeyError
        problem(400, 'invalid_request', request_id)
      end

      private

      def route_slot(path)
        match = %r{\A/v1/saves/([^/]+)/versions\z}.match(path)
        raise SaveValidationError, 'invalid save route' unless match

        match[1]
      end

      def read_limited(input, limit, content_length:)
        length = parse_content_length(content_length)
        raise SaveValidationError, 'payload is too large' if length > limit

        data = String.new(encoding: Encoding::BINARY)
        while data.bytesize <= limit
          chunk = input.read([16 * 1024, limit + 1 - data.bytesize].min)
          break if chunk.nil? || chunk.empty?
          raise SaveValidationError, 'invalid request body' unless chunk.is_a?(String)

          data << chunk
        end
        raise SaveValidationError, 'payload is too large' if data.bytesize > limit

        data
      rescue ArgumentError
        raise SaveValidationError, 'invalid content length'
      end

      def parse_content_length(value)
        return 0 if value.nil?

        raise SaveValidationError, 'invalid content length' unless value.is_a?(String)
        return 0 if value.empty?
        raise SaveValidationError, 'invalid content length' unless /\A[0-9]+\z/.match?(value)

        Integer(value, 10)
      end

      def header(env, name)
        env["HTTP_#{name}"] || env[name]
      end

      def required_header(env, name)
        value = header(env, name)
        raise SaveValidationError, "missing #{name.downcase}" unless value.is_a?(String) && !value.empty?

        value
      end

      def required_text_header(env, name)
        value = required_header(env, name)
        raise SaveValidationError, "invalid #{name.downcase}" if value.length > SaveUploadService::MAX_METADATA_LENGTH

        value
      end

      def required_integer_header(env, name)
        value = required_header(env, name)
        raise SaveValidationError, "invalid #{name.downcase}" unless /\A[0-9]+\z/.match?(value)

        Integer(value, 10)
      end

      def required_sha256_header(env, name)
        value = required_header(env, name)
        raise SaveValidationError, "invalid #{name.downcase}" unless /\A[0-9a-f]{64}\z/.match?(value)

        value
      end

      def optional_header(env, name)
        value = header(env, name)
        return nil if value.nil?
        raise SaveValidationError, "invalid #{name.downcase}" unless value.is_a?(String) && !value.empty?

        value
      end

      def method_not_allowed(request_id)
        [405, {'Allow' => 'POST', 'Content-Type' => 'application/problem+json', 'X-Request-Id' => request_id},
         [JSON.generate('code' => 'method_not_allowed', 'request_id' => request_id)]]
      end

      def json(status, data, request_id)
        [status, {'Content-Type' => 'application/json', 'X-Request-Id' => request_id}, [JSON.generate(data)]]
      end

      def problem(status, code, request_id)
        [status, {'Content-Type' => 'application/problem+json', 'X-Request-Id' => request_id},
         [JSON.generate('code' => code, 'request_id' => request_id)]]
      end
    end
  end
end
