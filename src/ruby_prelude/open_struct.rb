# OpenStruct implementation compatible with Ruby's OpenStruct
# Allows accessing hash values as attributes: obj.foo instead of obj['foo']
class OpenStruct
  def initialize(hash = nil)
    @table = {}
    if hash
      hash.each do |k, v|
        @table[k.to_s] = convert_value(v)
      end
    end
  end

  # Hash-style access
  def [](key)
    @table[key.to_s]
  end

  def []=(key, value)
    @table[key.to_s] = convert_value(value)
  end

  # Method missing for dynamic attribute access
  # Note: In mruby, method_missing works but some method names like 'user' may conflict
  def method_missing(method, *args)
    method_name = method.to_s

    # Check if it's a setter (ends with =)
    if method_name[-1] == '='
      key = method_name[0..-2]
      @table[key] = convert_value(args[0])
      return args[0]
    end

    # Getter - check if key exists in table
    if @table.key?(method_name)
      return @table[method_name]
    end

    # If key doesn't exist, return nil (like Ruby's OpenStruct)
    nil
  end

  # Convert Hash to OpenStruct recursively
  def convert_value(value)
    case value
    when Hash
      OpenStruct.new(value)
    when Array
      value.map { |v| convert_value(v) }
    else
      value
    end
  end

  # Get all keys
  def keys
    @table.keys
  end

  # Check if key exists
  def key?(key)
    @table.key?(key.to_s)
  end

  # Iterate over key-value pairs
  def each(&block)
    @table.each(&block)
  end

  # Convert to hash
  def to_h
    result = {}
    @table.each do |k, v|
      result[k] = case v
                  when OpenStruct
                    v.to_h
                  when Array
                    v.map { |item| item.is_a?(OpenStruct) ? item.to_h : item }
                  else
                    v
                  end
    end
    result
  end

  # Inspect for debugging
  def inspect
    "#<OpenStruct #{@table.inspect}>"
  end

  # String representation
  def to_s
    inspect
  end

  # Check for nil (for Ruby compatibility with if obj checks)
  def nil?
    false
  end
end
