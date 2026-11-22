#!/bin/sh
# soak-remote.sh — remotely driven endurance test: nothing is installed or left on the router.
# A Linux machine that reaches the router over SSH takes a sample at a regular interval (one
# read-only command per sample, reused SSH connection) and writes the CSV locally.
#
#   sh soak-remote.sh probe                                 # prints the sampling command (one line)
#   sh soak-remote.sh run <ssh-target> <file.csv> [interval_s] [hours]   # default 120 s, 48 h
#   sh soak-remote.sh report <file.csv>
#
# Restricted key (recommended in production): on the router, in /etc/dropbear/authorized_keys,
#   command="<probe output>",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... soak
# The key can then only run the sampling command, whatever command is requested.
# The sampling command contains no double quote, so that it fits in command="...".
# SSH options (key, known_hosts...): SOAK_SSH_OPTS variable.
set -eu

# Sampling command, run on the router (a single line, no double quote).
# Sampled process: the Asterisk daemon (started with -f), never a transient "asterisk -rx"
# console (rut360gw-cli, web interface), which pidof may list first.
PROBE=$(cat <<'EOF'
PATH=$PATH:/usr/local/usr/sbin:/usr/local/sbin; P=0; for p in $(pidof asterisk); do tr '\000' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q ' -f ' && P=$p; done; if [ ${P:-0} -gt 0 ]; then R=$(awk '/VmRSS/{print $2}' /proc/$P/status); T=$(awk '/Threads/{print $2}' /proc/$P/status); F=$(ls /proc/$P/fd | wc -l); D=$(rut360gw-cli 'quectel show devices' | awk '$1~/^eg06$/{print $3}'); C=$(rut360gw-cli 'core show channels count' | sed -n 's/^\([0-9]*\) active call.*/\1/p'); else R=0; T=0; F=0; D=DOWN; C=0; fi; M=$(awk '/MemAvailable/{print $2}' /proc/meminfo); U=$(df -k /tmp | awk 'NR==2{print $3}'); W=$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p'); G=$(ping -c 1 -W 3 1.1.1.1 | sed -n 's/.*time=\([0-9.]*\).*/\1/p'); H=$(wg show wg_vps latest-handshakes | awk '{print $2}'); N=$(date +%s); echo $N,$(cut -d. -f1 /proc/uptime),${P:-0},$R,$T,$F,$M,$U,$(cut -d' ' -f1 /proc/loadavg),${D:-?},${C:-0},$(gsmctl -j),$(gsmctl -t),$(gsmctl -v),${W:-?},${G:-LOST},$((N-${H:-0}))
EOF
)

HEAD="hub_epoch,ssh,epoch,uptime_s,ast_pid,ast_rss_kb,ast_threads,ast_fds,memavail_kb,tmp_used_kb,load1,modem,channels,data,techno,volte,wan_dev,ping_ms,wg_age_s"

case "${1:-}" in
probe)
	printf '%s\n' "$PROBE"
	;;
run)
	TARGET=${2:?SSH target}; OUT=${3:?CSV file}; IV=${4:-120}; HOURS=${5:-48}
	CM="${OUT%.csv}.cm"
	# reused connection: a single authentication as long as the link holds (fewer lines
	# in the router log), then automatic reconnection at the next sample
	OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlMaster=auto -o ControlPath=$CM -o ControlPersist=600 ${SOAK_SSH_OPTS:-}"
	[ -f "$OUT" ] || echo "$HEAD" > "$OUT"
	END=$(( $(date +%s) + HOURS * 3600 ))
	while [ "$(date +%s)" -lt "$END" ]; do
		T0=$(date +%s)
		# shellcheck disable=SC2086
		if L=$(timeout 60 ssh $OPTS "$TARGET" "$PROBE" 2>/dev/null) && [ -n "$L" ]; then
			echo "$T0,ok,$L" >> "$OUT"
		else
			echo "$T0,FAIL" >> "$OUT"
		fi
		S=$(( IV - ($(date +%s) - T0) )); [ "$S" -gt 0 ] && sleep "$S"
	done
	# shellcheck disable=SC2086
	ssh $OPTS -O exit "$TARGET" 2>/dev/null || true
	;;
report)
	F=${2:?CSV file}
	# Two passes. The first one spots "spurious" samples: PID different from both
	# neighbours while these are identical (asterisk -rx console sampled instead of the
	# daemon, with older versions of the probe). They are excluded from the Asterisk
	# statistics and do not count as restarts.
	awk -F, '
	NR == FNR { if (FNR > 1 && $2 == "ok") { k++; idx[FNR] = k; pid[k] = $5 } next }
	FNR == 1 { for (i = 2; i < k; i++) if (pid[i] != pid[i-1] && pid[i-1] == pid[i+1]) glitch[i] = 1; next }
	{ n++; if (t0 == "") t0 = $1; t1 = $1 }
	$2 != "ok" { fail++; next }
	{
		# router, modem and links: all successful samples
		ok++
		if (ok == 1) { up0 = $4; mamin = $9 }
		if ($4 < up0) reboot++; up0 = $4
		if ($9 < mamin) mamin = $9
		if ($12 != "Free" && $13 == 0) nf++
		if ($13 > 0) busy++
		if ($14 != "Connected") nd++
		if ($18 == "LOST") pl++
		if ($17 != prevwan && prevwan != "") wan++; prevwan = $17; wans[$17]++
		if ($19 > 180) wg++
		ma1 = $9; last = $0
	}
	glitch[idx[FNR]] { gl++; next }
	{
		# Asterisk: spurious samples excluded
		if (r0 == "") { r0 = $6; p0 = $5; rmin = $6; rmax = $6; fd0 = $8 }
		if ($6 > rmax) rmax = $6; if ($6 < rmin) rmin = $6
		if ($5 != p0) pc++; p0 = $5
		r1 = $6; fd1 = $8
	}
	END {
		printf "duration: %.1f h; samples: %d (successful %d, SSH failed %d)\n", (t1 - t0) / 3600, n, ok, fail
		if (gl) printf "spurious Asterisk samples (asterisk -rx console), excluded: %d\n", gl
		printf "Asterisk RSS: start %d KiB, end %d KiB, min %d, max %d (drift %+d KiB)\n", r0, r1, rmin, rmax, r1 - r0
		printf "Asterisk fds: start %d, end %d; available RAM: min %d MiB, end %d MiB\n", fd0, fd1, mamin / 1024, ma1 / 1024
		printf "restarts: Asterisk %d, router %d\n", pc, reboot
		printf "modem not ready outside a call: %d; samples during a call: %d\n", nf, busy
		printf "data not Connected: %d; Internet pings lost: %d; tunnel without handshake > 180 s: %d\n", nd, pl, wg
		printf "Internet uplink changes: %d (", wan; for (w in wans) printf " %s=%d", w, wans[w]; print " )"
		print "last sample: " last
	}' "$F" "$F"
	;;
*) echo "usage: $0 probe | run <target> <csv> [interval_s] [hours] | report <csv>" >&2; exit 2 ;;
esac
