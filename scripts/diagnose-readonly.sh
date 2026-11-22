#!/bin/sh
# STRICTLY read-only diagnostics for RUT360 (RutOS 7.x) + Quectel EG06.
# Usage (from the workstation):
#   ssh root@192.168.2.1 'sh -s' < scripts/diagnose-readonly.sh > diag.txt
# No write, no reboot, no configuration AT command.
# Identifiers (IMEI/ICCID/IMSI/phone numbers) are masked in the output.

redact() { sed -E \
	-e 's/([Ii][Cc][Cc][Ii][Dd][^0-9]*)[0-9A-Fa-f]{18,22}/\1<ICCID>/g' \
	-e 's/[0-9]{15}/<15DIGITS>/g' \
	-e 's/\+?[0-9]{9,14}/<NUM>/g' \
	-e "s/(pincode|puk|password|username|private_key|preshared_key)='[^']*'/\1='<REDACTED>'/g"; }

at() { printf '\n>> %s\n' "$1"; gsmctl -A "$1" 2>&1; }

{
printf '=== FIRMWARE ===\n'
cat /etc/openwrt_release /etc/version 2>/dev/null
ubus call system board 2>/dev/null
uname -a

printf '\n=== RESOURCES ===\n'
free; df -h; cat /proc/mtd
mount | grep -E 'overlay|squash|jffs|tmpfs'

printf '\n=== USB / PORTS ===\n'
for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] && echo "$d $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"; done
for i in /sys/bus/usb/devices/*:*; do
	echo "$i class=$(cat $i/bInterfaceClass) drv=$(basename "$(readlink $i/driver)" 2>/dev/null) $(ls $i 2>/dev/null | grep -E 'tty|net|usbmisc|sound' | tr '\n' ' ')"
done
ls -l /dev/ttyUSB* /dev/cdc-wdm* /dev/snd/* 2>/dev/null
cat /proc/asound/cards 2>/dev/null
printf '\n-- processes holding the modem ports --\n'
for p in /proc/[0-9]*; do for f in $p/fd/*; do t=$(readlink "$f" 2>/dev/null)
	case "$t" in /dev/ttyUSB*|/dev/cdc-wdm*) echo "$(basename $p) $(cat $p/comm) -> $t";; esac
done; done

printf '\n=== MODEM (read-only, via gsmd) ===\n'
for c in 'ATI' 'AT+QGMR' 'AT+QCFG="usbcfg"' 'AT+QPCMV=?' 'AT+QPCMV?' 'AT+QCFG="ims"' \
	'AT+QURCCFG="urcport"' 'AT+CEREG?' 'AT+COPS?' 'AT+QNWINFO' 'AT+QCFG="nwscanmode"' \
	'AT+QAUDMOD?' 'AT+QDAI?' 'AT+CMGF?' 'AT+CPMS?' 'AT+CNMI?' 'AT+QMBNCFG="select"' \
	'AT+QCFG="servicedomain"' 'AT+CLCC' 'AT+QINDCFG="all"'; do at "$c"; done
printf '\n>> VoLTE (gsmctl -v)\n'; gsmctl -v 2>&1
printf '>> technology (gsmctl -t)\n'; gsmctl -t 2>&1
printf '>> signal\n'; gsmctl -q 2>&1
printf '>> temperature x0.1C\n'; gsmctl -c 2>&1

printf '\n=== RUTOS SERVICES RELATED TO THE MODEM ===\n'
ps w | grep -E 'gsmd|mobifd|modem_trackd|qmuxtrack|call_utils|sms|asterisk|rut360gw' | grep -v grep
uci show call_utils 2>/dev/null
uci show simcard 2>/dev/null

printf '\n=== NETWORK ===\n'
ip -br addr; ip route
wg show interfaces 2>/dev/null

printf '\n=== SOFTWARE ===\n'
opkg list-installed 2>/dev/null | grep -i -E 'asterisk|alsa|pj|uclibcxx|jansson|xml2|edit|sqlite|wireguard|rut360gw'
} 2>&1 | redact
