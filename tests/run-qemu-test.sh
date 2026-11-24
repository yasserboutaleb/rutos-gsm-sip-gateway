#!/bin/bash
# run-qemu-test.sh — offline integration bench for the rut360gw PACKAGE (started by ci/run-local.sh).
#
# Runs, under qemu-mips, in the OpenWrt 21.02.7 malta-be rootfs (same arch mips_24kc / musl) or
# in the REAL rootfs of a RutOS firmware (ROOTFS_DIR):
#   - the rut360gw and rut360gw-runtime packages (installed files + rut360gw-config, which generates
#     the configuration from a test /etc/config/rut360gw);
#   - the Asterisk 18 runtime, selected by BENCH_RUNTIME:
#       embedded : the one shipped in the rut360gw-runtime package, prepared by
#                  "rut360gw-runtime embedded" (default when the package is provided);
#       bundle   : the official .ipk files of bundle.manifest (the fallback download);
# against a simulated EG06 modem (tests/fake_eg06.py) which, like the secondary AT port of the
# RUT360, emits NO URC at all, and a SIP client (tests/sip_client.py) on the loopback.
#
# Container: debian:bookworm --privileged. Mounts: /repo (repository, read-only),
# /dl (verified inputs: malta rootfs, bundle, test dependencies), /ipk (packages and test
# shims), /res (results).
# PJSIP under qemu-user: musl's getifaddrs() loops there (netlink translated by qemu); the TEST
# shim ifaddrs_shim.so (LD_PRELOAD, never installed on the router) works around it.
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq qemu-user-static socat python3 procps >/dev/null 2>&1
# binfmt_misc: lets the rootfs' MIPS sh start other MIPS binaries (uci, grep...).
# Flag F = qemu loaded at registration time, hence usable inside the chroot. Idempotent; stays
# active in the Docker VM until it restarts (Docker Desktop only registers mips64).
# Official qemu mask: accepts EI_ABIVERSION=1 (OpenWrt MIPS binaries) and ET_EXEC/ET_DYN (PIE).
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
[ -e /proc/sys/fs/binfmt_misc/qemu-mips ] && echo -1 > /proc/sys/fs/binfmt_misc/qemu-mips
echo ':qemu-mips:M::\x7fELF\x01\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x08:\xff\xff\xff\xff\xff\xff\xff\x00\xfe\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/usr/bin/qemu-mips-static:F' > /proc/sys/fs/binfmt_misc/register
[ -e /proc/sys/fs/binfmt_misc/qemu-mips ] || { echo "binfmt qemu-mips unavailable"; exit 1; }
R=/r; rm -rf $R; mkdir -p $R /res; : > /res/at.log
if [ -n "${ROOTFS_DIR:-}" ]; then
	# REAL file system of a RutOS firmware (e.g. 7.14.5: musl 1.2.4, OpenSSL 3), extracted by
	# build/extract-rutos-rootfs.sh: checks the runtime against that firmware's libc and libraries
	cp -a "$ROOTFS_DIR/." $R/
	echo "rootfs : $(cat $R/etc/version 2>/dev/null) ($(ls $R/lib/libc.so* 2>/dev/null | head -1))"
else
	tar -xzf /dl/openwrt-21.02.7-malta-be-default-rootfs.tar.gz -C $R
	# libraries provided by RutOS but missing from the malta rootfs (generic bench)
	for f in /dl/libsqlite3-0_*.ipk /dl/libopenssl1.1_*.ipk /dl/zlib_*.ipk; do tar -xzOf "$f" ./data.tar.gz | tar -xz -C $R; done
fi
# rut360gw package, installed the way the firmware's opkg would: RutOS 7.14 ("dest root /usr/local",
# read-only root) puts the package under /usr/local, except /etc (config, init.d); generic bench under /
IPK=$(ls /ipk/rut360gw_*_mips_24kc.ipk | head -1)
RTIPK=$(ls /ipk/rut360gw-runtime_*_mips_24kc.ipk 2>/dev/null | head -1)
P=; grep -q '^dest root /usr/local' $R/etc/opkg.conf 2>/dev/null && P=/usr/local
mkdir -p $R$P
for f in $IPK $RTIPK; do tar -xzOf "$f" ./data.tar.gz | tar -xz -C $R$P; done
[ -n "$P" ] && cp -a $R$P/etc/. $R/etc/
echo "packages installed under: ${P:-/} ($(basename "$IPK")${RTIPK:+ + $(basename "$RTIPK")})"
RT=$R/tmp/rut360gw/root
BENCH_RUNTIME=${BENCH_RUNTIME:-$([ -n "$RTIPK" ] && echo embedded || echo bundle)}
# test UCI configuration (dummy values)
cat > $R/etc/config/rut360gw <<'EOF'
config rut360gw 'main'
	option enabled '1'
	option country 'fr'
config modem 'modem'
	option usb_id '2c7c:0306'
	option audio_if '1'
	option data_if '3'
	option clcc_poll '1000'
config trunk 'vps'
	option enabled '1'
	option peer_address '10.8.0.1'
	option local_address '10.8.0.3'
	option extension '102'
	option codec 'ulaw'
config sip 'local'
	option username 'test'
	option password 'testpass'
config features 'features'
	option sms_bridge '1'
	option ussd '1'
	option rtp_start '10000'
	option rtp_end '10100'
EOF
cp /usr/bin/qemu-mips-static $R/usr/bin/
mount --rbind /dev $R/dev; mount -t proc proc $R/proc
mkfifo /ctrl
# in a loop: a device restart (quectel restart) closes the ports, and socat exits with them;
# the simulated modem is then started again (call state reset, as after a modem reset)
( while :; do socat PTY,link=/dev/ttyUSB3,raw,echo=0 EXEC:"python3 /repo/tests/fake_eg06.py /ctrl /res/at.log"; sleep 0.2; done ) &
( while :; do socat PTY,link=/dev/ttyUSB1,raw,echo=0 EXEC:"python3 /repo/tests/fake_audio.py /res/audio_stall"; sleep 0.2; done ) &
sleep 1
ulimit -n 1024  # qemu-user: the emulated select() rejects fds >= FD_SETSIZE
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }

# ---- runtime in RAM
if [ "$BENCH_RUNTIME" = embedded ]; then
	# the service's real path: sha256 check, then extraction by the rootfs busybox, no network
	chroot $R /bin/sh $P/usr/sbin/rut360gw-runtime embedded > /res/runtime.out 2>&1
	check "embedded runtime (rut360gw-runtime package): verified and extracted without network" "[ -f $RT/.ready ] && [ -x $RT/usr/sbin/asterisk ] && [ -f $RT/usr/lib/asterisk/modules/chan_quectel.so ]"
