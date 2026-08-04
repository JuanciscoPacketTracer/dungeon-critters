require 'openssl'
require 'tempfile'
require 'zip'

module Pkcs12Cert
  class KeystoreError < StandardError; end

  module_function

  def public_cert_der(path)
    cert = OpenSSL::X509::Certificate.new(File.binread(path))
    cert.to_der
  rescue OpenSSL::X509::CertificateError => e
    raise KeystoreError, "Invalid certificate file #{path}: #{e.message}"
  end

  def signing_cert_der(keystore_path, password)
    pkcs12 = OpenSSL::PKCS12.new(File.binread(keystore_path), password)
    cert = pkcs12.certificate or raise KeystoreError, "No certificate found in keystore: #{keystore_path}"
    cert.to_der
  rescue OpenSSL::PKCS12::PKCS12Error, OpenSSL::PKey::PKeyError, OpenSSL::X509::CertificateError => e
    raise KeystoreError, "Unable to read PKCS12 keystore #{keystore_path}: #{e.message}"
  end

  def generate(p12_path:, password:)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = Random.rand(1..(1 << 31))
    cert.subject = OpenSSL::X509::Name.parse('/CN=PSDK Debug Android Export')
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + (3650 * 24 * 60 * 60)

    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE', true))
    cert.add_extension(ef.create_extension('keyUsage', 'digitalSignature,keyEncipherment', true))
    cert.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash'))
    cert.add_extension(ef.create_extension('authorityKeyIdentifier', 'keyid:always'))
    cert.sign(key, OpenSSL::Digest.new('SHA256'))

    pkcs12 = OpenSSL::PKCS12.create(password, 'psdk-debug', key, cert)
    File.binwrite(p12_path, pkcs12.to_der)
  rescue OpenSSL::OpenSSLError => e
    raise KeystoreError, "Unable to generate PKCS12 keystore #{p12_path}: #{e.message}"
  end

  def cert_der_from_apk(apk_path)
    signature_entry = nil

    Zip::File.open(apk_path) do |zip|
      signature_entry = zip.glob('META-INF/*.RSA').first || zip.glob('META-INF/*.DSA').first || zip.glob('META-INF/*.EC').first
      raise KeystoreError, "No v1 signature certificate found in APK: #{apk_path}" unless signature_entry

      pkcs7 = OpenSSL::PKCS7.new(signature_entry.get_input_stream.read)
      cert = pkcs7.certificates&.first
      raise KeystoreError, "Unable to extract certificate from APK: #{apk_path}" unless cert

      return cert.to_der
    end
  rescue OpenSSL::PKCS7::PKCS7Error, OpenSSL::X509::CertificateError, Zip::Error => e
    raise KeystoreError, "Unable to extract certificate from APK #{apk_path}: #{e.message}"
  end
end