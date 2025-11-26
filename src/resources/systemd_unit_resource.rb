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
    instance_eval(&block) if block

    # Call Zig function with procs and notifications
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    # Convert notifications array to format: [[target, action, timing], ...]
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }

    # Convert actions to strings
    actions_arg = Array(@action).map(&:to_s)

    ZigBackend.add_systemd_unit(@name, @content, actions_arg, only_if_arg, not_if_arg, @ignore_failure, notifications_arg)
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

  def only_if(&block)
    @only_if_proc = block if block
  end

  def not_if(&block)
    @not_if_proc = block if block
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

  def subscribes(action, target_resource, timing: :delayed)
    # Note: subscribes is handled by the notification system in reverse
    # This is just a placeholder to support the DSL syntax
    # The actual implementation would need to register this with the target resource
  end
end

def systemd_unit(name, &block)
  SystemdUnitResource.new(name, &block)
end
