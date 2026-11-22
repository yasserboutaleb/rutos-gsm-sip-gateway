#!/bin/sh
# make-patch.sh — regenerates patches/0001-chan_quectel-rutos-coexistence.patch from the modified
# sources in work/chan_quectel (created by build/prepare-sources.sh, then edited).
# The patch stays relative to the repository root (a/third_party/chan_quectel/...).
# Usage: sh build/make-patch.sh [modified_dir]   (default: work/chan_quectel)
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:-$REPO/work/chan_quectel}
PATCH=$REPO/patches/0001-chan_quectel-rutos-coexistence.patch
[ -d "$SRC" ] || { echo "modified sources not found: $SRC (run build/prepare-sources.sh)" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/a/third_party" "$T/b/third_party"
cp -r "$REPO/third_party/chan_quectel" "$T/a/third_party/chan_quectel"
find "$T/a" -type f \( -name '*.c' -o -name '*.h' -o -name '*.txt' -o -name '*.cmake' \
	-o -name '*.in' -o -name '*.sh' -o -name '*.conf' -o -name '*.json' \) -exec sed -i 's/\r$//' {} +
cp -r "$SRC" "$T/b/third_party/chan_quectel"
# "git diff" format without timestamps, as in the committed patch; git diff --no-index
# returns 1 when there are differences: that is the expected case
( cd "$T" && git -c core.autocrlf=false diff --no-index --no-prefix a b > "$T/new.patch" ) || [ $? -eq 1 ]
[ -s "$T/new.patch" ] || { echo "no difference from upstream: patch left unchanged" >&2; exit 1; }
cp "$T/new.patch" "$PATCH"
echo "$PATCH ($(grep -c '^+++ ' "$PATCH") files, +$(grep -c '^+[^+]' "$PATCH") / -$(grep -c '^-[^-]' "$PATCH") lines)"
