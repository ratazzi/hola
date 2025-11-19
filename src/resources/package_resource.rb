module ZigBackend
end

class PackageResource
  def initialize(names, &block)
    # Support both single name and array of names
    @names = Array(names)
    @version = ""
    @options = ""
    @action = "install"
    @only_if_proc = nil
    @not_if_proc = nil
    @notifications = []
    instance_eval(&block) if block

    # Call Zig function with all package names at once
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    # Convert notifications array to format: [[target, action, timing], ...]
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }

    # Register all packages as a single resource (batch install)
    ZigBackend.add_package(@names, @version, @options, @action, only_if_arg, not_if_arg, notifications_arg)
  end

  # Allow overriding package names in block
  def package_name(value)
    @names = Array(value)
  end

  def version(value)
    @version = value.to_s
  end

  def options(value)
    @options = value.to_s
  end

  def action(value)
    @action = value.to_s
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

def package(names, &block)
  PackageResource.new(names, &block)
end
