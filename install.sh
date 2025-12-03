#!/bin/sh
# Hola installer - Download to current directory
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ratazzi/hola/refs/heads/master/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/ratazzi/hola/refs/heads/master/install.sh | sh -s -- nightly
#
set -e

# Version: supports both environment variable and positional argument
# Environment variable takes precedence
VERSION="${VERSION:-${1:-latest}}"

# Detect platform
OS=$(uname -s)
ARCH=$(uname -m)

# Map to binary naming convention
case "$OS" in
  Darwin) OS="macos" ;;
  Linux) OS="linux" ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="aarch64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Download
BINARY="hola-${OS}-${ARCH}"

# Construct URL based on version
case "$VERSION" in
  latest)
    URL="https://github.com/ratazzi/hola/releases/latest/download/${BINARY}"
    ;;
  nightly)
    URL="https://github.com/ratazzi/hola/releases/download/nightly/${BINARY}"
    ;;
  *)
    # Assume it's a specific tag/version
    URL="https://github.com/ratazzi/hola/releases/download/${VERSION}/${BINARY}"
    ;;
esac

echo "Downloading ${BINARY} (${VERSION})..."
echo "URL: $URL"
curl -fsSL -o hola "$URL"
chmod +x hola

# Remove macOS quarantine
[ "$OS" = "macos" ] && xattr -d com.apple.quarantine hola 2>/dev/null || true

echo "Done! Binary saved as: ./hola"
