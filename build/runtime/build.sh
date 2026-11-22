#!/bin/bash
# build.sh — builds the reduced runtime (Asterisk 18.15.1 and pjproject 2.12.1 WITHOUT OpenSSL) and the
# stub libraries, in the OpenWrt 21.02.7 SDK of the rut360-sdk-runtime Docker volume.
#
# Run by ci/run-local.sh (runtime stage), as user builder, with these mounts:
#   /sdk (rut360-sdk-runtime volume, SDK extracted and feeds installed), /rt (build/runtime, read-only),
#   /out (output: out/runtime/build, emptied by the caller).
# Kept separate from the rut360-sdk volume, where the chan_quectel driver is still built against the
# official Asterisk (the one used by the downloaded fallback runtime).
# Sources: those of the OpenWrt recipes (asterisk-18.15.1, pjproject-2.12.1, libsrtp...), downloaded
# by the SDK and verified against each recipe's PKG_HASH.
set -e
cd /sdk

# 1. Recipes: the feed's original recipe (.rut360gw-orig copy made on the first run) + patch.
#    The file is rewritten only when its content changes: otherwise OpenWrt would rebuild everything
#    on every run (a recipe's hash also depends on its files' timestamps).
for p in net/asterisk:asterisk libs/pjproject:pjproject; do
	d=feeds/telephony/${p%%:*}; patchf=/rt/patches/${p#*:}-Makefile.patch
	[ -f "$d/Makefile.rut360gw-orig" ] || cp -p "$d/Makefile" "$d/Makefile.rut360gw-orig"
	t=$(mktemp -d); cp "$d/Makefile.rut360gw-orig" "$t/Makefile"
	patch -s -d "$t" -p1 < "$patchf"
	cmp -s "$t/Makefile" "$d/Makefile" || { cp "$t/Makefile" "$d/Makefile"; echo "recipe updated: $d"; }
	rm -rf "$t"
done

# 2. Packages to build: the core and the modules listed in modules.conf (chan_quectel is built separately)
CFG='# CONFIG_ALL is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_SIGNED_PACKAGES is not set
CONFIG_PACKAGE_asterisk=m
CONFIG_PACKAGE_asterisk-pjsip=m
CONFIG_PACKAGE_asterisk-res-rtp-asterisk=m
CONFIG_PACKAGE_asterisk-res-sorcery=m
CONFIG_PACKAGE_asterisk-res-pjproject=m
CONFIG_PACKAGE_asterisk-bridge-simple=m
CONFIG_PACKAGE_asterisk-codec-alaw=m
CONFIG_PACKAGE_asterisk-codec-ulaw=m
CONFIG_PACKAGE_asterisk-format-pcm=m
CONFIG_PACKAGE_asterisk-func-db=m
CONFIG_PACKAGE_asterisk-app-record=m
CONFIG_PACKAGE_asterisk-res-clioriginate=m
CONFIG_PACKAGE_asterisk-app-system=m
CONFIG_PACKAGE_asterisk-func-base64=m
CONFIG_PACKAGE_asterisk-app-playtones=m'
if [ "$(cat .config.rut360gw 2>/dev/null)" != "$CFG" ]; then
	printf '%s\n' "$CFG" > .config
	make defconfig >/dev/null
	printf '%s\n' "$CFG" > .config.rut360gw
fi

# 3. Build (dependencies included: libsrtp2, jansson, libedit, libxml2...)
make -j"$(nproc)" package/pjproject/compile package/asterisk/compile V=s > /sdk/build-runtime.log 2>&1 ||
	{ tail -60 /sdk/build-runtime.log; exit 1; }

# 4. Built packages (exactly one version of each)
mkdir -p /out/ipk
for f in bin/packages/mips_24kc/telephony/asterisk*.ipk bin/packages/mips_24kc/telephony/libpj*.ipk; do
	case "${f##*/}" in asterisk-chan-quectel*) continue ;; esac
	cp "$f" /out/ipk/
done
n=$(ls /out/ipk | sed 's/_.*//' | sort | uniq -d)
[ -z "$n" ] || { echo "several versions of: $n (clean bin/packages in the volume)"; exit 1; }

# 5. Stub libraries: only the imported functions, never called in this configuration.
#    --hash-style=sysv is mandatory: with only the gnu hash table, asterisk crashes on musl/MIPS.
export STAGING_DIR=/sdk/staging_dir
CC=/sdk/staging_dir/toolchain-mips_24kc_gcc-8.4.0_musl/bin/mips-openwrt-linux-musl-gcc
F="-Os -fPIC -shared -msoft-float -Wall -Wextra -s -Wl,--gc-sections -Wl,-z,norelro -Wl,--hash-style=sysv -Wl,--build-id=none"
mkdir -p /out/stubs
$CC $F -Wl,-soname,libxml2.so.2 -o /out/stubs/libxml2.so.2 /rt/stubs/xml2.c
$CC $F -Wl,-soname,libasound.so.2 -o /out/stubs/libasound.so.2 /rt/stubs/asound.c
$CC $F -Wl,-soname,libncursesw.so.6 -o /out/stubs/libncursesw.so.6 /rt/stubs/termcap.c
ls /out/ipk | wc -l | sed 's/$/ packages built/'
