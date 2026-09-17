# Shared local-file loading for provision scripts and Holafiles.
module Hola
  class LoadError < ScriptError
  end
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
  known = %w[fileutils json time base64 set ostruct]
  known += %w[rake rake/tasklib rake/clean] if Object.const_defined?(:Rake)
  if name.to_s == "rake/clean" && Object.const_defined?(:Rake)
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
  current_file = $hola_load_stack.last || $hola_scriptfile || $hola_taskfile
  base = current_file ? File.dirname(current_file) : Dir.pwd
  hola_load_ruby_file(File.join(base, name.to_s), true)
end
