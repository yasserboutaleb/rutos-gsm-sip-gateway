#!/bin/bash
# Prepares the OpenWrt 21.02.7 ath79 SDK in /sdk (Docker volume) with the packages+telephony feeds.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential ccache file gawk gettext git libncurses-dev libssl-dev python3 python3-distutils rsync unzip wget xz-utils zstd cmake time >/dev/null
id builder >/dev/null 2>&1 || useradd -m builder
if [ ! -f /sdk/.extracted ]; then
  tar -C /sdk --strip-components=1 -xJf /dl/openwrt-sdk-21.02.7-ath79-generic_gcc-8.4.0_musl.Linux-x86_64.tar.xz
  touch /sdk/.extracted
fi
chown -R builder /sdk
su builder -c 'cd /sdk && ./scripts/feeds update base packages telephony >/tmp/feeds.log 2>&1 && ./scripts/feeds install -a -p telephony >/dev/null && ./scripts/feeds install alsa-lib libsqlite3 >/dev/null && echo FEEDS_OK'
