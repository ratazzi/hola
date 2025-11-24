# Ruby-compatible Resolv implementation
class Resolv
  # Get first IPv4 address for hostname
  def self.getaddress(name)
    ZigBackend.resolv_getaddress(name)
  end

  # Get all addresses (IPv4 and IPv6) for hostname
  def self.getaddresses(name)
    ZigBackend.resolv_getaddresses(name)
  end

  # Reverse DNS lookup
  def self.getname(address)
    ZigBackend.resolv_getname(address)
  end

  # DNS class for more control
  class DNS
    # Resource types
    module Resource
      module IN
        class A
          attr_reader :address

          def initialize(address)
            @address = address
          end

          def to_s
            @address
          end
        end

        class AAAA
          attr_reader :address

          def initialize(address)
            @address = address
          end

          def to_s
            @address
          end
        end
      end
    end

    def initialize(options = {})
      @nameservers = options[:nameserver] || options[:nameservers] || nil
      # Normalize to array
      if @nameservers && !@nameservers.is_a?(Array)
        @nameservers = [@nameservers]
      end
    end

    # Get resources for a hostname
    # type can be Resolv::DNS::Resource::IN::A or Resolv::DNS::Resource::IN::AAAA
    def getresources(name, type)
      # If custom nameservers are specified, use the first one
      nameserver = @nameservers&.first

      addresses = if nameserver
        # Use custom nameserver via DNS protocol
        ZigBackend.resolv_getaddresses(name, nameserver)
      else
        Resolv.getaddresses(name)
      end

      if type == Resource::IN::A
        # Filter IPv4 addresses
        addresses.select { |addr| addr.include?('.') }
                 .map { |addr| Resource::IN::A.new(addr) }
      elsif type == Resource::IN::AAAA
        # Filter IPv6 addresses
        addresses.select { |addr| addr.include?(':') }
                 .map { |addr| Resource::IN::AAAA.new(addr) }
      else
        []
      end
    end

    # Block form
    def self.open(options = {}, &block)
      dns = new(options)
      block.call(dns)
    end
  end
end
