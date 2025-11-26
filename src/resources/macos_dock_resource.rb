module ZigBackend
end

class MacosDockResource
  def initialize(&block)
    @apps = []
    @tilesize = nil
    @orientation = nil
    @autohide = nil
    @magnification = nil
    @largesize = nil
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    instance_eval(&block) if block

    # If the Zig backend for macos_dock is not available (non-macOS build),
    # act as a no-op so DSL usage like `macos_dock` does not crash.
    return unless ZigBackend.respond_to?(:add_macos_dock)

    # Call Zig function with procs and notifications
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    # Convert notifications array to format: [[target, action, timing], ...]
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }

    ZigBackend.add_macos_dock(@apps, @tilesize, @orientation, @autohide, @magnification, @largesize, only_if_arg, not_if_arg, @ignore_failure, notifications_arg)
  end

  def apps(app_list)
    @apps = app_list.map { |app| File.expand_path(app.to_s) }
  end

  def tilesize(size)
    @tilesize = size.to_i
  end

  def orientation(pos)
    @orientation = pos.to_s
  end

  def autohide(enabled)
    @autohide = enabled
  end

  def magnification(enabled)
    @magnification = enabled
  end

  def largesize(size)
    @largesize = size.to_i
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

def macos_dock(&block)
  MacosDockResource.new(&block)
end

