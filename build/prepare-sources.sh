#!/bin/sh
# prepare-sources.sh — produces the patched chan_quectel sources for the RUT360.
# Copies third_party/chan_quectel (pinned, unmodified revision), normalises line endings
# to LF (Git may check out CRLF on Windows), then applies
# patches/0001-chan_quectel-rutos-coexistence.patch.
# Usage: sh build/prepare-sources.sh [output]   (default: work/chan_quectel, ignored by Git)
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/work/chan_quectel}
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -r "$REPO/third_party/chan_quectel" "$OUT"
find "$OUT" -type f \( -name '*.c' -o -name '*.h' -o -name '*.txt' -o -name '*.cmake' \
	-o -name '*.in' -o -name '*.sh' -o -name '*.conf' -o -name '*.json' \) \
	-exec sed -i 's/\r$//' {} +
# the patch is relative to the repository root (a/third_party/chan_quectel/...)
( cd "$OUT" && patch -s -p3 < "$REPO/patches/0001-chan_quectel-rutos-coexistence.patch" )
echo "$OUT"
