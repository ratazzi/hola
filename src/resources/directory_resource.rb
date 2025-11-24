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
    instance_eval(&block) if block

    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    mode_arg = @mode.nil? ? "" : @mode.to_s
    action_arg = @action.nil? ? "create" : @action.to_s
    ZigBackend.add_directory(@path, mode_arg, @owner, @group, !!@recursive, action_arg, only_if_arg, not_if_arg, @ignore_failure, notifications_arg)
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

  def only_if(&block)
    @only_if_proc = block if block
  end

  def not_if(&block)
    @not_if_proc = block if block
  end

  def ignore_failure(value)
    @ignore_failure = value
  end

  def notifies(target_resource, action: :restart, timing: :delayed)
    @notifications << {
      target: target_resource,
      action: action.to_s,
      timing: timing.to_s
    }
  end
end

def directory(path, &block)
  DirectoryResource.new(path, &block)
end
