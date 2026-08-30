module Hola
  class ResourceError < StandardError
  end

  class LoadError < ScriptError
  end

  module Rake
    RESOURCE_DSL = Hola::Resources::DSL_METHODS

    class TaskArguments
      attr_reader :names

      def initialize(names, values)
        @names = Array(names).map { |name| name.to_sym }
        @values = Array(values)
        @hash = {}
        @names.each_with_index do |name, index|
          @hash[name] = @values[index]
        end
      end

      def [](key)
        return @values[key] if key.is_a?(Integer)
        @hash[key.to_sym]
      end

      def to_hash
        @hash.dup
      end

      def with_defaults(defaults)
        defaults.each do |key, value|
          symbol = key.to_sym
          @hash[symbol] = value unless @hash.key?(symbol) && !@hash[symbol].nil?
        end
        self
      end

      def extras
        @values[@names.length..-1] || []
      end

      def new_scope(new_names)
        names = Array(new_names).map { |name| name.to_sym }
        values = names.map { |name| @hash[name] }
        TaskArguments.new(names, values)
      end

      def method_missing(name, *args, &block)
        return @hash[name] if args.empty? && block.nil? && @hash.key?(name)
        super
      end

      def respond_to_missing?(name, include_private = false)
        @hash.key?(name) || super
      end
    end

    class Task
      attr_reader :name, :prerequisites, :actions, :arg_names, :description, :scope
      attr_accessor :source

      def self.[](name)
        Hola::Rake.application.lookup!(name.to_s, Hola::Rake.application.current_scope)
      end

      def self.tasks
        Hola::Rake.application.tasks.values
      end

      def self.task_defined?(name)
        !Hola::Rake.application.lookup(name.to_s, Hola::Rake.application.current_scope).nil?
      end

      def self.define_task(*definition, &block)
        Hola::Rake.application.define_task(self, *definition, &block)
      end

      def self.clear
        Hola::Rake.application.clear
      end

      def initialize(application, name, prerequisites = [], arg_names = [], description = nil, scope = [])
        @application = application
        @name = name.to_s
        @prerequisites = []
        @actions = []
        @arg_names = Array(arg_names).map { |item| item.to_sym }
        @description = description
        @scope = Array(scope).dup
        @already_invoked = false
        @source = nil
        enhance(prerequisites)
      end

      def enhance(dependencies = nil, &block)
        Array(dependencies).flatten.each do |dependency|
          value = dependency.to_s
          @prerequisites << value unless @prerequisites.include?(value)
        end
        @actions << block if block
        self
      end

      def add_description(description)
        @description = description if description
        self
      end

      def invoke(*values)
        args = TaskArguments.new(@arg_names, values)
        invoke_with_call_chain(args, [])
      end

      def invoke_with_call_chain(args, chain)
        puts "** Invoke #{@name}" if Hola::Rake.trace?
        if chain.include?(@name)
          raise "Circular dependency detected: #{(chain + [@name]).join(' => ')}"
        end
        return self if @already_invoked

        @already_invoked = true
        next_chain = chain + [@name]
        @prerequisites.each do |dependency|
          task = @application.lookup!(dependency, @scope)
          task.invoke_with_call_chain(args.new_scope(task.arg_names), next_chain)
        end
        execute(args) if needed?
        self
      end

      def execute(args = nil)
        args ||= TaskArguments.new(@arg_names, [])
        Hola::Rake.begin_task(@name)
        if Hola::Rake.dry_run?
          puts "** Execute #{@name} (dry run)"
          return self
        end
        puts "** Execute #{@name}" if Hola::Rake.trace?
        @actions.each do |action|
          failure_checkpoint = ZigBackend.failure_checkpoint
          action.call(self, args)
          Hola::Rake.converge!
          ZigBackend.handle_failures_since(failure_checkpoint)
        end
        Hola::Rake.converge!
        self
      end

      def reenable
        @already_invoked = false
        self
      end

      def already_invoked
        @already_invoked
      end

      def needed?
        true
      end

      def timestamp
        Time.now
      end

      def clear
        clear_prerequisites
        clear_actions
        self
      end

      def clear_actions
        @actions.clear
        self
      end

      def clear_prerequisites
        @prerequisites.clear
        self
      end

      def all_prerequisite_tasks
        result = []
        @prerequisites.each do |dependency|
          task = @application.lookup!(dependency, @scope)
          result << task unless result.include?(task)
          task.all_prerequisite_tasks.each { |item| result << item unless result.include?(item) }
        end
        result
      end

      def investigation
        "Task #{@name}: prerequisites=#{@prerequisites.inspect}, already_invoked=#{@already_invoked}"
      end

      def to_s
        @name
      end
    end

    class FileTask < Task
      def needed?
        return true unless File.exist?(@name)
        own_timestamp = timestamp
        @prerequisites.any? do |dependency|
          task = @application.lookup!(dependency, @scope)
          task.timestamp > own_timestamp
        end
      end

      def timestamp
        File.exist?(@name) ? File.mtime(@name) : Time.at(0)
      end
    end

    class Application
      attr_reader :tasks, :current_scope

      def initialize
        @tasks = {}
        @current_scope = []
        @last_description = nil
        @rules = []
        @rule_stack = []
      end

      def clear
        @tasks.clear
        @rules.clear
        @last_description = nil
      end

      def [](name)
        lookup!(name, @current_scope)
      end

      def task_defined?(name)
        !lookup(name, @current_scope).nil?
      end

      def last_description=(description)
        @last_description = description
      end

      def define_task(task_class, *definition, &block)
        parsed = parse_definition(definition)
        full_name = qualify(parsed[:name])
        task = @tasks[full_name]
        unless task
          task = task_class.new(self, full_name, [], parsed[:arg_names], @last_description, @current_scope)
          @tasks[full_name] = task
        end
        task.add_description(@last_description)
        task.enhance(parsed[:dependencies], &block)
        @last_description = nil
        task
      end

      def define_rule(*definition, &block)
        parsed = parse_rule(definition)
        @rules << {
          :target => parsed[:target],
          :source => parsed[:source],
          :dependencies => parsed[:dependencies],
          :action => block,
        }
        nil
      end

      def in_namespace(name)
        @current_scope << name.to_s
        begin
          yield
        ensure
          @current_scope.pop
        end
      end

      def lookup(name, scope = @current_scope)
        return name if name.is_a?(Task)
        task_name = name.to_s
        candidates = []

        if task_name.start_with?("^")
          candidates << task_name[1..-1]
        elsif task_name.include?(":")
          index = scope.length
          while index > 0
            candidates << (scope[0...index] + [task_name]).join(":")
            index -= 1
          end
          candidates << task_name
        else
          index = scope.length
          while index >= 0
            prefix = scope[0...index]
            candidates << (prefix + [task_name]).join(":")
            index -= 1
          end
        end

        candidates.each do |candidate|
          return @tasks[candidate] if @tasks.key?(candidate)
        end
        nil
      end

      def lookup!(name, scope = @current_scope)
        task = lookup(name, scope)
        return task if task

        task_name = name.to_s
        return synthesize_file_task(task_name) if File.exist?(task_name)
        task = synthesize_rule(task_name)
        return task if task
        raise "Don't know how to build task '#{task_name}'"
      end

      def parse_task_string(value)
        text = value.to_s
        open_index = text.index("[")
        return [text, []] unless open_index
        return [text, []] unless text.end_with?("]")

        name = text[0...open_index]
        body = text[(open_index + 1)...-1]
        values = body.empty? ? [] : body.split(",").map { |item| item.strip }
        [name, values]
      end

      def run(argv)
        requested = []
        Array(argv).each do |argument|
          if environment_assignment?(argument)
            separator = argument.index("=")
            ENV[argument[0...separator]] = argument[(separator + 1)..-1]
          else
            requested << argument
          end
        end
        requested = ["default"] if requested.empty?
        requested.each do |task_string|
          name, values = parse_task_string(task_string)
          lookup!(name, @current_scope).invoke(*values)
        end
      end

      def list_tasks
        described = @tasks.values.select { |task| task.description && !task.description.empty? }
        described.sort_by { |task| task.name }.each do |task|
          signature = task.name
          unless task.arg_names.empty?
            signature += "[#{task.arg_names.join(',')}]"
          end
          padding = " " * [1, 28 - signature.length].max
          puts "hola run #{signature}#{padding}# #{task.description}"
        end
      end

      def list_prerequisites
        @tasks.values.sort_by { |task| task.name }.each do |task|
          puts "hola run #{task.name}"
          task.prerequisites.each { |dependency| puts "    #{dependency}" }
        end
      end

      private

      def qualify(name)
        (@current_scope + [name.to_s]).join(":")
      end

      def parse_definition(definition)
        name = nil
        arg_names = []
        dependencies = []
        first = definition[0]

        if first.is_a?(Hash)
          key, value = first.first
          if key.is_a?(Array)
            name = key[0]
            arg_names = key[1] || []
          else
            name = key
          end
          dependencies = value
        else
          name = first
          second = definition[1]
          if second.is_a?(Hash)
            key, value = second.first
            arg_names = key if key.is_a?(Array)
            dependencies = value
          elsif second.is_a?(Array)
            arg_names = second
            dependencies = definition[2] || []
          elsif second
            dependencies = second
          end
        end

        raise "Task name is required" if name.nil?
        {
          :name => name.to_s,
          :arg_names => Array(arg_names),
          :dependencies => Array(dependencies).flatten,
        }
      end

      def parse_rule(definition)
        first = definition[0]
        raise "Rule definition must be a Hash" unless first.is_a?(Hash)
        target, source_spec = first.first
        sources = Array(source_spec)
        source = sources.shift
        raise "Rule source is required" if source.nil?
        {
          :target => target.to_s,
          :source => source.to_s,
          :dependencies => sources,
        }
      end

      def synthesize_file_task(name)
        @tasks[name] ||= FileTask.new(self, name, [], [], nil, [])
      end

      def synthesize_rule(name)
        return nil if @rule_stack.include?(name)
        @rule_stack << name
        begin
          @rules.reverse_each do |rule|
            target_suffix = rule[:target]
            next unless name.end_with?(target_suffix)
            stem = name[0...(name.length - target_suffix.length)]
            source = stem + rule[:source]
            next unless File.exist?(source) || lookup(source, []) || matching_rule?(source)

            dependencies = [source] + rule[:dependencies]
            task = FileTask.new(self, name, dependencies, [], nil, [])
            task.source = source
            task.enhance([], &rule[:action]) if rule[:action]
            @tasks[name] = task
            return task
          end
        ensure
          @rule_stack.pop
        end
        nil
      end

      def matching_rule?(name)
        @rules.any? { |rule| name.end_with?(rule[:target]) }
      end

      def environment_assignment?(argument)
        separator = argument.index("=")
        return false unless separator && separator > 0
        key = argument[0...separator]
        key.bytes.each_with_index do |byte, index|
          alpha = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
          digit = byte >= 48 && byte <= 57
          return false unless alpha || byte == 95 || (index > 0 && digit)
        end
        true
      end
    end

    class << self
      attr_writer :application

      def application
        @application ||= Application.new
      end

      def immediate?
        $hola_run_immediate == true
      end

      def dry_run?
        $hola_run_dry == true
      end

      def trace?
        $hola_run_trace == true
      end

      def converge!
        return unless immediate?
        return if dry_run?
        ok, message = ZigBackend.converge
        raise Hola::ResourceError, message unless ok
      end

      def flush_delayed!
        ok, message = ZigBackend.flush_delayed
        raise Hola::ResourceError, message unless ok
      end

      def begin_task(name)
        ok, message = ZigBackend.display_section(name.to_s)
        raise Hola::ResourceError, message unless ok
      end

      def install_immediate_resource!(resources_class, method_name, original)
        resources_class.send(:alias_method, original, method_name)
        resources_class.send(:private, original)
        resources_class.send(:define_method, method_name) do |*args, &block|
          result = send(original, *args, &block)
          Hola::Rake.converge!
          result
        end
      end

      def install_immediate_mode!
        resources_class = class << Hola::Resources; self; end
        RESOURCE_DSL.each do |name|
          method_name = name.to_sym
          next unless Hola::Resources.respond_to?(method_name)
          original = ("hola_deferred_resource_" + name).to_sym
          installed = resources_class.private_instance_methods.include?(original) ||
            resources_class.instance_methods.include?(original)
          next if installed
          install_immediate_resource!(resources_class, method_name, original)
        end
      end

      def main
        if $hola_run_list
          application.list_tasks
          $hola_run_status = 0
          return
        end
        if $hola_run_prerequisites
          application.list_prerequisites
          $hola_run_status = 0
          return
        end

        begin
          $hola_run_immediate = true
          converge!
          application.run($hola_run_argv || [])
          flush_delayed!
          $hola_run_status = 0
        rescue Hola::ResourceError => error
          location = error.backtrace && error.backtrace[0]
          puts(location ? "Task aborted at #{location}" : "Task aborted")
          $hola_run_status = 1
        rescue Exception => error
          puts "hola aborted!"
          puts error.message
          if error.backtrace
            error.backtrace[0, 8].each { |line| puts line }
          end
          $hola_run_status = 1
        end
      end
    end
  end