else
	# fallback: the official .ipk files of the manifest, as after their download (bundle verified by the CI)
	mkdir -p $RT
	grep -v '^#' $R$P/usr/share/rut360gw/bundle.manifest | while read -r sha rel cond; do
		[ -n "$sha" ] || continue
		# same rule as rut360gw-runtime: "ifmissing:<file>" = only if the system does not have it
		case "$cond" in ifmissing:*) [ -e "$R${cond#ifmissing:}" ] && { echo "bundle : $(basename "$rel") not needed (provided by the system)"; continue; } ;; esac
		tar -xzOf "/dl/bundle/$(basename "$rel")" ./data.tar.gz | tar -xz -C $RT
	done
	cp $R$P/usr/share/rut360gw/modules/chan_quectel.so $RT/usr/lib/asterisk/modules/
	mkdir -p $R/tmp/rut360gw/var/lib/asterisk $R/tmp/rut360gw/var/spool/asterisk $R/tmp/rut360gw/log $R/var/run/rut360gw
	touch $RT/.ready
fi
echo "runtime : $BENCH_RUNTIME ($(du -sk $RT | cut -f1) KB in RAM)"

# ---- configuration generated by the package (under qemu, MIPS uci and sh)
chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate > /res/generate.out 2>&1
G=$R/var/run/rut360gw/etc
check "rut360gw-config: configuration generated" "[ -f $G/asterisk.conf ] && [ -f $G/extensions.conf ]"
check "no leftover @...@ variable" "! grep -q '@[A-Z_]*@' $G/*.conf"
check "ports injected (ttyUSB1 / ttyUSB3)" "grep -q '^audio = /dev/ttyUSB1' $G/quectel.conf && grep -q '^data = /dev/ttyUSB3' $G/quectel.conf"
check "local SIP client present (password set)" "grep -q '^username = test' $G/pjsip.conf"
check "tones: country fr + Algeria (dz)" "grep -q '^country=fr' $G/indications.conf && grep -q '^\[dz\]' $G/indications.conf"
# country outside the template (fr, dz): tones read from the RUNTIME's indications.conf (regression
# of earlier prototypes, which had removed it)
sed -i "s/option country 'fr'/option country 'it'/" $R/etc/config/rut360gw
chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate > /res/generate-it.out 2>&1
check "tones of a country outside the template (it): taken from the runtime" "grep -q '^country=it' $G/indications.conf && grep -q '^\[it\]' $G/indications.conf"
sed -i "s/option country 'it'/option country 'fr'/" $R/etc/config/rut360gw
chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate > /dev/null 2>&1
# a forbidden value is rejected: interface 2 (gsmd's AT port)
cp $R/etc/config/rut360gw /tmp/uci.bak
sed -i "s/option data_if '3'/option data_if '2'/" $R/etc/config/rut360gw
chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate >/res/refus.out 2>&1; echo "rc=$?" >> /res/refus.out
check "forbidden value (data_if=2) rejected" "grep -q forbidden /res/refus.out && grep -q 'rc=1' /res/refus.out"
cp /tmp/uci.bak $R/etc/config/rut360gw
check "previous configuration kept after a rejection" "grep -q '^data = /dev/ttyUSB3' $G/quectel.conf"
# local.username names the LAN client's PJSIP endpoint and AOR: one of the gateway's own section
# names is rejected
sed -i "s/option username 'test'/option username 'server-reg'/" $R/etc/config/rut360gw
chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate >/res/refus-user.out 2>&1; echo "rc=$?" >> /res/refus-user.out
check "local.username equal to a gateway section (server-reg) rejected" "grep -q 'reserved name' /res/refus-user.out && grep -q 'rc=1' /res/refus-user.out"
cp /tmp/uci.bak $R/etc/config/rut360gw
check "LAN client named after its username: endpoint, AOR, SMS destination and incoming calls" "[ \$(grep -c '^\[test\]' $G/pjsip.conf) -eq 2 ] && grep -q '^aors = test' $G/pjsip.conf && grep -q 'MessageSend(pjsip:test,' $G/extensions.conf && ! grep -q linphone $G/pjsip.conf $G/extensions.conf"
# legacy vps section (up to v0.1.1): server in ip mode, as before
check "vps section taken over in ip mode: server endpoint identified by its address, no registration" "grep -q '^\[server-identify\]' $G/pjsip.conf && grep -q '^match = 10.8.0.1' $G/pjsip.conf && ! grep -q '^\[server-reg\]' $G/pjsip.conf"
check "incoming GSM calls to the server (gsm_in auto)" "grep -q '^GSM_IN_DIAL = PJSIP/102@server ' $G/extensions.conf"
# server section, register mode: registration, account, no identification by address
gen_srv() { # $1 = mode, $2 = server password, $3 = gsm_in
	sed -e "/^config trunk 'vps'/,/^config sip/{/^config sip/!d}" /tmp/uci.bak > $R/etc/config/rut360gw
	cat >> $R/etc/config/rut360gw <<EOF2
config server 'server'
	option enabled '1'
	option mode '$1'
	option host '127.0.0.1'
	option port '5070'
	option username 'gw'
	option password '$2'
	option extension '102'
	option local_address '10.8.0.3'
EOF2
	chroot $R /sbin/uci set rut360gw.features.gsm_in="$3"; chroot $R /sbin/uci commit rut360gw
	chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate > /res/generate-srv.out 2>&1
}
gen_srv register 'gw&pass;1' auto
check "register mode: password containing \";\" rejected" "grep -q 'server.password empty or contains a forbidden character' /res/generate-srv.out"
gen_srv register 'gw&pass1' both
check "register mode: registration, gateway account, server identified only by its registration line (identify_by = ip, no address)" "grep -q '^\[server-reg\]' $G/pjsip.conf && grep -q '^client_uri = sip:gw@127.0.0.1:5070' $G/pjsip.conf && grep -q '^from_user = gw' $G/pjsip.conf && grep -q '^password = gw&pass1' $G/pjsip.conf && grep -q '^identify_by = ip' $G/pjsip.conf && ! grep -q '^\[server-identify\]' $G/pjsip.conf"
check "gsm_in both: server and LAN client ring together" "grep -q '^GSM_IN_DIAL = PJSIP/102@server&PJSIP/test ' $G/extensions.conf"
gen_srv ip 'x' local
check "ip mode: IPv4 address required, LAN client alone for incoming calls (gsm_in local)" "grep -q '^\[server-identify\]' $G/pjsip.conf && ! grep -q '^\[server-reg\]' $G/pjsip.conf && grep -q '^GSM_IN_DIAL = PJSIP/test ' $G/extensions.conf"
cp /tmp/uci.bak $R/etc/config/rut360gw
chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate > /dev/null 2>&1

