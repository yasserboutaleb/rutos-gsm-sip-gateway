#!/bin/bash
# Builds Asterisk 18 (for its headers), then the patched chan_quectel, in the 21.02.7 SDK.
set -e
cd /sdk
# The 21.02 SDK ships CMake 3.19.8; chan_quectel needs >= 3.20 -> use Debian bookworm's CMake 3.25
[ -x /usr/bin/cmake ] && ln -sf /usr/bin/cmake /sdk/staging_dir/host/bin/cmake
rm -rf package/asterisk-chan-quectel && cp -r /pkg/asterisk-chan-quectel-rut360 package/asterisk-chan-quectel
if [ ! -f .config.done ]; then
  cat > .config <<CFG
# CONFIG_ALL is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_SIGNED_PACKAGES is not set
CONFIG_PACKAGE_asterisk=m
CONFIG_PACKAGE_asterisk-chan-quectel=m
CFG
  make defconfig >/dev/null && touch .config.done
fi
make -j"$(nproc)" package/asterisk-chan-quectel/compile V=s > /sdk/build-chan.log 2>&1 || { tail -60 /sdk/build-chan.log; exit 1; }
find bin/packages -name 'asterisk-chan-quectel*.ipk' -exec ls -la {} \;
