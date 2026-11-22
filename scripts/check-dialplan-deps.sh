#!/bin/sh
# check-dialplan-deps.sh — checks that every application and function used by
# extensions.conf is provided by a module LOADED in the RUT360 Asterisk
# (modules.conf uses autoload=no: a forgotten module silently breaks the dialplan).
# Read-only. Exit code = number of missing items.
set -eu
RUT_HOST=${RUT_HOST:-192.168.2.1}
RUT_KEY=${RUT_KEY:-$HOME/.ssh/id_ed25519}
ssh -i "$RUT_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$RUT_HOST" 'sh -s' <<'EOF'
A() { /usr/sbin/rut360gw-cli "$1" 2>/dev/null; }
X=/var/run/rut360gw/etc/extensions.conf
APPS=$(A "core show applications" | awk -F: 'NF>1{gsub(/ /,"",$1); print toupper($1)}')
FUNCS=$(A "core show functions" | awk 'NR>2{print toupper($1)}')
miss=0
# applications: first word after "exten => pattern,prio," or "same => n[(label)],"
for a in $( { grep -E '^\s*exten\s*=>' $X | sed -E 's/^[^,]*,[^,]*,//'; grep -E '^\s*same\s*=>' $X | sed -E 's/^[^,]*,//'; } | grep -o -E '^[A-Za-z]+' | sort -u); do
	echo "$APPS" | grep -q -x "$(echo $a | tr a-z A-Z)" && echo "ok    application $a" || { echo "MISSING application $a"; miss=$((miss+1)); }
done
# functions: ${NAME( ...
for f in $(grep -o -E '\$\{[A-Z][A-Z0-9_]+\(' $X | tr -d '${(' | sort -u); do
	echo "$FUNCS" | grep -q -x "$f" && echo "ok    function    $f" || { echo "MISSING function    $f"; miss=$((miss+1)); }
done
echo "Result: $miss missing item(s)"
exit $miss
EOF