# ---- migration of settings up to v0.1.1 (vps section + WireGuard tunnel created by the old package)
gen() { chroot $R /usr/bin/env RUT360GW_AUDIO_TTY=/dev/ttyUSB1 RUT360GW_DATA_TTY=/dev/ttyUSB3 /bin/sh $P/usr/sbin/rut360gw-config generate >/dev/null 2>&1; }
ug() { chroot $R /sbin/uci -q get "$1"; }
us() { chroot $R /sbin/uci "$@"; }
cp $R/etc/config/rut360gw /tmp/uci.bak
[ -f $R/etc/config/network ] && cp $R/etc/config/network /tmp/network.bak
# tunnel as left by rut360gw-wg; the vps section disagrees with it (the tunnel was authoritative)
printf "config interface 'wg_vps'\n\toption proto 'wireguard'\n\tlist addresses '10.8.0.4/32'\nconfig wireguard_wg_vps 'wg_vps_peer'\n\tlist allowed_ips '10.8.0.1/32'\n" >> $R/etc/config/network
us set rut360gw.vps.local_address=10.8.0.9; us commit rut360gw
chroot $R /bin/sh $P/usr/sbin/rut360gw-config migrate > /res/migrate.out 2>&1
check "migration vps -> server: ip mode, tunnel addresses, extension and codec carried over" '[ "$(ug rut360gw.server.mode)" = ip ] && [ "$(ug rut360gw.server.host)" = 10.8.0.1 ] && [ "$(ug rut360gw.server.local_address)" = 10.8.0.4 ] && [ "$(ug rut360gw.server.extension)" = 102 ] && [ "$(ug rut360gw.server.enabled)" = 1 ] && [ "$(ug rut360gw.server.codec)" = ulaw ]'
check "migration: vps section kept (rollback to v0.1.1 possible)" '[ "$(ug rut360gw.vps.extension)" = 102 ]'
gen
check "migration: configuration generated from the server section" "grep -q '^LOCAL_ADDR = 10.8.0.4 ' $G/extensions.conf && grep -q '^match = 10.8.0.1' $G/pjsip.conf"
us set rut360gw.server.extension=999; us commit rut360gw
chroot $R /bin/sh $P/usr/sbin/rut360gw-config migrate > /dev/null 2>&1
check "migration: no effect once the server section exists" '[ "$(ug rut360gw.server.extension)" = 999 ]'
cp /tmp/uci.bak $R/etc/config/rut360gw
if [ -f /tmp/network.bak ]; then cp /tmp/network.bak $R/etc/config/network; else rm -f $R/etc/config/network; fi
gen

# ---- LAN firewall (rut360gw-fw: SIP rate limit, anti-spoofing in ip mode) and access list
[ -f $R/etc/config/firewall ] && cp $R/etc/config/firewall /tmp/firewall.bak
printf "config defaults\n\toption input 'ACCEPT'\nconfig zone\n\toption name 'lan'\n\toption input 'ACCEPT'\nconfig rule 'autre'\n\toption name 'regle existante'\n\toption target 'ACCEPT'\n" > $R/etc/config/firewall
fw() { chroot $R /usr/bin/env RUT360GW_FW_NORELOAD=1 /bin/sh $P/usr/sbin/rut360gw-fw "$@" 2>&1; }
fw apply > /res/fw-apply.out
check "firewall, ip mode: anti-spoofing of 10.8.0.1 from the LAN, then SIP limit 20/s and drop beyond" '[ "$(ug firewall.rut360gw_antispoof.src_ip)" = 10.8.0.1 ] && [ "$(ug firewall.rut360gw_antispoof.target)" = DROP ] && [ "$(ug firewall.rut360gw_sip_lan.limit)" = 20/sec ] && [ "$(ug firewall.rut360gw_sip_lan_drop.target)" = DROP ] && [ "$(ug firewall.autre.name)" = "regle existante" ]'
check "firewall: order anti-spoofing, limit, drop" "grep -n '^config rule' $R/etc/config/firewall | sed -n '2,4p' | grep -c . | grep -q 3 && awk '/rut360gw_antispoof/{a=NR} /rut360gw_sip_lan.$/{b=NR} /rut360gw_sip_lan_drop/{c=NR} END{exit !(a<b && b<c)}' $R/etc/config/firewall"
fw apply > /res/fw-apply2.out
check "firewall: nothing to do when the rules are already in place" "! grep -q 'rules updated' /res/fw-apply2.out"
us set rut360gw.features.lan_sip_limit=0; us commit rut360gw; fw apply > /dev/null
check "firewall: lan_sip_limit=0, no more limit (anti-spoofing kept)" '[ -z "$(ug firewall.rut360gw_sip_lan)" ] && [ -z "$(ug firewall.rut360gw_sip_lan_drop)" ] && [ -n "$(ug firewall.rut360gw_antispoof)" ]'
fw remove > /dev/null
check "firewall: remove deletes our rules, and only ours" '[ -z "$(ug firewall.rut360gw_antispoof)" ] && [ "$(ug firewall.autre.name)" = "regle existante" ]'
cp /tmp/uci.bak $R/etc/config/rut360gw
if [ -f /tmp/firewall.bak ]; then cp /tmp/firewall.bak $R/etc/config/firewall; else rm -f $R/etc/config/firewall; fi
# LAN SIP client restricted to the LAN subnet (and to the loopback, where the bench's attempts come from)
[ -f $R/etc/config/network ] && cp $R/etc/config/network /tmp/network.bak2
printf "config interface 'lan'\n\toption proto 'static'\n\toption ipaddr '192.168.2.1'\n\toption netmask '255.255.255.0'\n" > $R/etc/config/network
gen
check "LAN SIP client: accepted only from the LAN (192.168.2.1/255.255.255.0) and the loopback" "grep -q '^permit = 192.168.2.1/255.255.255.0' $G/pjsip.conf && grep -q '^deny = 0.0.0.0/0.0.0.0' $G/pjsip.conf && grep -q '^permit = 127.0.0.1/' $G/pjsip.conf"
if [ -f /tmp/network.bak2 ]; then cp /tmp/network.bak2 $R/etc/config/network; else rm -f $R/etc/config/network; fi
gen

