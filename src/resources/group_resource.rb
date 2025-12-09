# group resource - Manage system groups
#
# Example:
#   group 'developers' do
#     gid 1001
#     members ['alice', 'bob']
#     append true
#     action :create
#   end

def group(name, &block)
  res = GroupResource.new(name)
  res.instance_eval(&block) if block
  res.register
end

class GroupResource
  def initialize(name)
    @name = name
    @group_name = name
    @gid = nil
    @members = []
    @excluded_members = []
    @append = false
    @comment = nil
    @system = false
    @non_unique = false
    @action = :create
    @only_if = nil
    @not_if = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []
  end

  def group_name(value)
    @group_name = value.to_s
  end

  def gid(value)
    @gid = value
  end

  def members(value)
    @members = value
  end

  def excluded_members(value)
    @excluded_members = value
  end

  def append(value)
    @append = value
  end

  def comment(value)
    @comment = value.to_s
  end

  def system(value)
    @system = value
  end

  def non_unique(value)
    @non_unique = value
  end

  def action(value)
    @action = value
  end

  def only_if(command = nil, &block)
    @only_if = command&.to_s || block
  end

  def not_if(command = nil, &block)
    @not_if = command&.to_s || block
  end

  def ignore_failure(value)
    @ignore_failure = value
  end

  def notify(action, resource_name, timing = :delayed)
    @notifications << [action.to_s, resource_name.to_s, timing.to_s]
  end

  def subscribes(action, resource_identifier, timing = :delayed)
    @subscriptions << [action.to_s, resource_identifier.to_s, timing.to_s]
  end

  def register
    gid_str = @gid ? @gid.to_s : ""

    # Convert members array to comma-separated string
    members_str = if @members.is_a?(Array)
                    @members.join(',')
                  elsif @members.is_a?(String)
                    @members
                  else
                    ""
                  end

    # Convert excluded_members array to comma-separated string
    excluded_members_str = if @excluded_members.is_a?(Array)
                             @excluded_members.join(',')
                           elsif @excluded_members.is_a?(String)
                             @excluded_members
                           else
                             ""
                           end

    ZigBackend.add_group(
      @group_name,
      gid_str,
      members_str,
      excluded_members_str,
      @append,
      @comment || "",
      @system,
      @non_unique,
      @action.to_s,
      @only_if,
      @not_if,
      @ignore_failure,
      @notifications,
      @subscriptions
    )
  end
end
