#!/bin/sh
# Installs the repository's Git hooks (run once per working copy).
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
cp "$REPO/ci/hooks/pre-commit" "$REPO/.git/hooks/pre-commit"
chmod 755 "$REPO/.git/hooks/pre-commit"
echo "pre-commit hook installed"
