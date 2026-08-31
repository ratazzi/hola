ROOT = "/tmp/hola-output-failures/provision"
READ_ONLY_DIR = "#{ROOT}/read-only"
PARENT_FILE = "#{ROOT}/parent-is-a-file"

directory ROOT do
  recursive true
  mode "0755"
end

file PARENT_FILE do
  content "this path is intentionally a regular file\n"
end

directory READ_ONLY_DIR do
  recursive true
  mode "0555"
end

execute "non-zero command with captured output" do
  command "printf 'compile started\\n'; printf 'main.c:42:7: error: expected semicolon\\n' >&2; exit 7"
  live_stream true
  ignore_failure true
end

execute "missing command" do
  command "/definitely/missing/hola-command --version"
  ignore_failure true
end

execute "timed out command" do
  command "printf 'starting slow step\\n'; sleep 3"
  live_stream true
  timeout 1
  ignore_failure true
end

execute "missing parent working directory" do
  command "pwd"
  cwd "#{ROOT}/missing-parent/worktree"
  ignore_failure true
end

template "#{ROOT}/rendered.conf" do
  source "definitely-missing-template.erb"
  variables "environment" => "test"
  ignore_failure true
end

file "#{PARENT_FILE}/child.txt" do
  content "cannot be created\n"
  ignore_failure true
end

file "#{READ_ONLY_DIR}/cannot-write.txt" do
  content "cannot be written\n"
  ignore_failure true
end

# Restore permissions so the fixture can always be removed by the next run.
directory READ_ONLY_DIR do
  mode "0755"
end

ruby_block "raise from provision code" do
  block do
    raise "simulated Ruby failure from provision.rb"
  end
  ignore_failure true
end

Hola::Resources.with_resource_scope "release_bundle", "demo application", :create do
  execute "nested signing failure" do
    command "printf 'sign stdout\\n'; printf 'codesign: invalid identity\\n' >&2; exit 17"
    live_stream true
    ignore_failure true
  end
end

execute "guarded command" do
  command "exit 99"
  only_if { false }
end
