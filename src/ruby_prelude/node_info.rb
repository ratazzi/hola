# Node object providing system information (like Chef's node)
class NodeObject
  def initialize
    @cache = {}
  end

  def [](key)
    @cache[key] ||= fetch_value(key)
  end

  def fetch_value(key)
    case key.to_s
    when 'hostname'
      ZigBackend.get_node_hostname
    when 'fqdn'
      ZigBackend.get_node_fqdn
    when 'platform'
      ZigBackend.get_node_platform
    when 'platform_family'
      ZigBackend.get_node_platform_family
    when 'platform_version'
      ZigBackend.get_node_platform_version
    when 'os'
      ZigBackend.get_node_os
    when 'kernel'
      # Return a nested hash for kernel info
      {
        'name' => ZigBackend.get_node_kernel_name,
        'release' => ZigBackend.get_node_kernel_release,
        'machine' => ZigBackend.get_node_machine
      }
    when 'cpu'
      # Return a nested hash for CPU info
      {
        'architecture' => ZigBackend.get_node_cpu_arch
      }
    when 'machine'
      ZigBackend.get_node_machine
    when 'lsb'
      # Return LSB information (Linux only)
      ZigBackend.get_node_lsb_info
    when 'network'
      # Return a nested hash for network info
      {
        'interfaces' => ZigBackend.get_node_network_interfaces,
        'default_gateway' => ZigBackend.get_node_default_gateway_ip,
        'default_interface' => ZigBackend.get_node_default_interface
      }
    else
      nil
    end
  end

  # Common shortcuts
  def hostname
    self['hostname']
  end

  def platform
    self['platform']
  end

  def platform_family
    self['platform_family']
  end

  def os
    self['os']
  end

  # Check if running on specific platform
  def mac_os_x?
    platform == 'mac_os_x'
  end

  def linux?
    os == 'linux'
  end

  def debian?
    platform_family == 'debian'
  end

  def rhel?
    platform_family == 'rhel'
  end
end

# Create global node instance
def node
  @_node ||= NodeObject.new
end
