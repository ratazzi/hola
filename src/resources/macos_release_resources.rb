module ZigBackend
end

module Hola
  module MacosResourceCommon
    def initialize_common
      @only_if_proc = nil
      @not_if_proc = nil
      @ignore_failure = false
      @notifications = []
      @subscriptions = []
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
      @notifications << [target_resource.to_s, action.to_s, timer.to_s]
    end

    def subscribes(action, source_resource, timer = :delayed)
      @subscriptions << [source_resource.to_s, action.to_s, timer.to_s]
    end

    def common_payload
      [
        @only_if_proc,
        @not_if_proc,
        @ignore_failure,
        @notifications,
        @subscriptions
      ]
    end
  end
end

class XcodeBuildResource
  include Hola::MacosResourceCommon

  def initialize(name, &block)
    @name = name.to_s
    @workspace = ""
    @project = ""
    @scheme = ""
    @configuration = "Release"
    @derived_data_path = ""
    @sdk = ""
    @destination = ""
    @archive_path = ""
    @action = "build"
    @settings = []
    @extra_args = []
    @creates = ""
    @clean = false
    @allow_provisioning_updates = false
    initialize_common
    instance_eval(&block) if block

    unless ZigBackend.respond_to?(:add_xcode_build)
      raise "xcode_build is only available on macOS"
    end

    ZigBackend.add_xcode_build([
      @name,
      @workspace,
      @project,
      @scheme,
      @configuration,
      @derived_data_path,
      @sdk,
      @destination,
      @archive_path,
      @action,
      @settings,
      @extra_args,
      @creates,
      @clean,
      @allow_provisioning_updates,
      *common_payload
    ])
  end

  def workspace(value)
    @workspace = File.expand_path(value.to_s)
  end

  def project(value)
    @project = File.expand_path(value.to_s)
  end

  def scheme(value)
    @scheme = value.to_s
  end

  def configuration(value)
    @configuration = value.to_s
  end

  def derived_data_path(value)
    @derived_data_path = File.expand_path(value.to_s)
  end

  def sdk(value)
    @sdk = value.to_s
  end

  def destination(value)
    @destination = value.to_s
  end

  def archive_path(value)
    @archive_path = File.expand_path(value.to_s)
  end

  def action(value)
    @action = value.to_s
  end

  def settings(value)
    @settings = value.map { |key, item| [key.to_s, item.to_s] }
  end

  def extra_args(value)
    @extra_args = Array(value).map(&:to_s)
  end

  def creates(value)
    @creates = File.expand_path(value.to_s)
  end

  def clean(value = true)
    @clean = value
  end

  def allow_provisioning_updates(value = true)
    @allow_provisioning_updates = value
  end
end

class MacosSigningCertificateResource
  include Hola::MacosResourceCommon

  def initialize(identity, &block)
    @identity = identity.to_s
    @certificate_base64 = ""
    @certificate_path = ""
    @password = ""
    @keychain = File.expand_path("build.keychain")
    @keychain_password = ""
    @make_default = false
    @action = "import"
    initialize_common
    instance_eval(&block) if block

    unless ZigBackend.respond_to?(:add_macos_signing_certificate)
      raise "macos_signing_certificate is only available on macOS"
    end

    ZigBackend.add_macos_signing_certificate([
      @identity,
      @certificate_base64,
      @certificate_path,
      @password,
      @keychain,
      @keychain_password,
      @make_default,
      @action,
      *common_payload
    ])
  end

  def certificate_base64(value)
    @certificate_base64 = value.to_s
  end

  def certificate(value)
    @certificate_path = File.expand_path(value.to_s)
  end

  def password(value)
    @password = value.to_s
  end

  def keychain(value)
    @keychain = File.expand_path(value.to_s)
  end

  def keychain_password(value)
    @keychain_password = value.to_s
  end

  def make_default(value = true)
    @make_default = value
  end

  def action(value)
    @action = value.to_s
  end
end

