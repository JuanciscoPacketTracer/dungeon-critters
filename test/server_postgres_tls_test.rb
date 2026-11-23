# frozen_string_literal: true

require 'digest'
require 'minitest/autorun'
require 'openssl'
require 'pg'
require 'uri'
require_relative '../server/lib/postgres_tls'

class ServerPostgresTlsTest < Minitest::Test
  ROOT_CERT = DungeonCritters::Server::PostgresTls::DEFAULT_ROOT_CERT
  DATABASE_URL = 'postgresql://app_private:password@pooler.example.test:5432/postgres'

  def test_packaged_certificate_is_the_supabase_root_ca
    certificate = OpenSSL::X509::Certificate.new(File.read(ROOT_CERT))

    assert_equal 'Supabase Root 2021 CA', certificate.subject.to_a.find { |name,| name == 'CN' }[1]
    assert_equal(
      '807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA',
      Digest::SHA256.hexdigest(certificate.to_der).upcase
    )
  end

  def test_production_connection_forces_full_tls_verification_and_packaged_ca
    captured = nil
    PG.stub(:connect, lambda { |*args| captured = args; :connection }) do
      result = DungeonCritters::Server::PostgresTls.connect(
        DATABASE_URL,
        environment: 'production'
      )

      assert_equal :connection, result
    end

    assert_equal DATABASE_URL, captured[0]
    assert_equal({ sslmode: 'verify-full', sslrootcert: ROOT_CERT }, captured[1])
  end

  def test_production_rejects_a_weaker_ssl_mode
    error = assert_raises(DungeonCritters::Server::PostgresTls::ConfigurationError) do
      DungeonCritters::Server::PostgresTls.connect(
        "#{DATABASE_URL}?sslmode=require",
        environment: 'production'
      )
    end

    assert_equal 'DATABASE_URL sslmode must be verify-full', error.message
  end

  def test_production_rejects_a_missing_root_certificate
    error = assert_raises(DungeonCritters::Server::PostgresTls::ConfigurationError) do
      DungeonCritters::Server::PostgresTls.connect(
        DATABASE_URL,
        environment: 'production',
        root_cert: File.join(__dir__, 'synthetic-secret-missing-root.crt')
      )
    end

    assert_equal 'Supabase root certificate is missing', error.message
    assert_nil error.cause
    refute_includes error.full_message, 'synthetic-secret'
  end

  def test_malformed_database_url_does_not_leak_password_or_original_cause
    password = 'synthetic-db-password'
    url = "postgresql://app_private:#{password}@bad host:5432/postgres"

    error = assert_raises(DungeonCritters::Server::PostgresTls::ConfigurationError) do
      DungeonCritters::Server::PostgresTls.connect(url, environment: 'production')
    end

    assert_equal 'invalid DATABASE_URL', error.message
    assert_nil error.cause
    refute_includes error.full_message, password
    refute_includes error.full_message, url
  end
end

class ServerPostgresTlsRealTest < Minitest::Test
  DATABASE_URL = ENV['POSTGRES_TLS_TEST_URL']
  CA_CERT = ENV['POSTGRES_TLS_TEST_CA']
  WRONG_CA_CERT = ENV['POSTGRES_TLS_TEST_WRONG_CA']
  WRONG_HOST_URL = ENV['POSTGRES_TLS_TEST_WRONG_HOST_URL']

  def setup
    skip 'real PostgreSQL TLS test variables are not configured' unless
      [DATABASE_URL, CA_CERT, WRONG_CA_CERT, WRONG_HOST_URL].all? { |value| value && !value.empty? }

    urls = [DATABASE_URL, WRONG_HOST_URL].map { |url| URI.parse(url) }
    skip 'real PostgreSQL TLS tests require local disposable databases' unless
      urls.all? { |url| %w[localhost 127.0.0.1 ::1].include?(url.host) } &&
      urls.map { |url| url.path.delete_prefix('/') }.uniq == ['dungeon_critters_tls_test']
  end

  def test_valid_certificate_and_hostname_complete_a_real_tls_query
    connection = DungeonCritters::Server::PostgresTls.connect(
      DATABASE_URL,
      environment: 'production',
      root_cert: CA_CERT
    )

    assert_equal '1', connection.exec('SELECT 1 AS connected').first.fetch('connected')
  ensure
    connection&.close
  end

  def test_wrong_ca_is_rejected_by_real_tls_verification
    assert_raises(PG::Error) do
      DungeonCritters::Server::PostgresTls.connect(
        DATABASE_URL,
        environment: 'production',
        root_cert: WRONG_CA_CERT
      )
    end
  end

  def test_wrong_hostname_is_rejected_by_real_tls_verification
    assert_raises(PG::Error) do
      DungeonCritters::Server::PostgresTls.connect(
        WRONG_HOST_URL,
        environment: 'production',
        root_cert: CA_CERT
      )
    end
  end
end
