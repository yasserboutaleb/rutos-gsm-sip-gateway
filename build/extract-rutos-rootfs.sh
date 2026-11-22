#!/bin/sh
# extract-rutos-rootfs.sh — downloads an official RutOS RUT36X image, checks its MD5 (published on
# wiki.teltonika-networks.com, "RUT360 Firmware Downloads" page) and extracts its squashfs
# filesystem into dl/firmware/rootfs-<version>/, for the QEMU bench ("integration-rutos" stage).
# Nothing from the image is executed: it is only read. Usage:
#   sh build/extract-rutos-rootfs.sh RUT36X_R_00.07.14.5 25b55947f35174fb67888ff7f3ed4f02
set -eu
VER=${1:?RutOS version, e.g. RUT36X_R_00.07.14.5}
MD5=${2:?MD5 published by Teltonika}
echo "$VER" | grep -q -E '^RUT36X_R_00\.07\.[0-9]+\.[0-9]+$' || { echo "invalid version" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
D=$HERE/dl/firmware; mkdir -p "$D"
SHORT=$(echo "$VER" | sed 's/^RUT36X_R_00\.0*//')          # 7.14.5
BIN=$D/${VER}_WEBUI.bin
[ -f "$BIN" ] || curl -fsS -o "$BIN" "https://firmware.teltonika-networks.com/$SHORT/RUT36X/${VER}_WEBUI.bin"
echo "$MD5  $BIN" | md5sum -c - >/dev/null || { echo "MD5 mismatch: image rejected" >&2; rm -f "$BIN"; exit 1; }
DREPO=$(cd "$HERE" && pwd -W 2>/dev/null || pwd)
MSYS_NO_PATHCONV=1 docker run --rm -v "$DREPO/dl/firmware:/fw" rut360gw-ci sh -c "
	apt-get -qq update >/dev/null 2>&1; apt-get -qq install -y squashfs-tools >/dev/null 2>&1
	python3 -c \"d=open('/fw/${VER}_WEBUI.bin','rb').read(); open('/tmp/root.sqfs','wb').write(d[d.find(b'hsqs'):])\"
	rm -rf /fw/rootfs-$SHORT && unsquashfs -q -no-xattrs -d /fw/rootfs-$SHORT /tmp/root.sqfs >/dev/null
	cat /fw/rootfs-$SHORT/etc/version"
