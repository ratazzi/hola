module ZigBackend
end

class RubyBlockResource
  def initialize(name, &block)
    @name = name
    @block_proc = nil
    @action = "run"
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

    ZigBackend.add_ruby_block(@name, @block_proc, @action, only_if_arg, not_if_arg, @ignore_failure, notifications_arg)
  end

  def block(&block)
    @block_proc = block if block
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

def ruby_block(name, &block)
  RubyBlockResource.new(name, &block)
end
