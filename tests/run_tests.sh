#!/bin/sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XDG_DIR="$REPO_DIR/tests/xdg"
FIXTURE_DIR="$REPO_DIR/tests/fixtures"

rm -rf "$XDG_DIR"
mkdir -p "$XDG_DIR/data" "$XDG_DIR/config" "$XDG_DIR/state"

# Set up deterministic fixture repository
sh "$REPO_DIR/tests/setup_fixtures.sh" "$FIXTURE_DIR" > /dev/null

run_spec() {
  local spec="$1"
  echo "=== $spec ==="
  XDG_DATA_HOME="$XDG_DIR/data" \
  XDG_CONFIG_HOME="$XDG_DIR/config" \
  XDG_STATE_HOME="$XDG_DIR/state" \
  ICEBOX_FIXTURE_DIR="$FIXTURE_DIR" \
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
run_spec "tests/git_spec.lua"       || FAILED=1
run_spec "tests/lazy_spec.lua"      || FAILED=1

rm -rf "$XDG_DIR"
rm -rf "$FIXTURE_DIR"

if [ "$FAILED" -eq 1 ]; then
  printf "\nSome tests failed.\n"
  exit 1
else
  printf "\nAll tests passed.\n"
fi