end

module Rake
  Task = Hola::Rake::Task
  FileTask = Hola::Rake::FileTask
  TaskArguments = Hola::Rake::TaskArguments
  Application = Hola::Rake::Application

  module DSL
    def desc(description)
      Hola::Rake.application.last_description = description.to_s
    end

    def task(*definition, &block)
      Hola::Rake.application.define_task(Hola::Rake::Task, *definition, &block)
    end

    def file(*definition, &block)
      Hola::Rake.application.define_task(Hola::Rake::FileTask, *definition, &block)
    end

    def file_task(*definition, &block)
      file(*definition, &block)
    end

    def directory(*definition, &block)
      Hola::Rake.application.define_task(Hola::Rake::FileTask, *definition) do |task, args|
        mkdir_p(task.name)
        block.call(task, args) if block
      end
    end

    def multitask(*definition, &block)
      task(*definition, &block)
    end

    def namespace(name, &block)
      Hola::Rake.application.in_namespace(name, &block)
    end

    def default(*dependencies)
      task({:default => dependencies.flatten})
    end

    def rule(*definition, &block)
      Hola::Rake.application.define_rule(*definition, &block)
    end

    def resources(&block)
      return Hola::Resources unless block
      Hola::Resources.instance_eval(&block)
    end

    private :desc, :task, :file, :file_task, :directory, :multitask, :namespace, :default, :rule, :resources
  end

  class TaskLib
    include DSL
  end

  class << self
    def application
      Hola::Rake.application
    end

    def application=(value)
      Hola::Rake.application = value
    end
  end
