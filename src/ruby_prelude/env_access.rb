# ENV object for accessing environment variables
module ENV
  def self.[](key)
    ZigBackend.env_get(key.to_s)
  end

  def self.[]=(key, value)
    if value.nil?
      ZigBackend.env_delete(key.to_s)
    else
      ZigBackend.env_set(key.to_s, value.to_s)
    end
  end

  def self.fetch(key, default = nil)
    val = self[key]
    val.nil? ? default : val
  end

  def self.key?(key)
    ZigBackend.env_has_key(key.to_s)
  end

  def self.has_key?(key)
    key?(key)
  end

  def self.include?(key)
    key?(key)
  end

  def self.delete(key)
    old_val = self[key]
    ZigBackend.env_delete(key.to_s)
    old_val
  end
end
