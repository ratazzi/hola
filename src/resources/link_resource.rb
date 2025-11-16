module ZigBackend
end

class LinkResource
  def initialize(path, &block)
    @path = File.expand_path(path)
    @target = ""
    @action = "create"
    @only_if_proc = nil
    @not_if_proc = nil
    @notifications = []
    instance_eval(&block) if block

    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    ZigBackend.add_link(@path, @target, @action, only_if_arg, not_if_arg, notifications_arg)
  end

  def to(value)
    @target = File.expand_path(value.to_s)
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

def link(path, &block)
  LinkResource.new(path, &block)
end
