#!/bin/sh
# run-local.sh — LOCAL CI for rut360gw (Docker on the workstation, no paid service).
#
#   sh ci/run-local.sh            all stages
#   sh ci/run-local.sh lint unit  only some stages
# Stages: fetch lint unit sources driver runtime package integration integration-rutos secrets
#   fetch       downloads and VERIFIES (sha256) the inputs: SDK, malta rootfs, runtime bundle
#   lint        shell syntax (sh -n + shellcheck at error level), Lua (luac -p), Python, web page (ci/check-webui.py: ACL, no CDN, no innerHTML)
#   unit        Lua self-test of the SMS/USSD bridge (rut360gw-sms selftest)
#   sources     vendored chan_quectel + RutOS patch -> work/
#   driver      builds chan_quectel.so in the OpenWrt 21.02.7 SDK (cached Docker volume)
#   runtime     embedded runtime: Asterisk and pjproject WITHOUT OpenSSL (rut360-sdk-runtime volume),
#               assembled and checked (dependencies, symbols) -> out/runtime/runtime.tar.gz
#   package     builds the .ipk files (rut360gw, rut360gw-runtime) TWICE: sha256 must be identical
#   integration QEMU bench: package installed, configuration generated, SIP and GSM calls (simulated modem)
#               generic OpenWrt rootfs + downloaded (fallback) runtime; integration-rutos: real
#               RutOS rootfs + embedded runtime
#   secrets     searches tracked files for sensitive patterns: the file named by
#               RUT360GW_SECRET_PATTERNS if set and readable, otherwise ci/secret-patterns.txt
#               (one extended regex per line, no comments or blank lines)
# Outputs: out/ (package, driver, reports). Exit code = number of failed stages.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
# path usable by Docker (Windows/Git Bash: D:/...; Linux: unchanged)
DREPO=$( (cd "$REPO" && pwd -W) 2>/dev/null || echo "$REPO")
export MSYS_NO_PATHCONV=1
IMG=rut360gw-ci
MIRROR=https://downloads.openwrt.org/releases
STAGES=${*:-fetch lint unit sources driver runtime package integration integration-rutos secrets}
mkdir -p "$REPO/dl/bundle" "$REPO/out/ci"
RESULTS=""; FAILS=0
step() { printf '\n===== %s =====\n' "$1"; }
ok() { RESULTS="$RESULTS\nPASS  $1"; }
ko() { RESULTS="$RESULTS\nFAIL  $1"; FAILS=$((FAILS+1)); }
drun() { docker run --rm -v "$DREPO":/repo "$@"; }
fetch_one() { # $1 sha256  $2 url  $3 destination
	if [ -f "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$1" ]; then return 0; fi
	# curl is run INSIDE the target directory: under Git Bash with MSYS_NO_PATHCONV=1, curl.exe (native
	# Windows) does not understand a /d/... path (same pitfall as "git -C")
	( cd "$(dirname "$3")" && curl -s -f -L -o "$(basename "$3").part" "$2" ) &&
		[ "$(sha256sum "$3.part" | cut -d' ' -f1)" = "$1" ] && mv "$3.part" "$3" && return 0
	rm -f "$3.part"; echo "download/verification failed: $2" >&2; return 1
}

docker image inspect $IMG >/dev/null 2>&1 || docker build -q -t $IMG "$DREPO/ci" >/dev/null || { echo "cannot build the CI image"; exit 99; }

for s in $STAGES; do case $s in
fetch)
	step "fetch: sha256-verified inputs"
	r=0
	grep -v '^#' "$REPO/ci/inputs.sha256" | while read -r sha rel; do
		[ -n "$sha" ] && { fetch_one "$sha" "$MIRROR/$rel" "$REPO/dl/$(basename "$rel")" || exit 1; }
	done || r=1
	grep -v '^#' "$REPO/package/rut360gw/files/usr/share/rut360gw/bundle.manifest" | while read -r sha rel _; do
		[ -n "$sha" ] && { fetch_one "$sha" "$MIRROR/21.02.0/packages/mips_24kc/$rel" "$REPO/dl/bundle/$(basename "$rel")" || exit 1; }
	done || r=1
	[ $r = 0 ] && ok "fetch ($(ls "$REPO/dl/bundle" | wc -l) runtime packages + SDK + rootfs)" || ko fetch
	;;
