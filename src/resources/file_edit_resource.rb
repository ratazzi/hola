module ZigBackend
end

class FileEditResource
  def initialize(path, &block)
    @path = File.expand_path(path)
    @operations = []
    @backup = false
    @mode = ""
    @owner = ""
    @group = ""
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

    ZigBackend.add_file_edit(
      @path,
      @operations,
      @backup,
      @mode,
      @owner,
      @group,
      only_if_arg,
      not_if_arg,
      @ignore_failure,
      notifications_arg,
      subscriptions_arg
    )
  end

  # Replace match (all occurrences) within each line
  def search_file_replace(pattern, replacement)
    @operations << ["search_file_replace", pattern.to_s, replacement.to_s]
  end

  # Replace entire line if pattern matches
  def search_file_replace_line(pattern, newline)
    @operations << ["search_file_replace_line", pattern.to_s, newline.to_s]
  end

  # Delete match (all occurrences) within each line
  def search_file_delete(pattern)
    @operations << ["search_file_delete", pattern.to_s, ""]
  end

  # Delete entire line if pattern matches
  def search_file_delete_line(pattern)
    @operations << ["search_file_delete_line", pattern.to_s, ""]
  end

  # Insert newline after each matching line
  def insert_line_after_match(pattern, newline)
    @operations << ["insert_line_after_match", pattern.to_s, newline.to_s]
  end

  # Insert newline at end if pattern not found anywhere
  def insert_line_if_no_match(pattern, newline)
    @operations << ["insert_line_if_no_match", pattern.to_s, newline.to_s]
  end

  def backup(value)
    @backup = !!value
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

def file_edit(path, &block)
  FileEditResource.new(path, &block)
end
