# frozen_string_literal: true

require 'fiddle'
require 'fiddle/import'
require 'securerandom'
require 'tmpdir'

unless Fiddle.respond_to?(:win32_last_socket_error=)
  # Fiddle::Function calls this Windows error accessor, but this Ruby build does not define it.
  def Fiddle.win32_last_socket_error=(_value)
    nil
  end
end

class MissingProtectedToken < StandardError; end
class DpapiError < StandardError; end
class InvalidTokenHeader < StandardError; end

DATA_BLOB = Struct.new(:size, :data)
CRYPTPROTECT_UI_FORBIDDEN = 0x1
STDCALL = Fiddle::Function::STDCALL

crypt_protect_data = Fiddle::Function.new(
  Fiddle.dlopen('crypt32.dll')['CryptProtectData'],
  [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
   Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP],
  Fiddle::TYPE_INT,
  STDCALL
)
crypt_unprotect_data = Fiddle::Function.new(
  Fiddle.dlopen('crypt32.dll')['CryptUnprotectData'],
  [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
   Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP],
  Fiddle::TYPE_INT,
  STDCALL
)
LOCAL_FREE = Fiddle::Function.new(
  Fiddle.dlopen('kernel32.dll')['LocalFree'],
  [Fiddle::TYPE_VOIDP],
  Fiddle::TYPE_VOIDP,
  STDCALL
)

def blob_pointer(blob)
  pointer = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP * 2)
  pointer[0, Fiddle::SIZEOF_VOIDP] = [blob.size].pack('L')
  pointer[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP] = [blob.data].pack('L')
  pointer
end

def read_blob(pointer)
  size = pointer[0, Fiddle::SIZEOF_VOIDP].unpack1('L')
  data_address = pointer[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP].unpack1('L')
  [size, Fiddle::Pointer.new(data_address)[0, size]]
end

def protect(crypt_protect_data, token, entropy)
  input = Fiddle::Pointer[token]
  entropy_pointer = Fiddle::Pointer[entropy]
  output = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP * 2)
  ok = crypt_protect_data.call(
    blob_pointer(DATA_BLOB.new(token.bytesize, input.to_i)),
    0,
    blob_pointer(DATA_BLOB.new(entropy.bytesize, entropy_pointer.to_i)),
    0,
    0,
    CRYPTPROTECT_UI_FORBIDDEN,
    output
  )
  raise DpapiError, 'CryptProtectData failed' if ok == 0

  _size, data = read_blob(output)
  data_address = output[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP].unpack1('L')
  data
ensure
  LOCAL_FREE.call(data_address) if data_address
end

def unprotect(crypt_unprotect_data, encrypted, entropy)
  input = Fiddle::Pointer[encrypted]
  entropy_pointer = Fiddle::Pointer[entropy]
  output = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP * 2)
  output[0, Fiddle::SIZEOF_VOIDP * 2] = "\0" * (Fiddle::SIZEOF_VOIDP * 2)
  ok = crypt_unprotect_data.call(
    blob_pointer(DATA_BLOB.new(encrypted.bytesize, input.to_i)),
    0,
    blob_pointer(DATA_BLOB.new(entropy.bytesize, entropy_pointer.to_i)),
    0,
    0,
    CRYPTPROTECT_UI_FORBIDDEN,
    output
  )
  raise DpapiError, 'CryptUnprotectData failed' if ok == 0

  _size, data = read_blob(output)
  data
ensure
  if output
    data_address = output[Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP].unpack1('L')
    LOCAL_FREE.call(data_address) if data_address != 0
  end
end

def write_protected(path, encrypted)
  File.binwrite(path, ['DCTK', 1, encrypted.bytesize].pack('a4V V') + encrypted)
end

def read_protected(path)
  raise MissingProtectedToken unless File.file?(path)

  contents = File.binread(path)
  raise InvalidTokenHeader unless contents.bytesize >= 12

  magic, version, length = contents.unpack('a4V V')
  payload = contents.byteslice(12, contents.bytesize - 12)
  raise InvalidTokenHeader unless magic == 'DCTK'
  raise InvalidTokenHeader unless version == 1
  raise InvalidTokenHeader unless length == payload.bytesize
  payload
end

def check(label, expected)
  yield
  raise "#{label} unexpectedly succeeded"
rescue expected => error
  puts "#{label}: PASS (#{error.class})"
end

puts "Ruby: #{RUBY_DESCRIPTION}"
puts "Fiddle pointer bytes: #{Fiddle::SIZEOF_VOIDP}"

Dir.mktmpdir('dctk-dpapi-proof') do |directory|
  path = File.join(directory, 'token.bin')
  entropy = SecureRandom.random_bytes(32)
  token = "fake-token-#{SecureRandom.hex(16)}"
  encrypted = protect(crypt_protect_data, token, entropy)
  write_protected(path, encrypted)
  recovered = unprotect(crypt_unprotect_data, read_protected(path), entropy)
  raise 'round trip mismatch' unless recovered == token
  puts 'protect/write/read/current-user round trip: PASS'

  File.delete(path)
  check('missing file', MissingProtectedToken) { read_protected(path) }

  write_protected(path, encrypted)
  corrupted = File.binread(path)
  corrupted.setbyte(-1, corrupted.getbyte(-1) ^ 0xff)
  File.binwrite(path, corrupted)
  check('corrupt file', DpapiError) { unprotect(crypt_unprotect_data, read_protected(path), entropy) }

  write_protected(path, encrypted)
  check('incorrect entropy', DpapiError) do
    unprotect(crypt_unprotect_data, read_protected(path), SecureRandom.random_bytes(32))
  end

  [
    ['invalid magic header', -> { data = File.binread(path); data[0, 4] = 'BAD!'; File.binwrite(path, data) }],
    ['invalid version header', -> { data = File.binread(path); data[4, 4] = [2].pack('V'); File.binwrite(path, data) }],
    ['invalid length header', -> { data = File.binread(path); data[8, 4] = [0].pack('V'); File.binwrite(path, data) }]
  ].each do |label, mutate|
    write_protected(path, encrypted)
    mutate.call
    check(label, InvalidTokenHeader) { read_protected(path) }
  end

  puts 'different Windows user or computer: NOT VERIFIED (not executed)'
end