class MacosCodesignResource
  include Hola::MacosResourceCommon

  def initialize(path, &block)
    @path = File.expand_path(path.to_s)
    @identity = "-"
    @identifier = ""
    @entitlements = ""
    @requirements = ""
    @library_constraint = ""
    @options = ["runtime"]
    @timestamp = "auto"
    @keychain = ""
    @nested = false
    @verify = true
    @action = "sign"
    initialize_common
    instance_eval(&block) if block

    unless ZigBackend.respond_to?(:add_macos_codesign)
      raise "macos_codesign is only available on macOS"
    end

    ZigBackend.add_macos_codesign([
      @path,
      @identity,
      @identifier,
      @entitlements,
      @requirements,
      @library_constraint,
      @options,
      @timestamp,
      @keychain,
      @nested,
      @verify,
      @action,
      *common_payload
    ])
  end

  def identity(value)
    @identity = value.to_s
  end

  def identifier(value)
    @identifier = value.to_s
  end

  def entitlements(value)
    @entitlements = File.expand_path(value.to_s)
  end

  def requirements(value)
    @requirements = value.to_s
  end

  def library_constraint(value)
    @library_constraint = File.expand_path(value.to_s)
  end

  def options(value)
    @options = Array(value).map(&:to_s)
  end

  def hardened_runtime(value = true)
    @options = value ? ["runtime"] : []
  end

  def timestamp(value = true)
    @timestamp = value.to_s
  end

  def keychain(value)
    @keychain = File.expand_path(value.to_s)
  end

  def nested(value = true)
    @nested = value
  end

  def verify(value = true)
    @verify = value
  end

  def action(value)
    @action = value.to_s
  end
end

class MacosDmgResource
  include Hola::MacosResourceCommon

  def initialize(path, &block)
    @path = File.expand_path(path.to_s)
    @source = ""
    @volume_name = File.basename(path.to_s, ".dmg")
    @format = "UDZO"
    @filesystem = "HFS+"
    @applications_link = true
    @background = ""
    @icon_size = 128
    @window_bounds = []
    @icon_positions = []
    @force = false
    @verify = true
    @action = "create"
    initialize_common
    instance_eval(&block) if block

    unless ZigBackend.respond_to?(:add_macos_dmg)
      raise "macos_dmg is only available on macOS"
    end

    ZigBackend.add_macos_dmg([
      @path,
      @source,
      @volume_name,
      @format,
      @filesystem,
      @applications_link,
      @background,
      @icon_size,
      @window_bounds,
      @icon_positions,
      @force,
      @verify,
      @action,
      *common_payload
    ])
  end

  def source(value)
    @source = File.expand_path(value.to_s)
  end

  def volume_name(value)
    @volume_name = value.to_s
  end

  def format(value)
    @format = value.to_s
  end

  def filesystem(value)
    @filesystem = value.to_s
  end

  def applications_link(value = true)
    @applications_link = value
  end

  def background(value)
    @background = File.expand_path(value.to_s)
  end

  def icon_size(value)
    @icon_size = value.to_i
  end

  def window_bounds(value)
    @window_bounds = Array(value).map(&:to_i)
  end

  def icon_position(name, coordinates)
    point = Array(coordinates)
    @icon_positions << [name.to_s, point[0].to_i, point[1].to_i]
  end

  def force(value = true)
    @force = value
  end

  def verify(value = true)
    @verify = value
  end

  def action(value)
    @action = value.to_s
  end
end

class MacosNotarizeResource
  include Hola::MacosResourceCommon

  def initialize(path, &block)
    @path = File.expand_path(path.to_s)
    @keychain_profile = ""
    @apple_id = ""
    @team_id = ""
    @password = ""
    @key = ""
    @key_id = ""
    @issuer = ""
    @staple = true
    @validate = true
    @assess = true
    @action = "submit"
    initialize_common
    instance_eval(&block) if block

    unless ZigBackend.respond_to?(:add_macos_notarize)
      raise "macos_notarize is only available on macOS"
    end

    ZigBackend.add_macos_notarize([
      @path,
      @keychain_profile,
      @apple_id,
      @team_id,
      @password,
      @key,
      @key_id,
      @issuer,
      @staple,
      @validate,
      @assess,
      @action,
      *common_payload
    ])
  end

  def keychain_profile(value)
    @keychain_profile = value.to_s
  end

  def apple_id(value)
    @apple_id = value.to_s
  end

  def team_id(value)
    @team_id = value.to_s
  end

  def password(value)
    @password = value.to_s
  end

  def api_key(path, key_id, issuer)
    @key = File.expand_path(path.to_s)
    @key_id = key_id.to_s
    @issuer = issuer.to_s
  end

  def staple(value = true)
    @staple = value
  end

  def validate(value = true)
    @validate = value
  end

  def assess(value = true)
    @assess = value
  end

  def action(value)
    @action = value.to_s
  end
end

def xcode_build(name, &block)
  XcodeBuildResource.new(name, &block)
end

def macos_signing_certificate(identity, &block)
  MacosSigningCertificateResource.new(identity, &block)
end

def macos_codesign(path, &block)
  MacosCodesignResource.new(path, &block)
end

def macos_dmg(path, &block)
  MacosDmgResource.new(path, &block)
end

def macos_notarize(path, &block)
  MacosNotarizeResource.new(path, &block)
end
