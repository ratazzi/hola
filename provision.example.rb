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

# Download files from HTTP/HTTPS
remote_file '/tmp/goreman' do
  url 'https://example.com/releases/goreman'
  mode '0755'
  checksum 'sha256:abc123...'  # Optional: verify file integrity
  use_etag true                 # Optional: conditional download (default: true)
end

# Download with HTTP Basic Auth
remote_file '/tmp/private-file.zip' do
  source 'https://private.example.com/file.zip'
  remote_user 'username'
  remote_password 'password'
  mode '0644'
end

# Download from SFTP
remote_file '/tmp/backup.tar.gz' do
  source 'sftp://backup.example.com/backups/latest.tar.gz'
  remote_user 'deploy'
  ssh_private_key File.expand_path('~/.ssh/id_rsa')
  ssh_known_hosts File.expand_path('~/.ssh/known_hosts')
  mode '0600'
end

# Download from S3
remote_file '/tmp/data.json' do
  source 's3://my-bucket/data/file.json'
  aws_access_key_id ENV['AWS_ACCESS_KEY_ID']
  aws_secret_access_key ENV['AWS_SECRET_ACCESS_KEY']
  aws_region 'us-east-1'
  mode '0644'
end

# Download from S3-compatible service (e.g., R2, MinIO)
remote_file '/tmp/asset.tar.gz' do
  source 's3://my-bucket/assets/archive.tar.gz'
  aws_access_key_id ENV['R2_ACCESS_KEY_ID']
  aws_secret_access_key ENV['R2_SECRET_ACCESS_KEY']
  aws_endpoint 'https://abc123.r2.cloudflarestorage.com'
  aws_region 'auto'
  mode '0644'
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
