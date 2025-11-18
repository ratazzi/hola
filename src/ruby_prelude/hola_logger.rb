# Hola logging module
module Hola
  def self.debug(msg)
    ZigBackend.hola_debug(msg.to_s)
  end

  def self.info(msg)
    ZigBackend.hola_info(msg.to_s)
  end

  def self.warn(msg)
    ZigBackend.hola_warn(msg.to_s)
  end

  def self.error(msg)
    ZigBackend.hola_error(msg.to_s)
  end

  # Alias for convenience
  class << self
    alias_method :log, :info
  end
end
