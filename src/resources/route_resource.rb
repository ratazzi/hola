module ZigBackend
end

class RouteResource
  def initialize(target, &block)
    @target = target
    @gateway = ""
    @netmask = ""
    @device = ""
    @action = :add
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    instance_eval(&block) if block

    # Call Zig function
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }

    # Signature: add_route(target, gateway, netmask, device, action, only_if, not_if, notifications)
    ZigBackend.add_route(@target, @gateway, @netmask, @device, @action.to_s, only_if_arg, not_if_arg, @ignore_failure, notifications_arg)
  end

  def gateway(value)
    @gateway = value.to_s
  end

  def netmask(value)
    @netmask = value.to_s
  end

  def device(value)
    @device = value.to_s
  end

  def action(value)
    @action = value
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
end

def route(target, &block)
  RouteResource.new(target, &block)
end

