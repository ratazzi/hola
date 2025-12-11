module Hola
  module Test
    class AssertionError < StandardError; end
    @test_count = 0
    @pass_count = 0

    class << self
      attr_accessor :test_count, :pass_count
    end

    def self.assert(condition, message = "Assertion failed")
      raise AssertionError, message unless condition
    end

    def self.assert_equal(expected, actual, message = nil)
      return if expected == actual
      msg = message || "Expected #{expected.inspect}, got #{actual.inspect}"
      raise AssertionError, msg
    end

    def self.assert_file_exists(path)
      raise AssertionError, "File should exist: #{path}" unless File.exist?(path)
    end

    def self.assert_file_not_exists(path)
      raise AssertionError, "File should not exist: #{path}" if File.exist?(path)
    end

    def self.assert_file_content(path, expected)
      actual = File.read(path)
      return if actual == expected
      raise AssertionError, "Content mismatch in #{path}\n  expected: #{expected.inspect}\n  actual: #{actual.inspect}"
    end

    def self.assert_file_mode(path, expected_mode)
      stat = File.stat(path)
      actual = stat.mode & 0o777
      return if actual == expected_mode
      raise AssertionError, "Mode mismatch in #{path}: expected #{expected_mode.to_s(8)}, got #{actual.to_s(8)}"
    end

    def self.assert_directory_exists(path)
      raise AssertionError, "Directory should exist: #{path}" unless File.directory?(path)
    end

    def self.assert_link_exists(path)
      raise AssertionError, "Symlink should exist: #{path}" unless File.symlink?(path)
    end

    def self.assert_link_target(path, expected_target)
      actual = File.readlink(path)
      return if actual == expected_target
      raise AssertionError, "Link target mismatch: expected #{expected_target}, got #{actual}"
    end

    def self.pass(message)
      puts "✓ #{message}"
    end

    def self.fail(message)
      raise AssertionError, message
    end

    def self.summary
      puts "#{@pass_count}/#{@test_count} tests passed"
    end
  end
end

class TestCase
  def initialize(name, &block)
    @name = name
    Hola::Test.test_count += 1
    instance_eval(&block)
    Hola::Test.pass_count += 1
    puts "✓ #{name}"
  end

  def assert(condition, message = "Assertion failed")
    Hola::Test.assert(condition, message)
  end

  def assert_equal(expected, actual, message = nil)
    Hola::Test.assert_equal(expected, actual, message)
  end

  def assert_file_exists(path)
    Hola::Test.assert_file_exists(path)
  end

  def assert_file_not_exists(path)
    Hola::Test.assert_file_not_exists(path)
  end

  def assert_file_content(path, expected)
    Hola::Test.assert_file_content(path, expected)
  end

  def assert_file_mode(path, expected_mode)
    Hola::Test.assert_file_mode(path, expected_mode)
  end

  def assert_directory_exists(path)
    Hola::Test.assert_directory_exists(path)
  end

  def assert_link_exists(path)
    Hola::Test.assert_link_exists(path)
  end

  def assert_link_target(path, expected_target)
    Hola::Test.assert_link_target(path, expected_target)
  end
end

def test(name, &block)
  ruby_block "test: #{name}" do
    block_proc = proc { TestCase.new(name, &block) }
    self.block(&block_proc)
  end
end

def skip_test(name, reason = "skipped")
  ruby_block "test: #{name}" do
    block do
      Hola::Test.test_count += 1
      puts "○ #{name} (#{reason})"
    end
  end
end

def test_if(condition, name, &block)
  if condition
    test(name, &block)
  else
    skip_test(name, "condition not met")
  end
end

def linux?
  node["os"] == "linux"
end

def macos?
  node["os"] == "darwin"
end

def systemd?
  linux? && File.exist?("/run/systemd/system")
end

def test_summary
  ruby_block "test summary" do
    block { Hola::Test.summary }
  end
end
