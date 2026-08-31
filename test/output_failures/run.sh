#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)

if [ -n "${HOLA_BIN:-}" ]; then
  HOLA=$HOLA_BIN
else
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) HOLA="$REPO_ROOT/zig-out/bin/hola-macos-aarch64" ;;
    Linux-aarch64|Linux-arm64) HOLA="$REPO_ROOT/zig-out/bin/hola-linux-aarch64" ;;
    Linux-x86_64) HOLA="$REPO_ROOT/zig-out/bin/hola-linux-x86_64" ;;
    *)
      echo "Unsupported platform; set HOLA_BIN to the hola executable." >&2
      exit 2
      ;;
  esac
fi

if [ ! -x "$HOLA" ]; then
  echo "Hola executable not found: $HOLA" >&2
  echo "Run 'zig build' first, or set HOLA_BIN explicitly." >&2
  exit 2
fi

cd "$SCRIPT_DIR"

unexpected=0

reset_fixture() {
  rm -rf /tmp/hola-output-failures
}

expect_failure() {
  label=$1
  shift
  reset_fixture
  printf '\n%s\n' "$label"
  "$@"
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "ERROR: expected a non-zero exit status" >&2
    unexpected=$((unexpected + 1))
  fi
}

expect_success() {
  label=$1
  shift
  reset_fixture
  printf '\n%s\n' "$label"
  "$@"
  status=$?
  if [ "$status" -ne 0 ]; then
    printf 'ERROR: expected exit status 0, got %s\n' "$status" >&2
    unexpected=$((unexpected + 1))
  fi
}

run_mode() {
  mode=$1
  printf '\nOutput mode: %s\n' "$mode"

  expect_success "run: handled diagnostics" \
    "$HOLA" run --output "$mode" diagnostics

  expect_failure "run: fatal diagnostic" \
    "$HOLA" run --output "$mode" abort

  expect_success "provision: handled diagnostics" \
    "$HOLA" provision --output "$mode" provision.rb

  expect_failure "provision: fatal diagnostic" \
    "$HOLA" provision --output "$mode" provision_abort.rb
}

case "${1:-both}" in
  normal|compact)
    run_mode "$1"
    ;;
  both)
    run_mode normal
    run_mode compact
    ;;
  *)
    echo "Usage: $0 [normal|compact|both]" >&2
    exit 2
    ;;
esac

reset_fixture

if [ "$unexpected" -ne 0 ]; then
  printf '\n%s scenario(s) returned an unexpected exit status.\n' "$unexpected" >&2
  exit 1
fi

printf '\nAll scenarios returned the expected exit status.\n'