end

class Dir
  class << self
    def glob(pattern, *flags, &block)
      results = ZigBackend.glob(pattern.to_s)
      if block
        results.each(&block)
        nil
      else
        results
      end
    end

    def [](*patterns)
      patterns.map { |pattern| glob(pattern) }.flatten
    end
  end
end

class FileList < Array
  def self.[](*patterns)
    new(*patterns)
  end

  def initialize(*patterns)
    super()
    include(*patterns)
  end

  def include(*patterns)
    patterns.flatten.each do |pattern|
      values = pattern.to_s.index("*") || pattern.to_s.index("?") || pattern.to_s.index("[")
      entries = values ? Dir.glob(pattern.to_s) : [pattern.to_s]
      entries.each { |entry| self << entry unless self.include?(entry) }
    end
    self
  end

  def exclude(*patterns)
    rejected = patterns.flatten.map do |pattern|
      value = pattern.to_s
      wildcard = value.index("*") || value.index("?") || value.index("[")
      wildcard ? Dir.glob(value) : [value]
    end.flatten
    delete_if { |entry| rejected.include?(entry) }
    self
  end

  def existing
    FileList.new.concat(select { |entry| File.exist?(entry) })
  end

  def ext(new_extension = nil)
    return map { |entry| File.extname(entry) } if new_extension.nil?
    map do |entry|
      extension = File.extname(entry)
      base = extension.empty? ? entry : entry[0...(entry.length - extension.length)]
      base + new_extension.to_s
    end
  end

  def to_a
    Array.new(self)
  end