# ---- embedded runtime: tampered archive, trial base (next to the running runtime)
EMB=$R$P/usr/share/rut360gw/runtime.tar.gz
if [ -f "$EMB" ]; then
	rt() { chroot $R /usr/bin/env RUT360GW_RUNTIME_BASE="$1" /bin/sh $P/usr/sbin/rut360gw-runtime "${2:-embedded}" > "/res/embedded-${1##*/}.out" 2>&1; }
	cp "$EMB" /tmp/emb.bak; printf 'x' >> "$EMB"
	rt /tmp/rt-emb-bad
	check "tampered embedded runtime: rejected" "[ ! -f $R/tmp/rt-emb-bad/root/.ready ] && grep -q damaged /res/embedded-rt-emb-bad.out"
	cp /tmp/emb.bak "$EMB"
	# purging a trial base: the generated configuration of the running runtime stays in place
	rt /tmp/rt-emb-ok; rt /tmp/rt-emb-ok purge
	check "purging a trial base: /var/run/rut360gw kept" "[ ! -e $R/tmp/rt-emb-ok ] && [ -f $G/asterisk.conf ]"
fi

# ---- web page API (logs method): never any SMTP credential. urcd (RutOS) logs the SMTP dialogue
# of the SMS -> e-mail forwarding; logread is replaced by a fake log (dummy values)
mkdir -p $R/tmp/fakebin
cat > $R/tmp/fakebin/logread <<'EOF'
#!/bin/sh
echo "Tue Nov 17 10:00:01 2026 daemon.debug urcd[901]: > AUTH PLAIN ZmFjdGljZUBleGVtcGxlLm9yZwBtb3RkZXBhc3NlLWZhY3RpY2U="
echo "Tue Nov 17 10:00:02 2026 daemon.debug urcd[901]: < 334 VXNlcm5hbWU6 rut360gw"
echo "Tue Nov 17 10:00:03 2026 daemon.debug urcd[901]: > ZmFjdGljZUBleGVtcGxlLm9yZw== rut360gw"
echo "Tue Nov 17 10:00:04 2026 user.notice rut360gw: test AUTH LOGIN bW90ZGVwYXNzZQ=="
echo "Tue Nov 17 10:00:05 2026 user.notice rut360gw: runtime ready (embedded, 4.4M in RAM)"
echo "Tue Nov 17 10:00:06 2026 local0.err asterisk[77]: ERROR[78]: chan_quectel.c:1 test"
EOF
chmod 755 $R/tmp/fakebin/logread
echo '{}' | chroot $R /usr/bin/env PATH=/tmp/fakebin:/usr/sbin:/usr/bin:/sbin:/bin /bin/sh $P/usr/libexec/rpcd/rut360gw call logs > /res/api-logs.json 2>&1
check "logs API: SMTP credentials never returned (urcd, AUTH, 334), useful lines kept" \
	"grep -q 'runtime ready' /res/api-logs.json && grep -q 'asterisk\[77\]' /res/api-logs.json && ! grep -q -E 'urcd|AUTH|334|ZmFjdGljZ|bW90ZGVwYXNzZQ' /res/api-logs.json"
rm -rf $R/tmp/fakebin
# web page API: SIP server settings (server section), no more config sheet nor WireGuard key
us set rut360gw.server=server; us set rut360gw.server.mode=register; us set rut360gw.server.host=pbx.example.com; us commit rut360gw
echo '{}' | chroot $R /bin/sh $P/usr/libexec/rpcd/rut360gw call get_config > /res/api-config.json 2>&1
chroot $R /bin/sh $P/usr/libexec/rpcd/rut360gw list > /res/api-list.json 2>&1
check "get_config API: SIP server settings; config sheet and WireGuard key methods removed" "grep -q '\"server_mode\": \"register\"' /res/api-config.json && grep -q '\"server_host\": \"pbx.example.com\"' /res/api-config.json && ! grep -q -E 'get_fiche|prepare|set_vps_key' /res/api-list.json"
cp /tmp/uci.bak $R/etc/config/rut360gw

# ---- Asterisk (PJSIP included) + chan_quectel against the simulated modem
LDP=/tmp/rut360gw/root/usr/lib:/tmp/rut360gw/root/lib
# TEST shims (never installed on the router): qemu-user emulates neither TIOCGEXCL (serial ports)
# nor the netlink answer of getifaddrs() (PJSIP)
ast() { chroot $R /usr/bin/qemu-mips-static -E LD_LIBRARY_PATH=$LDP -E LD_PRELOAD=/tmp/tiocexcl_shim.so:/tmp/ifaddrs_shim.so /tmp/rut360gw/root/usr/sbin/asterisk -C /var/run/rut360gw/etc/asterisk.conf "$@"; }
cp /ipk/tiocexcl_shim.so /ipk/ifaddrs_shim.so $R/tmp/
# bench only: container name resolved locally. Without DNS in the chroot, Asterisk waited several
# seconds for its resolution on the first SIP call (media address); on the router RutOS resolves it
echo "127.0.0.1 $(hostname)" >> $R/etc/hosts
# bench only: dialplan trace ("Executing [...]") in /res/asterisk.out
sed -i 's/^verbose = .*/verbose = 3/' $G/asterisk.conf
# RTP timeout: 60 s in the package, reduced to 8 s for the duration of the bench
check "RTP timeout of 60 s on the server and LAN client endpoints" "[ \$(grep -c -E '^rtp_timeout = 60' $G/pjsip.conf) -eq 2 ]"
sed -i 's/^rtp_timeout = 60/rtp_timeout = 8/' $G/pjsip.conf
sed -i 's/^console => .*/&,verbose/' $G/logger.conf
astrx() { ast -rx "$1" 2>&1; }
# start with a call still open in the modem, as after an Asterisk crash during a call (seen on a
# real EG06): the modem then refuses serial voice (AT+QPCMV=1,0). The driver must hang up this
# unknown call, then enable voice again; otherwise every call is refused.
echo "add_call 3 0 0" > /ctrl
ast -f > /res/asterisk.out 2>&1 &
for i in $(seq 1 60); do astrx 'core waitfullybooted' >/dev/null 2>&1 && break; sleep 2; done
for i in $(seq 1 30); do astrx 'quectel show devices' | grep -q -i free && break; sleep 2; done
sleep 8
astrx 'module show like quectel' > /res/modules.txt
check "chan_quectel.so loaded (MIPS/musl ABI)" "grep -q chan_quectel /res/modules.txt"
check "eg06 device initialized (Free)" "astrx 'quectel show devices' | grep -q -i free"
check "no SMS command (CMGF/CNMI/CPMS/CSMS/CSCA)" "! grep -E 'AT\+(CMGF|CNMI|CPMS|CSMS|CSCA)' /res/at.log"
check "no global URC config (QINDCFG/DSCI)" "! grep -E 'QINDCFG|\^DSCI' /res/at.log"
check "no global setting (CSCS/CMEE/CSSN/VTD/COPS=/CREG=/CEREG=/QTONEDET)" "! grep -E 'AT[+](CSCS|CMEE|CSSN|VTD|COPS=|CREG=|CEREG=|QTONEDET)' /res/at.log"
check "no ATZ" "! grep -x -E '[0-9.]+ ATZ' /res/at.log"
check "operator call waiting left unchanged (no CCWA=)" "! grep -E 'AT\+CCWA=' /res/at.log"
check "serial voice enabled (AT+QPCMV=1,0)" "grep -q 'AT+QPCMV=1,0' /res/at.log"
check "start with a call still open: call hung up, serial voice enabled again afterwards" "grep -q -E 'AT\+QHUP=21,3$' /res/at.log && [ \$(grep -c 'AT+QPCMV=1,0' /res/at.log) -ge 2 ] && grep -a -q 'Voice not enabled: enabling it again' /res/asterisk.out && astrx 'quectel show device state eg06' | grep -q -E 'Voice +: Yes'"
check "CLCC polling active (>=5 in 8 s)" "[ \$(grep -c 'AT+CLCC' /res/at.log) -ge 5 ]"
# dependencies of the generated dialplan: every application/function is provided by a loaded module
APPS=$(astrx 'core show applications' | awk -F: 'NF>1{gsub(/ /,"",$1); print toupper($1)}')
FUNCS=$(astrx 'core show functions' | awk 'NR>2{print toupper($1)}')
miss=""
for a in $( { grep -E '^\s*exten\s*=>' $G/extensions.conf | sed -E 's/^[^,]*,[^,]*,//'; grep -E '^\s*same\s*=>' $G/extensions.conf | sed -E 's/^[^,]*,//'; } | grep -o -E '^[A-Za-z]+' | sort -u); do
	echo "$APPS" | grep -q -x "$(echo "$a" | tr a-z A-Z)" || miss="$miss $a"; done
