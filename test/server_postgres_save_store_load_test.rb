# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'

class ServerPostgresSaveStoreLoadTest < Minitest::Test
  def test_injected_connection_loads_pg_before_initializing_bytea_decoder
    script = <<~RUBY
      require #{File.expand_path('../server/lib/save_upload', __dir__).inspect}

      connection = Object.new
      def connection.exec(*)
        []
      end

      begin
        DungeonCritters::Server::PostgresSaveStore.new(connection: connection)
      rescue DungeonCritters::Server::SaveUploadError => error
        abort(error.message) unless defined?(PG::TextDecoder::Bytea)
      rescue NameError => error
        warn error.full_message
        exit 2
      end
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      '-I', File.expand_path('../server/lib', __dir__),
      '-e', script
    )

    assert status.success?, stderr
  end
end
