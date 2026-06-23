#!/bin/sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XDG_DIR="$REPO_DIR/tests/xdg"

rm -rf "$XDG_DIR"
mkdir -p "$XDG_DIR/data" "$XDG_DIR/config" "$XDG_DIR/state"

NVIM_CMD="nvim --headless --noplugin -u NONE -c 'set rtp+=$REPO_DIR'"

run_spec() {
  local spec="$1"
  echo "=== $spec ==="
  XDG_DATA_HOME="$XDG_DIR/data" \
  XDG_CONFIG_HOME="$XDG_DIR/config" \
  XDG_STATE_HOME="$XDG_DIR/state" \
  nvim --headless --noplugin -u NONE \
    -c "set rtp+=$REPO_DIR" \
    -c "lua package.path = '$REPO_DIR/tests/?.lua;' .. package.path" \
    -l "$REPO_DIR/$spec"
}

FAILED=0

run_spec "tests/validate_spec.lua"  || FAILED=1
run_spec "tests/semver_spec.lua"    || FAILED=1
run_spec "tests/store_spec.lua"     || FAILED=1
run_spec "tests/resolver_spec.lua"  || FAILED=1

rm -rf "$XDG_DIR"

if [ "$FAILED" -eq 1 ]; then
  echo "\nSome tests failed."
  exit 1
else
  echo "\nAll tests passed."
fi
