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
    @use_etag = true
    @use_last_modified = true
    @force_unlink = false
    @remote_user = nil
    @remote_password = nil
    @remote_domain = nil
    @ssh_private_key = nil
    @ssh_public_key = nil
    @ssh_known_hosts = nil
    @aws_access_key = nil
    @aws_secret_key = nil
    @aws_region = nil
    @aws_endpoint = nil
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
    ZigBackend.add_remote_file(@path, @source, @mode, @owner, @group, @checksum, @backup, @headers, @use_etag, @use_last_modified, @force_unlink, @action, only_if_arg, not_if_arg, @ignore_failure, notifications_arg, subscriptions_arg, @remote_user, @remote_password, @remote_domain, @ssh_private_key, @ssh_public_key, @ssh_known_hosts, @aws_access_key, @aws_secret_key, @aws_region, @aws_endpoint)
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

  # Authentication parameters (Chef-compatible)
  def remote_user(value)
    @remote_user = value.to_s
  end

  def remote_password(value)
    @remote_password = value.to_s
  end

  def remote_domain(value)
    @remote_domain = value.to_s
  end

  # Hola-specific: SSH key authentication for SFTP
  def ssh_private_key(value)
    @ssh_private_key = value.to_s
  end

  def ssh_public_key(value)
    @ssh_public_key = value.to_s
  end

  def ssh_known_hosts(value)
    @ssh_known_hosts = value.to_s
  end

  # Hola-specific: AWS S3 authentication
  def aws_access_key(value)
    @aws_access_key = value.to_s
  end

  def aws_secret_key(value)
    @aws_secret_key = value.to_s
  end

  def aws_region(value)
    @aws_region = value.to_s
  end

  def aws_endpoint(value)
    @aws_endpoint = value.to_s
  end
end

def remote_file(path, &block)
  RemoteFileResource.new(path, &block)
end
