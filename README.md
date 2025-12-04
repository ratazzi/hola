# Hola

> **Brewfile + mise.toml + dotfiles = Done**

Set up your Mac in minutes.
Hola is a single-binary configuration manager written in Zig. It installs Homebrew packages, sets up dotfiles, and configures macOS defaults—all from a single command.

## What You Need

Create `username/dotfiles` on GitHub with three simple files:

### 1. 🍺 **~/.Brewfile** (Homebrew's native format)

```ruby
brew "tmux"
brew "neovim"
cask "ghostty"
cask "zed@preview"
cask "orbstack"
```

Homebrew integration.

### 2. 🛠️ **mise.toml** (mise's native format)

```toml
[tools]
node = "24"
python = "3.14"
```

Lock your tool versions. Never drift.

### 3. 📂 **~/.dotfiles/** (your dotfiles)

```
dotfiles/.zshrc      → ~/.zshrc
dotfiles/.gitconfig  → ~/.gitconfig
```

Symlink mapping. Dead simple.

**No custom syntax. No learning required.**

---

## Installation

### Quick Install (Recommended)

```bash
curl -fsSL https://hola.ac/install | bash
```

This downloads the binary for your architecture (arm64/x86_64) and installs it to the current directory.

### Homebrew

```bash
brew install ratazzi/hola/hola
```

### Manual Download

Download the latest release from [GitHub Releases](https://github.com/ratazzi/hola/releases):

```bash
# macOS (Apple Silicon)
curl -fsSL https://github.com/ratazzi/hola/releases/latest/download/hola-macos-aarch64 -o hola
chmod +x hola
xattr -d com.apple.quarantine hola
sudo mv hola /usr/local/bin/

# Linux (x86_64)
curl -fsSL https://github.com/ratazzi/hola/releases/latest/download/hola-linux-x86_64 -o hola
chmod +x hola
sudo mv hola /usr/local/bin/
```

---

## Why Hola?

### Convention Over Configuration

- **Zero learning curve**: Use Brewfile and mise.toml you already know
- **No custom syntax**: No templates, no special comments, no magic
- **Native integration**: First-class Homebrew and mise support
- **macOS declarative**: Configure Dock and system preferences as code
- **Tool version locking**: Reproducible environments across machines

### It Just Works™

```bash
# One command to set up everything
hola apply

# Packages, tools, dotfiles, and system settings - all done
```

---

## Advanced: ~/.config/hola/provision.rb (Optional)

**90% of users only need Brewfile + mise.toml + dotfiles/.**

For the other 10% who need complex logic, we provide a beautiful Ruby DSL:

```ruby
# resources.rb - reads like English, because it's Ruby

file "/etc/hosts" do
  content "127.0.0.1 local.dev"
end

execute "install-oh-my-zsh" do
  command 'sh -c "$(curl -fsSL https://ohmyz.sh/install.sh)"'
  not_if { Dir.exist?("~/.oh-my-zsh") }
end
```

###  macOS Native Integration

Configure macOS settings declaratively with **full type safety**:

```ruby
# Configure macOS Dock
macos_dock do
  apps [
    '/Applications/Google Chrome.app/',
    '/Applications/Zed Preview.app/',
    '/Applications/Ghostty.app/',
  ]
  orientation "bottom"
  autohide false
  magnification true
  tilesize 50
  largesize 40
end

# Keyboard repeat rate (lower = faster)
macos_defaults 'keyboard repeat rate' do
  global true
  key 'KeyRepeat'
  value 1
end

macos_defaults 'initial key repeat delay' do
  global true
  key 'InitialKeyRepeat'
  value 15
end

macos_defaults 'show all file extensions' do
  domain 'com.apple.finder'
  key 'AppleShowAllExtensions'
  value true
end
```

**Features:**
- ✅ **Type-safe**: Boolean, Integer, Float, String - automatically handled
- ✅ **Idempotent**: Only updates when values differ
- ✅ **Auto-restart**: Automatically restarts Finder/Dock/SystemUIServer when needed
- ✅ **No manual `defaults` commands**: Just declare what you want

No YAML hell. No cryptic property lists. Just readable code.

If you know Ruby, you already know this. If you don't, you can still read it.

---

## Performance

### Built with Zig. Stupid Fast.

- **~6 MB** - Single static binary with embedded Ruby interpreter
- **8ms** - Cold start time
- **Zero dependencies** - No runtime required
- **Native code** - Compiled for your architecture

---

## Commands

```bash
hola apply             # Run Brewfile + mise.toml + symlinks
hola provision         # Run provision.rb (advanced)
```

---

## License

MIT

**Stop learning tools. Start coding.**
