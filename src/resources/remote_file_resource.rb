module ZigBackend
end

class RemoteFileResource
  def initialize(path, &block)
    @path = File.expand_path(path)
    @source = ""
    @mode = ""
    @owner = ""
    @group = ""
    @checksum = ""
    @backup = ""
    @headers = {}
    @use_etag = false
    @use_last_modified = false
    @force_unlink = false
    @action = "create"
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []
    instance_eval(&block) if block

    # Call Zig function with procs and notifications
    # Pass nil for procs that weren't set
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    # Convert notifications array to format: [[target, action, timing], ...]
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    subscriptions_arg = @subscriptions.map { |s| [s[:target], s[:action], s[:timing]] }

    # Pass headers hash directly to Zig
    ZigBackend.add_remote_file(@path, @source, @mode, @owner, @group, @checksum, @backup, @headers, @use_etag, @use_last_modified, @force_unlink, @action, only_if_arg, not_if_arg, @ignore_failure, notifications_arg, subscriptions_arg)
  end

  def source(value)
    @source = value.to_s
  end

  def url(value)
    @source = value.to_s
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

  def checksum(value)
    @checksum = value.to_s
  end

  def backup(value)
    @backup = value.to_s
  end

  def use_etag(value)
    @use_etag = !!value
  end

  def use_last_modified(value)
    @use_last_modified = !!value
  end

  def force_unlink(value)
    @force_unlink = !!value
  end

  def headers(value)
    @headers = value
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

def remote_file(path, &block)
  RemoteFileResource.new(path, &block)
end