end

Rake::FileList = FileList
CLEAN = FileList.new unless Object.const_defined?(:CLEAN)
CLOBBER = FileList.new unless Object.const_defined?(:CLOBBER)

module FileUtils
  def mkdir_p(path)
    value = path.to_s
    current = value.start_with?("/") ? "/" : ""
    value.split("/").each do |part|
      next if part.empty? || part == "."
      current = if current == "/"
        "/#{part}"
      elsif current.empty?
        part
      else
        "#{current}/#{part}"
      end
      Dir.mkdir(current) unless File.directory?(current)
    end
    [value]
  end

  def rm_f(path)
    File.delete(path.to_s) if File.exist?(path.to_s)
    nil
  rescue Exception
    nil
  end

  def rm_rf(path)
    value = path.to_s
    return nil unless File.exist?(value) || File.directory?(value)
    if File.directory?(value)
      Dir.entries(value).each do |entry|
        next if entry == "." || entry == ".."
        rm_rf(File.join(value, entry))
      end
      Dir.rmdir(value)
    else
      File.delete(value)
    end
    nil
  end

  def cp(source, destination)
    data = File.open(source.to_s, "rb") { |file| file.read }
    File.open(destination.to_s, "wb") { |file| file.write(data) }
    destination
  end

  def mv(source, destination)
    File.rename(source.to_s, destination.to_s)
    destination
  end

  def touch(path)
    File.open(path.to_s, "a") { |file| file.write("") }
    path
  end

  def cd(directory)
    previous = Dir.pwd
    Dir.chdir(directory.to_s)
    return directory unless block_given?
    begin
      yield directory
    ensure
      Dir.chdir(previous)
    end
  end

  module_function :mkdir_p, :rm_f, :rm_rf, :cp, :mv, :touch, :cd