for f in $(grep -o -E '\$\{[A-Z][A-Z0-9_]+\(' $G/extensions.conf | tr -d '${(' | sort -u); do
	echo "$FUNCS" | grep -q -x "$f" || miss="$miss $f()"; done
echo "missing dependencies:${miss:- none}" > /res/deps.txt
check "dialplan: every application/function has its module" "[ -z \"$miss\" ]"
# incoming call (echo), remote hangup, outgoing call, +CME ERROR
astrx 'dialplan set global GSM_ECHO_TEST 1' >/dev/null
echo "ring +33612345678" > /ctrl; sleep 4
check "incoming call detected without URC" "astrx 'core show channels concise' | grep -q 'Quectel/eg06'"
check "answered (ATA)" "grep -q ' ATA' /res/at.log"
echo "remote_hangup" > /ctrl; sleep 5
check "end of call detected by polling" "! astrx 'core show channels concise' | grep -q 'Quectel/eg06'"
astrx 'channel originate Quectel/eg06/0612345678 application Wait 6' >/dev/null; sleep 3
check "outgoing call (ATD)" "grep -q 'ATD0612345678' /res/at.log"
echo "answer_remote" > /ctrl; sleep 9
check "local hangup (CHUP/QHUP)" "grep -E -q 'AT\+(CHUP|QHUP)' /res/at.log"
check "outgoing channel released" "! astrx 'core show channels concise' | grep -q 'Quectel/eg06'"
astrx 'channel originate Quectel/eg06/0001 application Wait 3' >/dev/null; sleep 5
check "+CME ERROR: call released without restarting the device" "! astrx 'core show channels concise' | grep -q Quectel/eg06 && astrx 'quectel show devices' | grep -q -i free"

# hangup refused by the modem (seen on a real EG06): the outgoing call is cancelled while ringing,
# the modem answers ERROR to the hangup and keeps the call. The driver must hang up again
# (AT+CHUP then AT+QHUP) and the line must become free again within a few seconds.
eg06_free() { astrx 'quectel show devices' | grep -q -i free; }
hup_count() { grep -c -E "AT\+$1" /res/at.log; }
retry_count() { grep -a -c 'still listed after hangup, hanging up again' /res/asterisk.out; }
cancel_call() {
	astrx "channel originate Quectel/eg06/$1 application Wait 30" >/dev/null
	for i in $(seq 1 15); do grep -q "ATD$1" /res/at.log && break; sleep 1; done
	sleep 3
	ch=$(astrx 'core show channels concise' | grep -o -m1 '^Quectel/eg06[^!]*')
	[ -n "$ch" ] && astrx "channel request hangup $ch" >/dev/null
}
wait_free() { t=0; while [ $t -lt $1 ] && ! eg06_free; do sleep 1; t=$((t+1)); done; echo $t; }
: > /res/hangup-retry.txt
echo "refuse_hangup 1 qhup" > /ctrl
c0=$(hup_count CHUP)
cancel_call 0612345670
sleep 1
check "hangup refused (QHUP): call kept by the modem, line busy" "! eg06_free"
t=$(wait_free 25); echo "QHUP refused: line free after $t s" >> /res/hangup-retry.txt
check "hangup refused (QHUP): new hangup with AT+CHUP, line free (${t} s)" "[ \$(hup_count CHUP) -gt $c0 ] && eg06_free && [ $t -lt 20 ]"
echo "refuse_hangup 2 all" > /ctrl
r0=$(retry_count)
cancel_call 0612345671
t=$(wait_free 30); echo "two refusals: line free after $t s" >> /res/hangup-retry.txt
check "hangup refused twice: the driver retries until the call is released (${t} s)" "[ \$(retry_count) -ge \$((r0 + 2)) ] && eg06_free && [ $t -lt 25 ]"
echo "refuse_hangup 1 gone" > /ctrl
r0=$(retry_count); c0=$(hup_count CHUP)
cancel_call 0612345672
t=$(wait_free 15); sleep 4; echo "call already released: line free after $t s" >> /res/hangup-retry.txt
check "hangup error on a call already released: line free, no retry" "eg06_free && [ \$(retry_count) -eq $r0 ] && [ \$(hup_count CHUP) -eq $c0 ]"

