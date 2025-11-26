module ZigBackend
end

class TemplateResource
  def initialize(path, &block)
    @path = File.expand_path(path)
    @source = ""
    @mode = ""
    @owner = ""
    @group = ""
    @action = "create"
    @variables = {}
    @only_if_proc = nil
    @not_if_proc = nil
    @ignore_failure = false
    @notifications = []
    instance_eval(&block) if block

    # Convert variables hash to array format: [[name, value, type], ...]
    # type: 'string', 'integer', 'float', 'boolean', 'nil', 'array'
    variables_arg = @variables.map do |k, v|
      type = case v
      when Integer then 'integer'
      when Float then 'float'
      when TrueClass, FalseClass then 'boolean'
      when NilClass then 'nil'
      when Array then 'array'
      else 'string'
      end
      # For arrays, convert to JSON-like string representation
      # For other types, use to_s
      value_str = if type == 'array'
        # Convert array to Ruby array literal string
        '[' + v.map { |item| item.inspect }.join(', ') + ']'
      else
        v.to_s
      end
      [k.to_s, value_str, type]
    end

    # Call Zig function with procs and notifications
    only_if_arg = @only_if_proc || nil
    not_if_arg = @not_if_proc || nil

    # Convert notifications array to format: [[target, action, timing], ...]
    notifications_arg = @notifications.map { |n| [n[:target], n[:action], n[:timing]] }
    ZigBackend.add_template(@path, @source, @mode, @owner, @group, variables_arg, @action, only_if_arg, not_if_arg, @ignore_failure, notifications_arg)
  end

  def source(value)
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

  def action(value)
    @action = value.to_s
  end

  def variables(vars_hash)
    @variables = vars_hash
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

def template(path, &block)
  TemplateResource.new(path, &block)
end

