module Hola
  module Resources
    CANDIDATE_METHODS = %w[
      file directory execute remote_file template link route
      macos_dock macos_defaults apt_repository systemd_unit mount
      package homebrew_package apt_package ruby_block git user group
      aws_kms file_edit extract apt_update
    ]

    DSL_METHODS = []
    @receiver = Object.new

    class << self
      def register(method_name, original_name)
        resources_class = class << self; self; end
        resources_class.send(:define_method, method_name) do |*args, &block|
          @receiver.send(original_name, *args, &block)
        end
      end

      private :register
    end

    CANDIDATE_METHODS.each do |name|
      method_name = name.to_sym
      available = Object.private_instance_methods.include?(method_name) ||
        Object.instance_methods.include?(method_name)
      next unless available

      original_name = ("hola_resource_" + name).to_sym
      installed = Object.private_instance_methods.include?(original_name) ||
        Object.instance_methods.include?(original_name)
      Object.send(:alias_method, original_name, method_name) unless installed
      register(method_name, original_name)
      DSL_METHODS << name
    end
  end
end
