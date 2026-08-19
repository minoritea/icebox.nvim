#!/bin/sh
# Create a deterministic bare git repository for integration tests.
# Outputs the path to the bare repo on stdout.
# Usage: FIXTURE_DIR=$(sh tests/setup_fixtures.sh)
set -e

FIXTURE_DIR="${1:-$(dirname "$0")/fixtures}"
BARE_DIR="$FIXTURE_DIR/repo.git"
WORK_DIR="$FIXTURE_DIR/_work"

rm -rf "$FIXTURE_DIR"
mkdir -p "$WORK_DIR"

cd "$WORK_DIR"
git init -q -b main
git config user.email "test@icebox"
git config user.name "Test"
# Disable signing so commit hashes stay deterministic across developer
# machines (a global commit.gpgsign / gpg.format=ssh would otherwise
# embed a signature and change every hash the specs hard-code).
git config commit.gpgsign false
git config tag.gpgsign false

# Commit 1 (older)
echo "first" > file.txt
git add file.txt
GIT_AUTHOR_DATE="2024-01-01T00:00:00+00:00" \
GIT_COMMITTER_DATE="2024-01-01T00:00:00+00:00" \
git commit -q -m "commit 1"

# Tag v1.0.0 (lightweight) on commit 1
git tag v1.0.0

# Commit 2 (newer, on main)
echo "second" >> file.txt
git add file.txt
GIT_AUTHOR_DATE="2024-01-02T00:00:00+00:00" \
GIT_COMMITTER_DATE="2024-01-02T00:00:00+00:00" \
git commit -q -m "commit 2"

# Tag v1.1.0 (lightweight) on commit 2
git tag v1.1.0

# Tag v2.0.0 (annotated) on commit 2
GIT_COMMITTER_DATE="2024-01-02T00:00:00+00:00" \
git tag -a v2.0.0 -m "release 2.0.0"

# Bare clone
git clone -q --bare "$WORK_DIR" "$BARE_DIR"

rm -rf "$WORK_DIR"

echo "$BARE_DIR"
