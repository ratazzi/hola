# JSON module using Zig backend
module JSON
  def self.encode(obj)
    ZigBackend.json_encode(obj)
  end

  def self.generate(obj)
    encode(obj)
  end

  def self.decode(str)
    ZigBackend.json_decode(str)
  end

  def self.parse(str)
    decode(str)
  end
end

# Add to_json method to all objects
class Object
  def to_json
    JSON.encode(self)
  end
end