lint)
	step "lint"
	# list of scripts computed on the host: in a Git worktree, the .git file points to a Windows path
	# (D:/.../.git/worktrees/...), "git ls-files" fails in the container, the list is empty and the
	# lint used to pass without checking anything
	SH_FILES=$(cd "$REPO" && git ls-files "*.sh" | grep -v "^third_party/" | tr '\n' ' ')
	if [ -z "$SH_FILES" ]; then echo "no .sh script found (git ls-files)"; ko lint; continue; fi
	echo "$(echo $SH_FILES | wc -w) .sh scripts"
	if drun -e SH_FILES="$SH_FILES" $IMG sh -c '
		cd /repo; e=0
		for f in $SH_FILES package/rut360gw/files/etc/init.d/rut360gw $(ls package/rut360gw/files/usr/sbin/* | grep -v rut360gw-sms) package/rut360gw/CONTROL/postinst package/rut360gw/CONTROL/prerm package/rut360gw/CONTROL/postrm package/rut360gw/CONTROL-runtime/preinst package/rut360gw/CONTROL-runtime/postinst package/rut360gw/files/usr/libexec/rpcd/rut360gw; do
			sh -n "$f" || { echo "syntax: $f"; e=1; }
		done
		shellcheck -S error -s sh $(printf "%s\n" $SH_FILES | grep -v "^tests/run-qemu-test.sh$") $(ls package/rut360gw/files/usr/sbin/* | grep -v rut360gw-sms) package/rut360gw/files/usr/libexec/rpcd/rut360gw || e=1
		shellcheck -S error -s bash tests/run-qemu-test.sh || e=1
		luac5.1 -p package/rut360gw/files/usr/sbin/rut360gw-sms || e=1
		python3 -m py_compile tests/fake_eg06.py tests/fake_audio.py tests/fake_registrar.py tests/webui-relay.py tests/sip_client.py build/runtime/assemble.py build/runtime/prune.py || e=1
		python3 ci/check-webui.py || e=1
		exit $e'; then ok lint; else ko lint; fi
	;;
unit)
	step "unit: Lua self-test"
	if drun $IMG lua5.1 /repo/package/rut360gw/files/usr/sbin/rut360gw-sms selftest | tee "$REPO/out/ci/unit.txt" | tail -3 && grep -q "Result: OK" "$REPO/out/ci/unit.txt"
	then ok "unit ($(grep -c ^PASS "$REPO/out/ci/unit.txt") tests)"; else ko unit; fi
	;;
sources)
	step "sources: chan_quectel + RutOS patch"
	if drun $IMG sh /repo/build/prepare-sources.sh /repo/work/chan_quectel >/dev/null; then ok sources; else ko sources; fi
	;;
driver)
	step "driver: chan_quectel.so (OpenWrt 21.02.7 SDK, rut360-sdk volume)"
	if docker run --rm -v rut360-sdk:/sdk -v "$DREPO/dl":/dl:ro -v "$DREPO/build":/scripts:ro \
		-v "$DREPO/work/chan_quectel":/src:ro -v "$DREPO/build/pkg":/pkg:ro -v "$DREPO/out":/out -v "$DREPO/tests":/tests:ro $IMG sh -c '
		set -e
		[ -f /sdk/.extracted ] || { tar -C /sdk --strip-components=1 -xJf /dl/openwrt-sdk-21.02.7-ath79-generic_gcc-8.4.0_musl.Linux-x86_64.tar.xz; touch /sdk/.extracted; }
		chown -R builder /sdk
		[ -d /sdk/feeds/telephony ] || su builder -c "cd /sdk && ./scripts/feeds update base packages telephony >/dev/null && ./scripts/feeds install -a -p telephony >/dev/null && ./scripts/feeds install alsa-lib libsqlite3 >/dev/null"
		su builder -c "bash /scripts/build-chan.sh" | tail -1
		cd /tmp && tar -xzOf "$(ls /sdk/bin/packages/mips_24kc/base/asterisk-chan-quectel_*.ipk | head -1)" ./data.tar.gz | tar -xz
		cp usr/lib/asterisk/modules/chan_quectel.so /out/chan_quectel.so
		# TEST shims for the QEMU bench (never installed on the router)
		for s in tiocexcl ifaddrs; do
			STAGING_DIR=/sdk/staging_dir /sdk/staging_dir/toolchain-mips_24kc_gcc-8.4.0_musl/bin/mips-openwrt-linux-musl-gcc -shared -fPIC -Os -o /out/${s}_shim.so /tests/qemu-shim/${s}_shim.c
		done
		sha256sum /out/chan_quectel.so'; then ok "driver ($(sha256sum "$REPO/out/chan_quectel.so" | cut -c1-12)…)"; else ko driver; fi
	;;
runtime)
	# Asterisk and pjproject WITHOUT OpenSSL, built in a separate SDK volume (rut360-sdk-runtime: the
	# driver is still built against the official Asterisk, the one of the downloaded fallback runtime),
	# then assembled with the official bundle dependencies and the stubs. BLOCKING check: every
	# dependency and every symbol resolved, for each firmware listed in FIRMWARES (extracted rootfs).
	step "runtime: embedded runtime (Asterisk without OpenSSL, rut360-sdk-runtime volume)"
	[ -f "$REPO/out/chan_quectel.so" ] || { ko "runtime (chan_quectel.so missing: run the driver stage)"; continue; }
	RF=""; miss=""
	for fw in $(grep -v '^#' "$REPO/package/rut360gw/FIRMWARES" | awk 'NF{print $1}'); do
		v=$(echo "$fw" | sed 's/^RUT36X_R_00\.0*//')
		if [ -d "$REPO/dl/firmware/rootfs-$v" ]; then RF="$RF --rootfs /repo/dl/firmware/rootfs-$v"; else miss="$miss $fw"; fi
	done
	[ -z "$miss" ] && [ -n "$RF" ] || { ko "runtime (rootfs not extracted:$miss; see build/extract-rutos-rootfs.sh)"; continue; }
	rm -rf "$REPO/out/runtime"; mkdir -p "$REPO/out/runtime/build"
	# timestamp of the archive's files: that of the last commit touching the runtime (reproducible archive)
	EPOCH=$(cd "$REPO" && git log -1 --format=%ct -- build/runtime package/rut360gw/files/usr/share/rut360gw/templates/modules.conf 2>/dev/null)
	if docker run --rm -v rut360-sdk-runtime:/sdk -v "$DREPO/dl":/dl:ro -v "$DREPO/build/runtime":/rt:ro \
		-v "$DREPO/out/runtime/build":/out $IMG sh -c '
		set -e
		[ -f /sdk/.extracted ] || { tar -C /sdk --strip-components=1 -xJf /dl/openwrt-sdk-21.02.7-ath79-generic_gcc-8.4.0_musl.Linux-x86_64.tar.xz; touch /sdk/.extracted; }
		chown -R builder /sdk /out
		[ -d /sdk/feeds/telephony ] || su builder -c "cd /sdk && ./scripts/feeds update base packages telephony >/dev/null && ./scripts/feeds install -a -p telephony >/dev/null"
		su builder -c "bash /rt/build.sh"' &&
		drun $IMG python3 -I /repo/build/runtime/assemble.py --ipk /repo/out/runtime/build/ipk --bundle /repo/dl/bundle \
			--stubs /repo/out/runtime/build/stubs --chan /repo/out/chan_quectel.so \
			--modules /repo/package/rut360gw/files/usr/share/rut360gw/templates/modules.conf $RF \
			--out /repo/out/runtime/runtime.tar.gz --report /repo/out/runtime/runtime.txt --epoch "${EPOCH:-0}"
	then ok "runtime ($(( $(wc -c < "$REPO/out/runtime/runtime.tar.gz") / 1024 )) KiB gzip, $(sha256sum "$REPO/out/runtime/runtime.tar.gz" | cut -c1-12)…)"
	else ko "runtime (see out/runtime/runtime.txt and /sdk/build-runtime.log in the volume)"; fi
	;;
package)
	step "package: reproducible build"
	[ -f "$REPO/out/chan_quectel.so" ] || { ko "package (chan_quectel.so missing: run the driver stage)"; continue; }
	[ -f "$REPO/out/runtime/runtime.tar.gz" ] || { ko "package (out/runtime/runtime.tar.gz missing: run the runtime stage)"; continue; }
	A=$(CHAN_SO="$REPO/out/chan_quectel.so" RUNTIME_TGZ="$REPO/out/runtime/runtime.tar.gz" sh "$REPO/package/rut360gw/build-ipk.sh" "$REPO/out" | tail -1)
	B=$(CHAN_SO="$REPO/out/chan_quectel.so" RUNTIME_TGZ="$REPO/out/runtime/runtime.tar.gz" sh "$REPO/package/rut360gw/build-ipk.sh" "$REPO/out" | tail -1)
	echo "build 1: $A"; echo "build 2: $B"
	if [ -n "$A" ] && [ "$A" = "$B" ]; then ok "package reproducible (${A%"${A#????????????}"}…)"; else ko "package (sha256 differ)"; fi
	;;
integration)
	# generic OpenWrt rootfs + FALLBACK runtime (the downloaded official .ipk files)
	step "integration: QEMU bench (packages, downloaded runtime, SIP client, simulated modem)"
	ls "$REPO"/out/rut360gw_*_mips_24kc.ipk "$REPO"/out/rut360gw-runtime_*_mips_24kc.ipk >/dev/null 2>&1 || { ko "integration (packages missing)"; continue; }
	rm -f "$REPO"/out/ci/qemu-*; mkdir -p "$REPO/out/ci/qemu"
	# a single copy of each package in the mounted directory: the most recent one
	mkdir -p "$REPO/out/ci/ipk" && rm -f "$REPO"/out/ci/ipk/*
	cp "$(ls -t "$REPO"/out/rut360gw_*_mips_24kc.ipk | head -1)" "$(ls -t "$REPO"/out/rut360gw-runtime_*_mips_24kc.ipk | head -1)" \
		"$REPO/out/tiocexcl_shim.so" "$REPO/out/ifaddrs_shim.so" "$REPO/out/ci/ipk/"
	docker run --rm --privileged -e BENCH_RUNTIME=bundle -v "$DREPO":/repo:ro -v "$DREPO/dl":/dl:ro -v "$DREPO/out/ci/ipk":/ipk:ro \
		-v "$DREPO/out/ci/qemu":/res $IMG bash /repo/tests/run-qemu-test.sh > "$REPO/out/ci/integration.txt" 2>&1
	grep -E "^(package|runtime|PASS|FAIL|Result)" "$REPO/out/ci/integration.txt"
	# success only if the bench explicitly reports 0 failures
	if grep -q -E "^Result: [0-9]+ PASS / 0 FAIL$" "$REPO/out/ci/integration.txt"
	then ok "integration ($(grep -c ^PASS "$REPO/out/ci/integration.txt") checks)"; else ko "integration (see out/ci/integration.txt and out/ci/qemu/)"; fi
	;;
integration-rutos)
	# same bench, but on the REAL filesystem of each RutOS firmware extracted by
	# build/extract-rutos-rootfs.sh (that firmware's musl libc, busybox...), with the EMBEDDED runtime
	# (the service's normal path); skipped if none is extracted
	step "integration-rutos: QEMU bench on the extracted RutOS rootfs (embedded runtime)"
	ls -d "$REPO"/dl/firmware/rootfs-* >/dev/null 2>&1 || { echo "(no RutOS rootfs extracted: stage skipped)"; continue; }
	[ -f "$REPO/out/ci/ipk/tiocexcl_shim.so" ] || { ko "integration-rutos (run the integration stage first)"; continue; }
	for fs in "$REPO"/dl/firmware/rootfs-*; do
		v=${fs##*/rootfs-}
		mkdir -p "$REPO/out/ci/qemu-$v"
		docker run --rm --privileged -e ROOTFS_DIR="/fw/rootfs-$v" -v "$DREPO":/repo:ro -v "$DREPO/dl":/dl:ro \
			-v "$DREPO/dl/firmware":/fw:ro -v "$DREPO/out/ci/ipk":/ipk:ro -v "$DREPO/out/ci/qemu-$v":/res $IMG \
			bash /repo/tests/run-qemu-test.sh > "$REPO/out/ci/integration-$v.txt" 2>&1
		grep -E "^(rootfs|package|runtime|bundle|PASS|FAIL|Result)" "$REPO/out/ci/integration-$v.txt"
		if grep -q -E "^Result: [0-9]+ PASS / 0 FAIL$" "$REPO/out/ci/integration-$v.txt"
		then ok "integration RutOS $v ($(grep -c ^PASS "$REPO/out/ci/integration-$v.txt") checks)"; else ko "integration RutOS $v (see out/ci/integration-$v.txt)"; fi
		# space check of the runtime package (Installed-Size: 0 + preinst) with this firmware's opkg
		mkdir -p "$REPO/out/ci/opkg-$v"
		docker run --rm --privileged -v "$DREPO/dl/firmware/rootfs-$v":/fw:ro -v "$DREPO/out/ci/ipk":/ipk:ro \
			-v "$DREPO/out/ci/opkg-$v":/res -v "$DREPO/tests":/t:ro $IMG bash /t/opkg-runtime-test.sh > "$REPO/out/ci/opkg-$v.txt" 2>&1
		grep -E "^(PASS|FAIL|Result)" "$REPO/out/ci/opkg-$v.txt"
		if grep -q -E "^Result: [0-9]+ PASS / 0 FAIL$" "$REPO/out/ci/opkg-$v.txt"
		then ok "opkg RutOS $v: runtime upgrade ($(grep -c ^PASS "$REPO/out/ci/opkg-$v.txt") scenarios)"; else ko "opkg RutOS $v (see out/ci/opkg-$v.txt)"; fi
	done
	;;
