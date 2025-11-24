# apt_update - A Ruby-only resource that wraps execute
# This demonstrates how to create custom resources without Zig implementation

class AptUpdateResource
  def initialize(name, &block)
    @name = name
    @frequency = 86400  # Default: update once per day
    @action = :periodic
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false

    instance_eval(&block) if block

    # Execute the actual logic based on action
    case @action
    when :periodic
      apply_periodic
    when :update
      apply_update
    end
  end

  def frequency(seconds)
    @frequency = seconds
  end

  def action(value)
    @action = value
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

  private

  def apply_periodic
    # Only update if the last update was more than @frequency seconds ago
    # IMPORTANT: Capture instance variables in local variables before using in blocks
    # mruby does not support accessing @instance_variables from nested blocks
    frequency = @frequency
    ignore_fail = @ignore_failure

    # Production paths for Linux
    command_str = "apt-get update && mkdir -p /var/lib/apt/periodic && touch /var/lib/apt/periodic/update-success-stamp"
    stamp_path = "/var/lib/apt/periodic/update-success-stamp"

    execute @name do
      command command_str
      action "run"

      only_if do
        stamp_file = stamp_path

        # If stamp file doesn't exist, we need to update
        if File.exist?(stamp_file)
          # Check if file is older than frequency
          # File.mtime returns Time object (compatible with Ruby)
          mtime = File.mtime(stamp_file)
          now = Time.now
          age = now - mtime  # Time difference in seconds

          # Return true if file is older than frequency
          age > frequency
        else
          # File doesn't exist, need to update
          true
        end
      end

      ignore_failure ignore_fail
    end
  end

  def apply_update
    # Always update, no frequency check
    ignore_fail = @ignore_failure

    execute @name do
      command "apt-get update"
      action "run"
      ignore_failure ignore_fail
    end
  end
end

def apt_update(name, &block)
  AptUpdateResource.new(name, &block)
end
