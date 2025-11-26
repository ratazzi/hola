module ZigBackend
end

class ExecuteResource
  def initialize(name, command = nil, &block)
    @name = name
    @command = command || name  # If no command given, use name as command
    @cwd = ""
    @user = ""
    @group = ""
    @live_stream = false  # Default: don't output to stdout
    @action = "run"
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
    ZigBackend.add_execute(@name, @command, @cwd, @user, @group, @live_stream, @action, only_if_arg, not_if_arg, @ignore_failure, notifications_arg, subscriptions_arg)
  end

  def command(value)
    @command = value.to_s
  end

  def cwd(value)
    @cwd = value.to_s
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

  def live_stream(value)
    @live_stream = value
  end

  def timeout(value)
    @timeout = value.to_i
  end

  def returns(value)
    @returns = Array(value)
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

  def subscribes(action, source_resource, timer = :delayed)
    @subscriptions << {
      target: source_resource,
      action: action.to_s,
      timing: timer.to_s
    }
  end
end

def execute(name, command = nil, &block)
  ExecuteResource.new(name, command, &block)
end