# calls listed late by the modem (seen on a real EG06 during a 4G -> 3G fallback), cancelled before
# being listed, or unknown to the driver: no call failure, no provisional index, no call left over
late_count() { grep -a -c 'listed by the modem after' /res/asterisk.out; }
unknown_count() { grep -a -c 'unknown call idx' /res/asterisk.out; }
hangup_err_count() { grep -a -c 'Error sending hangup' /res/asterisk.out; }
qhup3_count() { grep -c -E 'AT\+QHUP=[0-9]+,3$' /res/at.log; }
modem_calls_empty() { echo dump > /ctrl; sleep 1; grep 'CALLS' /res/at.log | tail -1 | grep -q 'CALLS 0$'; }
dial_wait() { for i in $(seq 1 15); do grep -q "ATD$1" /res/at.log && break; sleep 1; done; }
chan_hangup() { ch=$(astrx 'core show channels concise' | grep -o -m1 '^Quectel/eg06[^!]*'); [ -n "$ch" ] && astrx "channel request hangup $ch" >/dev/null; }
echo "list_delay 4" > /ctrl
l0=$(late_count); u0=$(unknown_count)
astrx "channel originate Quectel/eg06/0612345673 application Wait 20" >/dev/null
dial_wait 0612345673; sleep 7
check "call listed 4 s after dialing: still in progress, reported in the log" "astrx 'core show channels concise' | grep -q '^Quectel/eg06' && [ \$(late_count) -gt $l0 ]"
echo "answer_remote" > /ctrl; sleep 3
check "call listed late: answered afterwards" "astrx 'core show channels concise' | grep '^Quectel/eg06' | grep -q '!Up!'"
q0=$(qhup3_count); chan_hangup
t=$(wait_free 10); echo "call listed late: line free $t s after the hangup" >> /res/hangup-retry.txt
check "call listed late: hung up by its real index, line free, no unknown call" "[ \$(qhup3_count) -gt $q0 ] && eg06_free && [ \$(unknown_count) -eq $u0 ] && modem_calls_empty"
echo "list_delay 6" > /ctrl
u0=$(unknown_count); c0=$(hup_count CHUP); e0=$(hangup_err_count)
astrx "channel originate Quectel/eg06/0612345674 application Wait 20" >/dev/null
dial_wait 0612345674; sleep 1; chan_hangup
t=$(wait_free 10); sleep 7; echo "cancelled before being listed: line free after $t s" >> /res/hangup-retry.txt
check "cancelled before the modem lists it: immediate AT+CHUP, no error, line free (${t} s)" "[ \$(hup_count CHUP) -gt $c0 ] && [ \$(hangup_err_count) -eq $e0 ] && eg06_free && [ $t -le 4 ] && [ \$(unknown_count) -eq $u0 ] && modem_calls_empty"
echo "list_delay 4 sticky" > /ctrl
q0=$(qhup3_count)
astrx "channel originate Quectel/eg06/0612345675 application Wait 20" >/dev/null
dial_wait 0612345675; sleep 1; chan_hangup
t=$(wait_free 15); sleep 5; echo "cancelled, hangup refused, listed later: line free after $t s" >> /res/hangup-retry.txt
check "cancelled, hangup refused, then listed anyway: hung up by its real index, no call left over (${t} s)" "[ \$(qhup3_count) -gt $q0 ] && eg06_free && modem_calls_empty"
u0=$(unknown_count)
echo "add_call 3 0 0" > /ctrl; sleep 7
check "active call unknown to the driver (Asterisk restarted during a call): hung up" "[ \$(unknown_count) -gt $u0 ] && grep -q -E 'AT\+QHUP=21,3$' /res/at.log && modem_calls_empty && eg06_free"
check "never AT+QHUP on a provisional index (31) or a data index (1, 2)" "! grep -q -E 'AT\+QHUP=[0-9]+,(1|2|31)$' /res/at.log"

# ---- SIP: LAN client (endpoint "test" = local.username of the GENERATED pjsip.conf; From, To and
# Contact carry the username, as a softphone configured as documented), loopback
astrx 'pjsip show endpoints' > /res/pjsip-endpoints.txt
check "PJSIP loaded: LAN client (named after its username) and server endpoints" "grep -q -E 'Endpoint:  test( |/)' /res/pjsip-endpoints.txt && grep -q 'Endpoint:  server' /res/pjsip-endpoints.txt"
SIPC="python3 /repo/tests/sip_client.py --user test --password testpass"
$SIPC register > /res/sip-register.out 2>&1
check "SIP: REGISTER of the local client (digest)" "grep -q 'REGISTER -> 200' /res/sip-register.out"
$SIPC echo 600 > /res/sip-echo.out 2>&1; echo "rc=$?" >> /res/sip-echo.out
check "SIP: call to echo 600, RTP echoed back, BYE" "grep -q 'INVITE 600 -> 200' /res/sip-echo.out && grep -q 'rc=0' /res/sip-echo.out"
$SIPC message 0612345678 bonjour > /res/sip-message.out 2>&1
sleep 2
check "SIP: MESSAGE to a number -> SMS bridge (sms-out context)" "grep -q 'MESSAGE 0612345678 -> 202' /res/sip-message.out && grep -a -q '0612345678@sms-out' /res/asterisk.out"
# SIP -> GSM call: the simulated modem sees ATD, answers, then the SIP client hangs up
n0=$(grep -c -E 'AT\+(CHUP|QHUP)' /res/at.log)
$SIPC call 0612345679 --wait 40 --hold 3 > /res/sip-call.out 2>&1 &
SPID=$!
for i in $(seq 1 20); do grep -q 'ATD0612345679' /res/at.log && break; sleep 1; done
check "SIP -> GSM: dialed by the modem (ATD)" "grep -q 'ATD0612345679' /res/at.log"
sleep 2; echo "answer_remote" > /ctrl
wait $SPID; echo "rc=$?" >> /res/sip-call.out
check "SIP -> GSM: answered (200), then BYE from the SIP client" "grep -q 'INVITE 0612345679 -> 200' /res/sip-call.out && grep -q 'rc=0' /res/sip-call.out"
sleep 4
check "SIP -> GSM: GSM call released (CHUP/QHUP)" "[ \$(grep -c -E 'AT\+(CHUP|QHUP)' /res/at.log) -gt $n0 ] && ! astrx 'core show channels concise' | grep -q Quectel/eg06"
# "&" in the dialled number: before, Dial() received it as is and called a second destination
# (here a second GSM number). Only the filtered number may be dialled: the call is refused.
$SIPC call '0612345690&Quectel/eg06/0612345691' --wait 15 > /res/sip-inject.out 2>&1; echo "rc=$?" >> /res/sip-inject.out
sleep 2
check "SIP: \"&\" in the dialled number refused, nothing dialled by the modem" "grep -q -E 'INVITE 0612345690&Quectel/eg06/0612345691 -> [3-6][0-9][0-9]' /res/sip-inject.out && ! grep -q -E 'ATD06123456(90|91)' /res/at.log && modem_calls_empty"

