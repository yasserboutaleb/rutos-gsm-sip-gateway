#!/bin/sh
# build-ipk.sh — builds, reproducibly:
#   - rut360gw_<version>_mips_24kc.ipk: scripts, web page, chan_quectel driver (updated often);
#   - rut360gw-runtime_<version>_mips_24kc.ipk if RUNTIME_TGZ is given: the embedded Asterisk
#     runtime (out/runtime/runtime.tar.gz from the CI runtime stage), rarely updated;
#   - one WebUI archive per firmware listed in FIRMWARES, containing both.
# Usage: CHAN_SO=<chan_quectel.so mips_24kc> [RUNTIME_TGZ=<runtime.tar.gz>] [VERSION=x.y.z-n] sh build-ipk.sh [output_dir]
# OpenWrt 21.02 ipk format: tar.gz { debian-binary, control.tar.gz, data.tar.gz }.
#
# Why two packages: opkg (and the WebUI) reject a package whose Installed-Size exceeds the free space,
# WITHOUT deducting the already installed version. With the runtime (~1.8 MB) inside rut360gw, every
# upgrade would be rejected once the package is installed (~1.5 MB free). Kept separate, the runtime is
# only reinstalled when its version changes (build/runtime/VERSION); otherwise the WebUI skips it ("up to
# date"). Its own upgrade goes through thanks to "Installed-Size: 0" and the space check in its preinst.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUTDIR=${1:-$HERE/../../out}
: "${CHAN_SO:?CHAN_SO required (chan_quectel.so built for mips_24kc)}"
# "cd" rather than "git -C": under Git Bash with MSYS_NO_PATHCONV=1 (CI), git.exe does not understand /d/...
GITREV=$(cd "$HERE" && git log -1 --format=%h 2>/dev/null || echo nogit)
COUNT=$(cd "$HERE" && git rev-list --count HEAD 2>/dev/null || echo 0)
# Increasing version for opkg: r<commit count>.g<hash>. A hash alone is not ordered
# (0.1.0-4332d2f < 0.1.0-c18ff8e for opkg: the upgrade was rejected as a "downgrade").
# The "r" prefix sorts these versions above the older "0.1.0-<hash>" versions.
VERSION=${VERSION:-0.2.2-r$COUNT.g$GITREV}
# runtime version: bump it on EVERY change of its content (otherwise the WebUI considers it up to date)
RTVER=$(cat "$HERE/../../build/runtime/VERSION")
EPOCH=${SOURCE_DATE_EPOCH:-$(cd "$HERE" && git log -1 --format=%ct 2>/dev/null || echo 0)}
[ "$GITREV" != nogit ] || [ -n "${ALLOW_NOGIT:-}" ] || { echo "build-ipk: git revision not found (ALLOW_NOGIT=1 to force)" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
T="tar --sort=name --mtime=@$EPOCH --owner=0 --group=0 --numeric-owner"
# Runtime package: timestamps of the last commit touching ITS content (not the whole repository), so that it
# stays byte-identical from one commit to the next as long as the runtime does not change (traceability).
RTEPOCH=${SOURCE_DATE_EPOCH:-$(cd "$HERE/../.." && git log -1 --format=%ct -- build/runtime package/rut360gw/CONTROL-runtime package/rut360gw/files/usr/share/rut360gw/templates/modules.conf 2>/dev/null)}
RT_T="tar --sort=name --mtime=@${RTEPOCH:-$EPOCH} --owner=0 --group=0 --numeric-owner"
mkdir -p "$OUTDIR"

# assemble <dir containing data.tar.gz and control/> <.ipk file> [tar command, $T by default]
assemble() {
	local tar="${3:-$T}"
	( cd "$1/control" && $tar -cf - . | gzip -9n > "$1/control.tar.gz" )
	echo "2.0" > "$1/debian-binary"
	( cd "$1" && $tar -cf - ./debian-binary ./control.tar.gz ./data.tar.gz | gzip -9n > "$2" )
}

# ---- rut360gw-runtime (if RUNTIME_TGZ)
RTIPK=
if [ -n "${RUNTIME_TGZ:-}" ]; then
	R=$W/rt; mkdir -p "$R/data/usr/share/rut360gw" "$R/control"
	cp "$RUNTIME_TGZ" "$R/data/usr/share/rut360gw/runtime.tar.gz"
	( cd "$R/data/usr/share/rut360gw" && sha256sum runtime.tar.gz > runtime.tar.gz.sha256 )
	sed "s/@VERSION@/$RTVER/" "$HERE/CONTROL-runtime/control" > "$R/control/control"
	# "Installed-Size: 0": otherwise opkg and the WebUI, which do not deduct the installed version,
	# would reject any new runtime version. The field must stay present (the WebUI adds it up).
	# The real space check is done by preinst, using the archive size.
	echo "Installed-Size: 0" >> "$R/control/control"
	sed "s/@NEW_KB@/$(( ($(wc -c < "$RUNTIME_TGZ") + 1023) / 1024 ))/" "$HERE/CONTROL-runtime/preinst" > "$R/control/preinst"
	cp "$HERE/CONTROL-runtime/postinst" "$R/control/"
	chmod 755 "$R/control/preinst" "$R/control/postinst"
	( cd "$R/data" && $RT_T --mode='u=rw,go=r,a+X' -cf - . | gzip -9n > "$R/data.tar.gz" )
	RTIPK="$OUTDIR/rut360gw-runtime_${RTVER}_mips_24kc.ipk"
	assemble "$R" "$RTIPK" "$RT_T"
	echo "$RTIPK"
fi

# ---- rut360gw
mkdir -p "$W/data" "$W/control"
cp -r "$HERE/files/." "$W/data/"
mkdir -p "$W/data/usr/share/rut360gw/modules"
cp "$CHAN_SO" "$W/data/usr/share/rut360gw/modules/chan_quectel.so"
# checksums of what is shipped (traceability)
( cd "$W/data" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum ) > "$W/data/usr/share/rut360gw/SHA256SUMS"
SIZE=$(du -sk "$W/data" | cut -f1)
sed "s/@VERSION@/$VERSION/" "$HERE/CONTROL/control" > "$W/control/control"
# embedded runtime provided: versioned dependency (otherwise: downloaded runtime only)
[ -z "$RTIPK" ] || sed -i "s/^Depends: .*/&, rut360gw-runtime (>= $RTVER)/" "$W/control/control"
echo "Installed-Size: $((SIZE*1024))" >> "$W/control/control"
cp "$HERE/CONTROL/conffiles" "$HERE/CONTROL/postinst" "$HERE/CONTROL/prerm" "$HERE/CONTROL/postrm" "$W/control/"
chmod 755 "$W/control/postinst" "$W/control/prerm" "$W/control/postrm"
# Modes set INSIDE the archive (Windows filesystem permissions are not reliable):
# executables 755, configuration (secrets) 600, everything else 644 / directories 755.
EXEC="./etc/init.d/rut360gw ./usr/libexec/rpcd/rut360gw ./usr/share/rut360gw/modules/chan_quectel.so $(cd "$W/data" && ls ./usr/sbin/* | tr '\n' ' ')"
( cd "$W/data"
  $T --mode='u=rw,go=r,a+X' --exclude='./usr/sbin/*' --exclude='./etc/init.d/rut360gw' --exclude='./usr/libexec/rpcd/rut360gw' \
     --exclude='./usr/share/rut360gw/modules/chan_quectel.so' --exclude='./etc/config/rut360gw' -cf "$W/data.tar" .
  $T --mode=755 -rf "$W/data.tar" $EXEC
  $T --mode=600 -rf "$W/data.tar" ./etc/config/rut360gw
  gzip -9n < "$W/data.tar" > "$W/data.tar.gz" )
IPK="$OUTDIR/rut360gw_${VERSION}_mips_24kc.ipk"
assemble "$W" "$IPK"
echo "$IPK"

# Archive for the RutOS WebUI (Services > Package Manager > Upload). The Package Manager does NOT
# accept a bare .ipk: it unpacks the upload (tar -xz), reads a "main" file (Package, Version,
# Router, Firmware; tlt_name, pkg_reboot, pkg_network_restart optional), requires
# <Package>_*.ipk next to it, then runs "opkg-call --offline-install <dir>", which checks
# Router (= platform from /etc/board.json), Firmware (= /etc/version, exact match),
# Installed-Size, the version (rejected if not newer) and finally runs "opkg install".
# Format observed on RutOS 7.04.5 (/sbin/opkg-call, /usr/lib/lua/api/services/packages.lua), no longer supported.
# RutOS 7.14.5 (packages.lua, vuci/opkg_pkg.lua) additionally requires in "main":
#   ipk_file: <file.ipk>:<sha256>   (rejected with "Invalid file" without it)
# where sha256 = checksum of control.tar.gz followed by data.tar.gz; /bin/ipk-sig.sh <ipk> <sha256> only
# compares it for a Teltonika-signed package (control+data.sig), otherwise "not verified" (warning).
#   ipk_deps: <file.ipk>:<sha256> ...   (same format, space-separated): installed BEFORE
# ipk_file, in the same opkg command; a package that is already up to date is skipped.
# The archive must contain only main, an optional main.sig and the listed .ipk files (ipk_file, ipk_deps).
# Since the Firmware check is a strict equality, one
# archive is produced PER firmware listed in FIRMWARES.
ROUTER=$(sed -n 's/^Router: //p' "$W/control/control")
CDSUM=$(cat "$W/control.tar.gz" "$W/data.tar.gz" | sha256sum | cut -d' ' -f1)
SUMS="$(sha256sum "$IPK" | cut -d' ' -f1)"
DEPS=""; FILES="main $(basename "$IPK")"
if [ -n "$RTIPK" ]; then
	DEPS="ipk_deps: $(basename "$RTIPK"):$(cat "$W/rt/control.tar.gz" "$W/rt/data.tar.gz" | sha256sum | cut -d' ' -f1)\n"
	FILES="$FILES $(basename "$RTIPK")"
	SUMS="$SUMS $(sha256sum "$RTIPK" | cut -d' ' -f1)"
fi
for FW in $(grep -v '^#' "$HERE/FIRMWARES" | awk 'NF{print $1}'); do
	echo "$FW" | grep -q -E '^RUT36X_R_00\.07\.[0-9]+\.[0-9]+$' || { echo "FIRMWARES: invalid version $FW" >&2; exit 1; }
	rm -rf "$W/bundle"; mkdir "$W/bundle"
	printf "Package: rut360gw\nVersion: %s\nRouter: %s\nFirmware: %s\ntlt_name: RUT360 GSM Gateway (rut360gw)\npkg_reboot: 0\npkg_network_restart: 0\n${DEPS}ipk_file: %s:%s\n" \
		"$VERSION" "$ROUTER" "$FW" "$(basename "$IPK")" "$CDSUM" > "$W/bundle/main"
	cp "$IPK" "$W/bundle/"
	[ -z "$RTIPK" ] || cp "$RTIPK" "$W/bundle/"
	BUNDLE="$OUTDIR/rut360gw_${VERSION}_${FW}.tar.gz"
	# shellcheck disable=SC2086
	( cd "$W/bundle" && $T --mode='u=rw,go=r' -cf - $FILES | gzip -9n > "$BUNDLE" )
	echo "$BUNDLE"
	SUMS="$SUMS $(sha256sum "$BUNDLE" | cut -d' ' -f1)"
done
# last line = checksums (.ipk files, then WebUI archives): compared by the CI "package" stage
echo "$SUMS"
