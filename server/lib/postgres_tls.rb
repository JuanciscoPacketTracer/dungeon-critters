# frozen_string_literal: true

require 'uri'

module DungeonCritters
  module Server
    module PostgresTls
      class ConfigurationError < StandardError; end

      DEFAULT_ROOT_CERT = File.expand_path('../certs/supabase-root.crt', __dir__).freeze

      module_function

      def connect(url, environment: ENV.fetch('RACK_ENV', 'development'), root_cert: DEFAULT_ROOT_CERT)
        require 'pg'
        parsed_url = parse_database_url(url)
        return PG.connect(url) unless environment == 'production'

        validate_root_cert!(root_cert)
        validate_requested_ssl_mode!(parsed_url)
        PG.connect(url, sslmode: 'verify-full', sslrootcert: root_cert)
      end

      def validate_root_cert!(root_cert)
        return if File.file?(root_cert)

        raise ConfigurationError, 'Supabase root certificate is missing', cause: nil
      end

      def validate_requested_ssl_mode!(parsed_url)
        query = parsed_url.query.to_s
        params = URI.decode_www_form(query).to_h
        sslmode = params['sslmode']
        return if sslmode.nil? || sslmode == 'verify-full'

        raise ConfigurationError, 'DATABASE_URL sslmode must be verify-full', cause: nil
      rescue URI::InvalidURIError, ArgumentError
        raise ConfigurationError, 'invalid DATABASE_URL', cause: nil
      end

      def parse_database_url(url)
        URI.parse(url.to_s)
      rescue URI::InvalidURIError, ArgumentError, TypeError
        raise ConfigurationError, 'invalid DATABASE_URL', cause: nil
      end
    end
  end
end