# the SIP client vanishes mid-call (remote SIP server, tunnel or softphone lost): without a BYE, the
# GSM call stayed open. The RTP timeout (8 s on the bench) must hang it up.
n0=$(qhup3_count)
$SIPC call 0612345680 --wait 40 --vanish > /res/sip-vanish.out 2>&1 &
SPID=$!
dial_wait 0612345680; sleep 2; echo "answer_remote" > /ctrl
wait $SPID; echo "rc=$?" >> /res/sip-vanish.out
t=0; while [ $t -lt 30 ] && astrx 'core show channels concise' | grep -q '^Quectel/eg06'; do sleep 1; t=$((t+1)); done
echo "SIP client vanished: GSM call hung up $t s after it vanished" >> /res/hangup-retry.txt
check "SIP client vanished mid-call: GSM call hung up by the RTP timeout (${t} s)" "grep -q 'INVITE 0612345680 -> 200' /res/sip-vanish.out && [ \$(qhup3_count) -gt $n0 ] && ! astrx 'core show channels concise' | grep -q Quectel/eg06 && [ $t -ge 4 ] && modem_calls_empty"

# incoming call the softphone cannot take (here: remote SIP server unreachable): rejected as "busy"
# (cause 17) so that the operator forwards the caller to voicemail, instead of a plain hangup
q17_count() { grep -c -E 'AT\+QHUP=17,3$' /res/at.log; }
astrx 'dialplan set global GSM_ECHO_TEST 0' >/dev/null
sleep 3; k0=$(q17_count)
echo "ring +33612345681" > /ctrl
for i in $(seq 1 45); do [ "$(q17_count)" -gt "$k0" ] && break; sleep 1; done
check "incoming call, softphone unreachable: rejected as \"busy\" (AT+QHUP=17) for voicemail (${i} s)" "[ \$(q17_count) -gt $k0 ] && modem_calls_empty"
echo "remote_hangup" > /ctrl; sleep 3

# end of a call and a new incoming call at the same moment, under the same index: the modem reuses
# the index before two polls have confirmed the end of the first one. Previously the incoming call
# was mistaken for the old one ("direction mismatch"), ignored, then hung up with AT+CHUP.
astrx "channel originate Quectel/eg06/0612345682 application Wait 30" >/dev/null
dial_wait 0612345682; sleep 2; echo "answer_remote" > /ctrl; sleep 3
r0=$(grep -a -c 'reused by the modem for a new call' /res/asterisk.out); k0=$(q17_count)
printf 'remote_hangup\nring +33612345683\n' > /ctrl
for i in $(seq 1 45); do [ "$(q17_count)" -gt "$k0" ] && break; sleep 1; done
sleep 2
check "end of call and incoming call under the same index: old call released, new call handled (${i} s)" "[ \$(grep -a -c 'reused by the modem for a new call' /res/asterisk.out) -gt $r0 ] && [ \$(q17_count) -gt $k0 ] && modem_calls_empty && ! astrx 'core show channels concise' | grep -q Quectel/eg06"
check "no call ignored because of a different direction" "! grep -a -q 'direction mismatch' /res/asterisk.out"

# calls ended by the network while voice is being written to the modem (continuous tone): the
# channel waits for the device lock while the device releases the call. The old driver then read
# the released call's memory to unlock (seen on a real EC25: "Task skipping: no lock" forever).
# The device must stay free and keep answering after each call.
astrx 'dialplan add extension 700,1,Answer into bench-voice' >/dev/null
astrx 'dialplan add extension 700,2,Playtones,440 into bench-voice' >/dev/null
astrx 'dialplan add extension 700,3,Wait,30 into bench-voice' >/dev/null
ok_calls=0
for k in 1 2 3 4 5 6; do
	astrx "channel originate Quectel/eg06/06123457$k extension 700@bench-voice" >/dev/null
	dial_wait "06123457$k"; sleep 1; echo "answer_remote" > /ctrl; sleep 2
	echo "network_end" > /ctrl
	t=$(wait_free 15)
	eg06_free && ! astrx 'core show channels concise' | grep -q '^Quectel/eg06' && ok_calls=$((ok_calls+1))
done
clcc_count() { grep -c 'AT+CLCC$' /res/at.log; }
n0=$(clcc_count); sleep 5
check "6 calls ended by the network (audio port stalled, NO CARRIER): device free after each ($ok_calls/6), AT+CLCC polling still active" "[ $ok_calls -eq 6 ] && eg06_free && [ \$(clcc_count) -gt \$((n0 + 2)) ]"

# AT+QPCMV? refused during initialization, like a restarting modem (AT port ready before voice):
# the old driver stopped the initialization and stayed "Not initialized" until Asterisk was
# restarted. It must now schedule a device restart every 15 s.
i0=$(grep -a -c 'AT+QPCMV? refused during init' /res/asterisk.out)
echo "refuse_qpcmv_query 2" > /ctrl; sleep 1
astrx 'quectel restart now eg06' >/dev/null
sleep 5
for i in $(seq 1 60); do eg06_free && break; sleep 2; done
echo "QPCMV? refused twice: device free after about $((5 + 2 * i)) s" >> /res/hangup-retry.txt
check "AT+QPCMV? refused twice during initialization: restarts scheduled, then device free" "[ \$(grep -a -c 'AT+QPCMV? refused during init' /res/asterisk.out) -ge \$((i0 + 2)) ] && eg06_free"

