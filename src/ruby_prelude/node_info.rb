# Node object providing system information (like Chef's node)
# This is a simplified wrapper that loads all data upfront from Zig
class NodeObject
  def initialize
    # Get all node info in one call (high reuse with node-info command)
    @data = ZigBackend.get_full_node_info
    # Convert all nested hashes to OpenStruct for dot notation
    convert_nested_hashes!
  end

  def [](key)
    @data[key.to_s]
  end

  # Support method_missing for dot notation access
  def method_missing(method, *args)
    key = method.to_s
    # Remove trailing '?' for predicate methods
    key = key[0..-2] if key[-1] == '?'

    value = self[key]

    # Handle predicate methods (e.g., node.linux?)
    if method.to_s[-1] == '?'
      return !value.nil? && value != false
    end

    value
  end

  def respond_to_missing?(method, include_private = false)
    true
  end

  private

  # Convert all nested hashes to OpenStruct recursively
  def convert_nested_hashes!
    @data.each do |key, value|
      @data[key] = convert_to_openstruct(value)
    end
  end

  # Helper to convert Hash to OpenStruct recursively
  def convert_to_openstruct(value)
    case value
    when Hash
      OpenStruct.new(value)
    when Array
      value.map { |v| convert_to_openstruct(v) }
    else
      value
    end
  end

  # Platform check helpers (predicate methods handled by method_missing)
  # These are just for clarity, method_missing handles node.linux?, node.mac_os_x?, etc.
end

# Create global node instance
def node
  @_node ||= NodeObject.new
end
