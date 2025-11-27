# Hola Provision Example
# Copy to ~/.config/hola/provision.rb and customize as needed

# Files
file '/tmp/hello.txt' do
  content "Hello from Hola!"
  mode "0644"
end

# Directories
directory "/tmp/myapp/logs" do
  mode "0755"
  recursive true
end

# Symbolic links
link "/usr/local/bin/myapp" do
  to "/opt/myapp/bin/app"
end

# Templates with variables
template '/tmp/config.yml' do
  source 'templates/config.yml.erb'
  mode "0644"
  variables({
    port: 8080,
    host: 'localhost'
  })
end

# Download files
remote_file '/tmp/goreman' do
  url 'https://example.com/releases/goreman'
  mode '0755'
end

# Execute commands
execute "setup-app" do
  command "./install.sh"
  cwd "/opt/myapp"
end

# Conditional execution
execute "install-oh-my-zsh" do
  command 'sh -c "$(curl -fsSL https://ohmyz.sh/install.sh)"'
  not_if { Dir.exist?(File.expand_path("~/.oh-my-zsh")) }
end

# Install packages
package "neovim"
package %w[git tmux curl]

# Systemd services (Linux)
systemd_unit "myapp.service" do
  content <<~UNIT
    [Unit]
    Description=My App

    [Service]
    ExecStart=/opt/myapp/start

    [Install]
    WantedBy=multi-user.target
  UNIT
  action [:create, :enable, :start]
end

# APT repositories (Debian/Ubuntu)
apt_repository "docker" do
  uri "https://download.docker.com/linux/ubuntu"
  distribution "jammy"
  components ["stable"]
  key_url "https://download.docker.com/linux/ubuntu/gpg"
end

apt_repository "neovim-ppa" do
  uri "ppa:neovim-ppa/unstable"
end

apt_update do
  action :update
end

# macOS Dock
macos_dock do
  apps [
    '/Applications/Google Chrome.app/',
    '/Applications/Ghostty.app/'
  ]
  orientation "bottom"
  autohide false
  tilesize 50
end

# macOS system preferences
macos_defaults 'keyboard repeat' do
  global true
  key 'KeyRepeat'
  value 1
end

macos_defaults 'show hidden files' do
  domain 'com.apple.finder'
  key 'AppleShowAllFiles'
  value true
end

# Network routes
route "192.168.100.0/24" do
  gateway "10.0.0.1"
  device "eth0"
end

# Custom Ruby code
ruby_block "custom-logic" do
  block do
    puts "Running custom Ruby code"
  end
end
