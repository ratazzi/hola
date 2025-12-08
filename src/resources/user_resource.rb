# user resource - Manage system users
#
# Example:
#   user 'deployer' do
#     uid 1001
#     gid 1001
#     comment 'Deployment user'
#     home '/home/deployer'
#     shell '/bin/bash'
#     manage_home true
#     action :create
#   end

def user(name, &block)
  res = UserResource.new(name)
  res.instance_eval(&block) if block
  res.register
end

class UserResource
  def initialize(name)
    @name = name
    @username = name
    @uid = nil
    @gid = nil
    @comment = nil
    @home = nil
    @shell = nil
    @password = nil
    @system = false
    @manage_home = false
    @non_unique = false
    @action = :create
    @only_if = nil
    @not_if = nil
    @ignore_failure = false
    @notifications = []
    @subscriptions = []
  end

  def username(value)
    @username = value.to_s
  end

  def uid(value)
    @uid = value
  end

  def gid(value)
    @gid = value
  end

  def comment(value)
    @comment = value.to_s
  end

  def home(value)
    @home = value.to_s
  end

  def shell(value)
    @shell = value.to_s
  end

  def password(value)
    @password = value.to_s
  end

  def system(value)
    @system = value
  end

  def manage_home(value)
    @manage_home = value
  end

  def non_unique(value)
    @non_unique = value
  end

  def action(value)
    @action = value
  end

  def only_if(&block)
    @only_if = block
  end

  def not_if(&block)
    @not_if = block
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
    uid_str = @uid ? @uid.to_s : ""
    gid_str = @gid ? @gid.to_s : ""

    ZigBackend.add_user(
      @username,
      uid_str,
      gid_str,
      @comment || "",
      @home || "",
      @shell || "",
      @password || "",
      @system,
      @manage_home,
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