end

include FileUtils
Rake::FileUtilsExt = FileUtils
include Rake::DSL

def sh(command_text, options = {}, &block)
  if block
    raise ArgumentError, "sh block form is not supported; use resources.execute with ignore_failure"
  end
  options ||= {}
  if Hola::Rake.dry_run?
    puts command_text.to_s
    return true
  end
  Hola::Resources.execute(command_text.to_s) do
    self.command(command_text.to_s)
    live_stream(true)
    cwd(options[:cwd].to_s) if options[:cwd]
    environment(options[:env] || {})
  end
end

def abort(message = "")
  raise RuntimeError, message.to_s
end

$hola_required_files ||= []
$hola_load_stack ||= []

def hola_load_ruby_file(path, once = false)
  candidate = File.expand_path(path.to_s)
  candidate += ".rb" if !File.exist?(candidate) && File.exist?(candidate + ".rb")
  return false if once && $hola_required_files.include?(candidate)

  $hola_load_stack << candidate
  begin
    ok, message = ZigBackend.load_file(candidate)
    raise Hola::LoadError, message unless ok
    $hola_required_files << candidate if once
  ensure
    $hola_load_stack.pop
  end
  true
end

def load(path)
  hola_load_ruby_file(path, false)
end

def require(name)
  known = %w[rake rake/tasklib rake/clean fileutils json time base64 set ostruct]
  if name.to_s == "rake/clean"
    unless Hola::Rake.application.lookup("clean", [])
      Hola::Rake.application.define_task(Hola::Rake::Task, :clean) { CLEAN.each { |path| rm_rf(path) } }
      Hola::Rake.application.define_task(Hola::Rake::Task, {:clobber => :clean}) { CLOBBER.each { |path| rm_rf(path) } }
    end
    return false
  end
  return false if known.include?(name.to_s)
  if name.to_s.start_with?(".") || name.to_s.start_with?("/") || File.exist?(name.to_s) || File.exist?(name.to_s + ".rb")
    return hola_load_ruby_file(name, true)
  end
  raise Hola::LoadError, "cannot load such file -- #{name}"
end

def require_relative(name)
  current_file = $hola_load_stack.last || $hola_taskfile
  base = current_file ? File.dirname(current_file) : Dir.pwd
  hola_load_ruby_file(File.join(base, name.to_s), true)
end

def import(*files)
  files.flatten.each { |path| hola_load_ruby_file(path, false) }
end

Hola::Rake.install_immediate_mode!

if $hola_run_capture_output
  unless Object.private_instance_methods.include?(:hola_original_puts) || Object.instance_methods.include?(:hola_original_puts)
    Object.send(:alias_method, :hola_original_puts, :puts)
    Object.send(:define_method, :puts) do |*values|
      values = [""] if values.empty?
      values.each do |value|
        if value.is_a?(Array)
          value.each { |item| puts(item) }
        else
          ok, message = ZigBackend.print_line(value.nil? ? "nil" : value.to_s)
          raise Hola::ResourceError, message unless ok
        end
      end
      nil
    end
    Object.send(:private, :puts)
  end
end
