module ZigBackend
end

class DirectoryResource
  def initialize(path, &block)
    @path = File.expand_path(path)
    @mode = nil
    @owner = ""
    @group = ""
    @recursive = false
    @action = "create"
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
    mode_arg = @mode.nil? ? "" : @mode.to_s
    action_arg = @action.nil? ? "create" : @action.to_s
    ZigBackend.add_directory(@path, mode_arg, @owner, @group, !!@recursive, action_arg, only_if_arg, not_if_arg, @ignore_failure, notifications_arg, subscriptions_arg)
  end

  def mode(value)
    @mode = value.to_s
  end

  def owner(value)
    @owner = value.to_s
  end

  def group(value)
    @group = value.to_s
  end

  def recursive(value)
    @recursive = value
  end

  def action(value)
    @action = value.to_s
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

def directory(path, &block)
  DirectoryResource.new(path, &block)
end
