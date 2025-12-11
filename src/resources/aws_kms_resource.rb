module ZigBackend
end

class AwsKmsResource
  def initialize(name, &block)
    @name = name
    @path = name  # name is the target path
    @region = ""
    @access_key_id = ""
    @secret_access_key = ""
    @session_token = ""
    @key_id = ""
    @algorithm = "SYMMETRIC_DEFAULT"
    @source = ""
    @source_encoding = ""  # empty means auto-detect
    @target_encoding = ""  # empty means auto-detect
    @mode = "0600"
    @owner = ""
    @group = ""
    @action = "decrypt"
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []

    instance_eval(&block) if block

    # Parse source URI and infer encoding
    parsed_source, inferred_source_encoding = parse_source_uri(@source)

    # Determine final encoding
    final_source_encoding = if @source_encoding != ""
      @source_encoding
    elsif inferred_source_encoding
      inferred_source_encoding
    else
      # Default: decrypt defaults to base64, encrypt defaults to binary
      @action == "decrypt" ? "base64" : "binary"
    end

    final_target_encoding = if @target_encoding != ""
      @target_encoding
    else
      # Default: decrypt defaults to binary, encrypt defaults to base64
      @action == "decrypt" ? "binary" : "base64"
    end

    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    subscriptions_arg = @subscriptions.map { |s| [s[:target], s[:action], s[:timing]] }

    ZigBackend.add_aws_kms(
      @name,
      @region,
      @access_key_id,
      @secret_access_key,
      @session_token,
      @key_id,
      @algorithm,
      parsed_source,
      final_source_encoding,
      final_target_encoding,
      @path,
      @mode,
      @owner,
      @group,
      @action,
      only_if_arg,
      not_if_arg,
      @ignore_failure,
      notifications_arg,
      subscriptions_arg
    )
  end

  # Parse source URI, returns [path, encoding]
  def parse_source_uri(source)
    if source.start_with?("fileb://")
      # fileb:// - binary file
      path = source[8..-1]  # strip "fileb://"
      [File.expand_path(path), "binary"]
    elsif source.start_with?("file://")
      # file:// - base64 text file
      path = source[7..-1]  # strip "file://"
      [File.expand_path(path), "base64"]
    elsif source.start_with?("base64:")
      # base64:xxx - inline base64 data
      data = source[7..-1]  # strip "base64:"
      ["inline:" + data, "base64"]
    elsif source.empty?
      ["", nil]
    else
      # Plain path
      [File.expand_path(source), nil]
    end
  end

  def region(value)
    @region = value.to_s
  end

  def access_key_id(value)
    @access_key_id = value.to_s
  end

  def secret_access_key(value)
    @secret_access_key = value.to_s
  end

  def session_token(value)
    @session_token = value.to_s
  end

  def key_id(value)
    @key_id = value.to_s
  end

  def algorithm(value)
    @algorithm = value.to_s
  end

  def source(value)
    @source = value.to_s
  end

  def source_encoding(value)
    @source_encoding = value.to_s
  end

  def target_encoding(value)
    @target_encoding = value.to_s
  end

  def path(value)
    path_str = value.to_s
    # Parse file:// prefix
    if path_str.start_with?("file://")
      @path = File.expand_path(path_str[7..-1])
    elsif path_str.start_with?("fileb://")
      @path = File.expand_path(path_str[8..-1])
    else
      @path = File.expand_path(path_str)
    end
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

def aws_kms(name, &block)
  AwsKmsResource.new(name, &block)
end
