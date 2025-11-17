module ZigBackend
end

class AptRepositoryResource
  def initialize(name, &block)
    @name = name
    @uri = ""
    @key_url = ""
    @key_path = ""
    @distribution = ""
    @components = ""
    @arch = ""
    @options = ""
    @repo_type = "deb"
    @action = "add"
    @only_if_proc = nil
    @not_if_proc = nil
    @notifications = []
    instance_eval(&block) if block

    # Convert options array to string if needed
    if @options.is_a?(Array)
      @options = @options.join(" ")
    end

    # Convert components array to string if needed
    if @components.is_a?(Array)
      @components = @components.join(" ")
    end

    # Call Zig function only if on Linux (ZigBackend.add_apt_repository exists)
    if ZigBackend.respond_to?(:add_apt_repository)
      only_if_arg = @only_if_proc || nil
      not_if_arg = @not_if_proc || nil
      notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }

      ZigBackend.add_apt_repository(
        @name,
        @uri,
        @key_url,
        @key_path,
        @distribution,
        @components,
        @arch,
        @options,
        @repo_type,
        @action,
        only_if_arg,
        not_if_arg,
        notifications_arg
      )
    end
  end

  def uri(value)
    # Handle PPA format
    if value.start_with?("ppa:")
      @uri = value
      @repo_type = "ppa"
    else
      @uri = value.to_s
    end
  end

  def key_url(value)
    @key_url = value.to_s
  end

  def key(value)
    @key_url = value.to_s
  end

  def key_path(value)
    @key_path = value.to_s
  end

  def distribution(value)
    @distribution = value.to_s
  end

  def components(value)
    if value.is_a?(Array)
      @components = value.join(" ")
    else
      @components = value.to_s
    end
  end

  def arch(value)
    @arch = value.to_s
  end

  def options(value)
    if value.is_a?(Array)
      @options = value.join(" ")
    else
      @options = value.to_s
    end
  end

  def repo_type(value)
    @repo_type = value.to_s
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

  def notifies(target_resource, action: :restart, timing: :delayed)
    @notifications << {
      target: target_resource,
      action: action.to_s,
      timing: timing.to_s
    }
  end
end

def apt_repository(name, &block)
  AptRepositoryResource.new(name, &block)
end