secrets)
	step "secrets"
	# Pattern source: RUT360GW_SECRET_PATTERNS (e.g. a private list kept outside the repository) when
	# set and readable, otherwise the generic built-in list ci/secret-patterns.txt (private keys,
	# WireGuard/age keys, literal passwords in UCI/Asterisk files, cloud tokens).
	P=${RUT360GW_SECRET_PATTERNS:-}
	if [ -n "$P" ] && [ -r "$P" ] && [ -s "$P" ]; then
		P=$(cd "$(dirname "$P")" && pwd)/$(basename "$P")   # absolute: grep runs from the repository root
		SRC="RUT360GW_SECRET_PATTERNS"; ALLOW='^$'
	else
		[ -n "$P" ] && echo "RUT360GW_SECRET_PATTERNS=$P is not a readable non-empty file: using the built-in list"
		P="$REPO/ci/secret-patterns.txt"; SRC="built-in list"
		# built-in list only: obvious test fixtures and @PLACEHOLDER@ templates are not secrets
		ALLOW="'(test|example|dummy|changeme)[^']*'"
	fi
	echo "patterns: $P ($SRC)"
	[ -s "$P" ] || { ko "secrets (pattern file $P missing)"; continue; }
	hits=$(cd "$REPO" && git ls-files -z | xargs -0 grep -I -n -E -f "$P" 2>/dev/null | grep -v '^third_party/' | grep -v -E "$ALLOW" | cut -d: -f1 | sort -u)
	if [ -z "$hits" ]; then ok "secrets ($SRC)"; else echo "$hits"; ko "secrets ($(echo "$hits" | wc -l) file(s))"; fi
	;;
*) echo "unknown stage: $s"; ko "$s" ;;
esac; done

printf '\n===== Summary =====%b\n' "$RESULTS"
exit $FAILS
