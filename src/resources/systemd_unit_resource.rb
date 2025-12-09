module ZigBackend
end

class SystemdUnitResource
  def initialize(name, &block)
    @name = name
    @content = ""
    @action = [:create]
    @verify = true
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []
    instance_eval(&block) if block

    # Call Zig function with procs and notifications
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    # Convert notifications array to format: [[target, action, timing], ...]
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    subscriptions_arg = @subscriptions.map { |s| [s[:target], s[:action], s[:timing]] }

    # Convert actions to strings
    actions_arg = Array(@action).map(&:to_s)

    ZigBackend.add_systemd_unit(@name, @content, actions_arg, only_if_arg, not_if_arg, @ignore_failure, notifications_arg, subscriptions_arg)
  end

  def content(value)
    @content = value.to_s
  end

  def action(value)
    @action = value
  end

  def verify(value)
    @verify = value
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

def systemd_unit(name, &block)
  SystemdUnitResource.new(name, &block)
end
