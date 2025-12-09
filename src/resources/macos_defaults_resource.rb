module ZigBackend
end

class MacOSDefaultsResource
  def initialize(name, &block)
    @name = name.to_s
    @domain = nil
    @key = nil
    @value = nil
    @type = nil
    @global = false
    @action = :write
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []
    instance_eval(&block) if block

    # Validate required parameters
    raise "macos_defaults: 'key' is required" if @key.nil? || @key.empty?

    # domain or global must be specified
    if @domain.nil? && !@global
      raise "macos_defaults: either 'domain' or 'global true' must be specified"
    end

    # If global is true, use NSGlobalDomain
    if @global
      @domain = "NSGlobalDomain"
    end

    # If the Zig backend for macos_defaults is not available (non-macOS build),
    # act as a no-op so DSL usage like `macos_defaults` does not crash.
    return unless ZigBackend.respond_to?(:add_macos_defaults)

    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    subscriptions_arg = @subscriptions.map { |s| [s[:target], s[:action], s[:timing]] }

    # Auto-detect type from value if not explicitly specified
    if @type.nil? && @value != nil
      @type = case @value
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

    # Convert value to appropriate format
    value_arg = nil
    if @value != nil
      value_arg = [@type || "string", @value]
    end

    action_arg = @action.to_s

    ZigBackend.add_macos_defaults(@domain, @key, value_arg, action_arg, only_if_arg, not_if_arg, @ignore_failure, notifications_arg, subscriptions_arg)
  end

  def domain(val)
    @domain = val.to_s
  end

  def global(val)
    @global = val
  end

  def key(val)
    @key = val.to_s
  end

  def type(val)
    @type = val.to_s
  end

  def value(val)
    @value = val
  end

  def action(val)
    @action = val.to_sym
  end

  def only_if(command = nil, &block)
    @only_if_proc = command&.to_s || block
  end

  def not_if(command = nil, &block)
    @not_if_proc = command&.to_s || block
  end

  def ignore_failure(value)
    @ignore_failure = value
  end

  def notifies(action, target_resource, timer = :delayed)
    @notifications << {
      target: target_resource,
      action: action.to_s,
      timing: timer.to_s
    }
  end

  def subscribes(action, source_resource, timer = :delayed)
    @subscriptions << {
      target: source_resource,
      action: action.to_s,
      timing: timer.to_s
    }
  end
end

def macos_defaults(name, &block)
  MacOSDefaultsResource.new(name, &block)
end
