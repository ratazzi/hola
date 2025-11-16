module ZigBackend
end

class MacOSDefaultsResource
  def initialize(domain, key, &block)
    @domain = domain.to_s
    @key = key.to_s
    @value = nil
    @value_type = nil
    @action = "write"
    @only_if_proc = nil
    @not_if_proc = nil
    @notifications = []
    instance_eval(&block) if block

    # If the Zig backend for macos_defaults is not available (non-macOS build),
    # act as a no-op so DSL usage like `macos_defaults` does not crash.
    return unless ZigBackend.respond_to?(:add_macos_defaults)

    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }

    # Convert value to appropriate format
    # Format: [type, value] where type is "string", "integer", "boolean", "float", "array", "dict"
    value_arg = nil
    if @value != nil
      value_arg = [@value_type || "string", @value]
    end

    action_arg = @action.nil? ? "write" : @action.to_s
    ZigBackend.add_macos_defaults(@domain, @key, value_arg, action_arg, only_if_arg, not_if_arg, notifications_arg)
  end

  def value(val)
    @value = val
    @value_type = case val
    when String
      "string"
    when Integer
      "integer"
    when TrueClass, FalseClass
      "boolean"
    when Float
      "float"
    when Array
      "array"
    when Hash
      "dict"
    else
      "string" # Default to string
    end
  end

  def action(val)
    @action = val.to_s
  end

  def only_if(&block)
    @only_if_proc = block if block
  end

  def not_if(&block)
    @not_if_proc = block if block
  end

  def notifies(target_resource, action: :restart, timing: :delayed)
    @notifications << {
      target: target_resource,
      action: action.to_s,
      timing: timing.to_s
    }
  end
end

def macos_defaults(domain, key, &block)
  MacOSDefaultsResource.new(domain, key, &block)
end
