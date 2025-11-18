# Base64 encoding/decoding module using Zig backend
module Base64
  def self.encode64(str)
    ZigBackend.base64_encode(str)
  end

  def self.decode64(str)
    ZigBackend.base64_decode(str)
  end

  def self.strict_encode64(str)
    encode64(str)
  end

  def self.strict_decode64(str)
    decode64(str)
  end

  def self.urlsafe_encode64(str, padding: false)
    ZigBackend.base64_urlsafe_encode(str)
  end

  def self.urlsafe_decode64(str)
    ZigBackend.base64_urlsafe_decode(str)
  end
end
