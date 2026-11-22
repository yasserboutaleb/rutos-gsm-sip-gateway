# rut360gw local CI image: checking, build (OpenWrt SDK) and emulation tools.
# Built once by ci/run-local.sh (docker build -t rut360gw-ci ci/).
FROM debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      build-essential ccache file gawk gettext git libncurses-dev libssl-dev python3 python3-distutils \
      rsync unzip wget xz-utils zstd cmake ca-certificates curl \
      shellcheck lua5.1 qemu-user-static socat procps patch \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m builder
