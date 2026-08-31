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
      # Give Ruby-only composite resources a stable parent row in normal output.
      # Every resource declared inside the block inherits this display path.
      def with_resource_scope(type, name, action = :run)
        ok, message = ZigBackend.begin_resource_scope(type.to_s, name.to_s, action.to_s)
        raise message unless ok
        begin
          yield
        ensure
          ZigBackend.end_resource_scope
        end
      end

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

  module Phases
    @namespace = nil
    @listener = nil

    class << self
      def current
        ZigBackend.current_phase
      end

      def select(name)
        value = name.to_s
        raise ArgumentError, "phase name cannot be empty" if value.empty?
        qualified = @namespace && !@namespace.empty? ? "#{@namespace}:#{value}" : value
        set_raw(qualified)
        @listener.call(qualified) if @listener
        qualified
      end

      def restore(name)
        set_raw(name)
      end

      def with_import(namespace = nil, listener = nil)
        previous_current = current
        previous_namespace = @namespace
        previous_listener = @listener
        prefix = []
        prefix << previous_namespace if previous_namespace && !previous_namespace.empty?
        prefix << namespace.to_s if namespace && !namespace.to_s.empty?
        @namespace = prefix.join(":")
        @listener = listener
        set_raw(nil)
        begin
          yield
        ensure
          @namespace = previous_namespace
          @listener = previous_listener
          set_raw(previous_current)
        end
      end

      private

      def set_raw(name)
        ok, message = name ? ZigBackend.select_phase(name.to_s) : ZigBackend.clear_phase
        raise message unless ok
      end
    end
  end
end

module Hola
  module PhaseDSL
    def phase(name, &block)
      previous = Hola::Phases.current
      selected = Hola::Phases.select(name)
      return selected unless block
      begin
        block.call
      ensure
        Hola::Phases.restore(previous)
      end
      selected
    end

    private :phase
  end
end

Object.send(:include, Hola::PhaseDSL)
