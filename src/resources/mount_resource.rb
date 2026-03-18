module ZigBackend
end

class MountResource
  def initialize(name, &block)
    @mount_point = name
    @device = ""
    @device_type = "device"
    @fstype = "auto"
    @options = ["defaults"]
    @dump = 0
    @pass = 2
    @supports = { remount: false }
    @action = [:mount, :enable]
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []
    instance_eval(&block) if block

    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    subscriptions_arg = @subscriptions.map { |s| [s[:target], s[:action], s[:timing]] }

    actions_arg = Array(@action).map(&:to_s)
    options_str = Array(@options).join(",")
    supports_remount = @supports[:remount] ? true : false

    return unless ZigBackend.respond_to?(:add_mount)

    ZigBackend.add_mount(
      @mount_point, @device, @device_type.to_s, @fstype,
      options_str, @dump.to_s, @pass.to_s, supports_remount,
      actions_arg,
      only_if_arg, not_if_arg, @ignore_failure,
      notifications_arg, subscriptions_arg
    )
  end

  def device(value)
    @device = value.to_s
  end

  def device_type(value)
    @device_type = value.to_s
  end

  def fstype(value)
    @fstype = value.to_s
  end

  def options(value)
    @options = Array(value)
  end

  def dump(value)
    @dump = value.to_i
  end

  def pass(value)
    @pass = value.to_i
  end

  def supports(value)
    @supports = value
  end

  def action(value)
    @action = value
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

def mount(name, &block)
  MountResource.new(name, &block)
end
