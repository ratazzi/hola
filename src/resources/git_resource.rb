module ZigBackend
end

class GitResource
  def initialize(destination, &block)
    @destination = destination
    @repository = ""
    @revision = "HEAD"
    @checkout_branch = "deploy"
    @remote = "origin"
    @depth = nil
    @enable_checkout = true
    @enable_submodules = false
    @ssh_key = nil
    @enable_strict_host_key_checking = true
    @user = nil
    @group = nil
    @action = "sync"
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []
    instance_eval(&block) if block

    # Validate required fields
    if @repository.empty?
      raise "git resource requires 'repository' property"
    end

    # Call Zig function with all parameters
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    # Convert notifications and subscriptions arrays to format: [[target, action, timing], ...]
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    subscriptions_arg = @subscriptions.map { |s| [s[:target], s[:action], s[:timing]] }

    # Call Zig backend if available
    if ZigBackend.respond_to?(:add_git)
      ZigBackend.add_git(
        @repository,
        @destination,
        @revision,
        @checkout_branch,
        @remote,
        @depth || 0,
        @enable_checkout,
        @enable_submodules,
        @ssh_key || "",
        @enable_strict_host_key_checking,
        @user || "",
        @group || "",
        @action,
        only_if_arg,
        not_if_arg,
        @ignore_failure,
        notifications_arg,
        subscriptions_arg
      )
    end
  end

  def repository(value)
    @repository = value.to_s
  end

  def revision(value)
    @revision = value.to_s
  end

  def checkout_branch(value)
    @checkout_branch = value.to_s
  end

  def remote(value)
    @remote = value.to_s
  end

  def depth(value)
    @depth = value.to_i
  end

  def enable_checkout(value)
    @enable_checkout = value
  end

  def enable_submodules(value)
    @enable_submodules = value
  end

  def ssh_key(value)
    @ssh_key = value.to_s
  end

  def enable_strict_host_key_checking(value)
    @enable_strict_host_key_checking = value
  end

  def user(value)
    @user = value.to_s
  end

  def group(value)
    @group = value.to_s
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

def git(destination, &block)
  GitResource.new(destination, &block)
end