# ---- remote SIP server in register mode (Asterisk, FreePBX...): fake server on 127.0.0.1:5070,
# digest authentication required for REGISTER and MESSAGE. The gateway registers, sends it the
# incoming GSM calls and the SMS under its account (number as display name), and accepts its calls.
mkfifo /ctrl-reg
: > /res/registrar.log
python3 /repo/tests/fake_registrar.py 5070 gw 'gw&pass1' /res/registrar.log /ctrl-reg &
gen_srv register 'gw&pass1' auto
astrx 'module reload res_pjsip.so' >/dev/null; astrx 'module reload res_pjsip_outbound_registration.so' >/dev/null; astrx 'dialplan reload' >/dev/null
for i in $(seq 1 30); do astrx 'pjsip show registrations' | grep 'server-reg' | grep -q ' Registered' && break; sleep 1; done
astrx 'pjsip show registrations' > /res/pjsip-registrations.txt
check "register mode: registration accepted after digest authentication (${i} s)" "grep -q 'REGISTER-401' /res/registrar.log && grep -q 'REGISTER-200' /res/registrar.log && grep -q 'Registered' /res/pjsip-registrations.txt"
k0=$(q17_count)
echo "ring +33612345691" > /ctrl
for i in $(seq 1 45); do [ "$(q17_count)" -gt "$k0" ] && break; sleep 1; done
check "register mode: incoming GSM call presented to the server (extension 102, account gw, number in P-Asserted-Identity), \"busy\" rejection relayed" "grep -E 'INVITE ruri=sip:102@127.0.0.1:5070' /res/registrar.log | grep -q 'sip:gw@' && grep 'INVITE ruri=sip:102@' /res/registrar.log | grep -q '+33612345691' && [ \$(q17_count) -gt $k0 ]"
echo "remote_hangup" > /ctrl; sleep 2
astrx 'database put rut360sms 9001_b64 Ym9uam91cg==' >/dev/null
astrx 'database put rut360sms 9001_from +33612345692' >/dev/null
astrx 'channel originate Local/9001@sms-to-sip application Wait 1' >/dev/null
for i in $(seq 1 15); do grep -q 'MESSAGE-200' /res/registrar.log && break; sleep 1; done
check "register mode: received SMS relayed as an authenticated MESSAGE (sender as display name, account gw)" "grep -q 'MESSAGE-401' /res/registrar.log && grep 'MESSAGE-200' /res/registrar.log | grep -q -E '[+]33612345692.? <sip:gw@127.0.0.1>' && grep 'MESSAGE-200' /res/registrar.log | grep -q 'body=bonjour'"
echo "invite 0612345693" > /ctrl-reg
dial_wait 0612345693
check "register mode: call from the server (registered line) dialed to GSM" "grep -q 'ATD0612345693' /res/at.log"
echo "cancel" > /ctrl-reg; sleep 4
check "register mode: call cancelled by the server, line free" "eg06_free && ! astrx 'core show channels concise' | grep -q '^Quectel/eg06'"
echo "message 0612345695 bonjour" > /ctrl-reg
for i in $(seq 1 10); do grep -q 'RESPONSE 202 .*MESSAGE' /res/registrar.log && break; sleep 1; done
check "register mode: MESSAGE from the server (registered line) accepted to the SMS bridge" "grep -q 'RESPONSE 202 .*MESSAGE' /res/registrar.log && grep -a -q '0612345695@sms-out' /res/asterisk.out"
# a LAN client posing as the server (From: server, no account): before the fix, identified by the
# user of its From header and treated as the server, without a password (GSM call and SMS)
SPOOF="python3 /repo/tests/sip_client.py --user server --password wrong --port 5072 --rtp 40020"
$SPOOF call 0612345694 --wait 10 > /res/sip-spoof.out 2>&1
$SPOOF message 0612345696 spoof >> /res/sip-spoof.out 2>&1
sleep 2
check "register mode: LAN request posing as the server (From: server) refused, no GSM call, no SMS" "grep -q -E 'INVITE 0612345694 -> 40[13]' /res/sip-spoof.out && grep -q -E 'MESSAGE 0612345696 -> 40[13]' /res/sip-spoof.out && ! grep -q 'ATD0612345694' /res/at.log && ! grep -a -q -E '0612345694@from-server|0612345696@sms-out' /res/asterisk.out"

# ---- URC mode, like an EC25 in URC mode (Pi gateway): +QIND "ccinfo" IN ADDITION to AT+CLCC polling
# The modem sends RING and +QIND "ccinfo"; the "dialing" URC arrives BEFORE the OK of ATD. The driver
# must attach the call anyway, and never hang up one of its own calls as "unknown".
astrx 'core stop now' >/dev/null 2>&1
for i in $(seq 1 30); do astrx 'core show uptime' >/dev/null 2>&1 || break; sleep 1; done
sed -i -e 's/^urc_cfg *=.*/urc_cfg = on/' $G/quectel.conf
echo "urc on" > /ctrl
ast -f > /res/asterisk-urc.out 2>&1 &
for i in $(seq 1 60); do astrx 'core waitfullybooted' >/dev/null 2>&1 && break; sleep 2; done
for i in $(seq 1 30); do eg06_free && break; sleep 2; done
urc_unknown() { grep -a -c 'unknown call idx' /res/asterisk-urc.out; }
check "URC mode: +QIND ccinfo enabled at start, line free" "grep -q 'AT+QINDCFG=.ccinfo.,1' /res/at.log && eg06_free"
q0=$(qhup3_count)
astrx "channel originate Quectel/eg06/0612345690 application Wait 20" >/dev/null
dial_wait 0612345690; sleep 4
check "URC mode: ccinfo \"dialing\" before the OK of ATD, call attached, still in progress" "astrx 'core show channels concise' | grep -q '^Quectel/eg06' && grep -q 'URC ccinfo 3 2' /res/at.log && [ \$(urc_unknown) -eq 0 ]"
echo "answer_remote" > /ctrl; sleep 3
check "URC mode: answered" "astrx 'core show channels concise' | grep '^Quectel/eg06' | grep -q '!Up!'"
chan_hangup; t=$(wait_free 10)
check "URC mode: hung up by its real index, line free, no unknown call (${t} s)" "[ \$(qhup3_count) -gt $q0 ] && eg06_free && [ \$(urc_unknown) -eq 0 ] && modem_calls_empty"
e0=$(grep -a -c 'Error sending hangup' /res/asterisk-urc.out)
astrx "channel originate Quectel/eg06/0612345691 application Wait 20" >/dev/null
dial_wait 0612345691; chan_hangup; t=$(wait_free 10)
check "URC mode: cancelled at once, hung up without error, line free (${t} s)" "[ \$(grep -a -c 'Error sending hangup' /res/asterisk-urc.out) -eq $e0 ] && eg06_free && modem_calls_empty && [ \$(urc_unknown) -eq 0 ]"
k0=$(q17_count)
echo "ring +33612345692" > /ctrl
for i in $(seq 1 45); do [ "$(q17_count)" -gt "$k0" ] && break; sleep 1; done
check "URC mode: incoming call (RING + ccinfo) handled, rejected as busy (${i} s)" "[ \$(q17_count) -gt $k0 ] && modem_calls_empty"
check "URC mode: never AT+QHUP on a provisional (31) or data (1, 2) index" "! grep -q -E 'AT\+QHUP=[0-9]+,(1|2|31)$' /res/at.log"

echo "Result: $PASS PASS / $FAIL FAIL"
astrx 'core stop now' >/dev/null 2>&1; sleep 2
umount $R/proc; umount -l $R/dev 2>/dev/null
exit $FAIL
