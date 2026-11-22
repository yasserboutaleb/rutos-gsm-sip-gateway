#!/bin/bash
# opkg-runtime-test.sh — free-space check of the rut360gw-runtime package with the RutOS FIRMWARE's
# own opkg, under qemu-mips (started by ci/run-local.sh, integration-rutos step).
# The package declares "Installed-Size: 0" and its preinst does the real check. Each scenario has its
# own tmpfs root, sized to leave the desired free space (under qemu-user, df does not see mounts made
# below the chroot root; it does see the root itself). Checks are run INSIDE the chroot (the RutOS
# rootfs contains absolute links).
# Container --privileged. Mounts: /fw (RutOS rootfs, read-only), /ipk (packages), /res (output)
set -u
apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq qemu-user-static >/dev/null 2>&1
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
[ -e /proc/sys/fs/binfmt_misc/qemu-mips ] && echo -1 > /proc/sys/fs/binfmt_misc/qemu-mips
echo ':qemu-mips:M::\x7fELF\x01\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x08:\xff\xff\xff\xff\xff\xff\xff\x00\xfe\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/usr/bin/qemu-mips-static:F' > /proc/sys/fs/binfmt_misc/register
RT=$(ls /ipk/rut360gw-runtime_*_mips_24kc.ipk | head -1)
NEW=$(tar -xzOf "$RT" ./control.tar.gz | tar -xzO ./preinst | sed -n 's/^NEW_KB=//p')
V=$(tar -xzOf "$RT" ./control.tar.gz | tar -xzO ./control | sed -n 's/^Version: //p')
V99=${V%-*}-99
# next version (same content) for the upgrade test
W=$(mktemp -d); (cd $W && tar -xzf "$RT" && mkdir c && tar -xzf control.tar.gz -C c && sed -i "s/^Version: .*/Version: $V99/" c/control \
	&& (cd c && tar -czf ../control.tar.gz ./*) && tar -czf /tmp/rt99.ipk ./debian-binary ./control.tar.gz ./data.tar.gz)
R=/r; mkdir -p $R
# new root: RutOS rootfs + exactly $1 KB free
root() {
	umount $R/proc 2>/dev/null; umount $R 2>/dev/null
	mount -t tmpfs -o size=200m tmpfs $R && cp -a /fw/. $R/ && cp /usr/bin/qemu-mips-static $R/usr/bin/
	cp "$RT" $R/tmp/rt2.ipk; cp /tmp/rt99.ipk $R/tmp/; mkdir -p $R/tmp/opkg-lists $R/var/lock
	printf 'dest t /\nlists_dir ext /tmp/opkg-lists\narch all 1\narch noarch 1\narch mips_24kc 10\n' > $R/tmp/opkg-t.conf
	mount -t proc proc $R/proc
	used=$(df -k $R | tail -1 | awk '{print $3}'); mount -o remount,size=$((used + $1))k $R
}
OP() { chroot $R /bin/opkg -f /tmp/opkg-t.conf -d t install "$1" > "/res/$2.out" 2>&1; echo $?; }
inr() { chroot $R /bin/sh -c "$1"; }
AR=/usr/share/rut360gw/runtime.tar.gz
# INSTALLED version (a "not-installed" entry left behind by a rejection does not count)
st() { inr "opkg -f /tmp/opkg-t.conf status rut360gw-runtime" 2>/dev/null | awk '/^Version:/ {v=$2} /^Status:.* installed/ && !/not-installed/ {print v}'; }
sum() { inr "sha256sum $AR 2>/dev/null" | cut -c1-16; }
libre() { df -k $R | tail -1 | awk '{print $4}'; }
P=0; F=0; ck() { if [ "$2" = ok ]; then echo "PASS  $1"; P=$((P+1)); else echo "FAIL  $1 ($2)"; F=$((F+1)); fi; }
echo "package $V, archive $NEW KB"

root $((NEW + 100)); l=$(libre); r=$(OP /tmp/rt2.ipk 1)
res=ok; [ "$r" != 0 ] || res="opkg rc=0"; grep -q 'not enough flash space' /res/1.out || res="$res, no message"
inr "test -e $AR" && res="$res, archive written"; [ -z "$(st)" ] || res="$res, state $(st)"
ck "first install, $l KB free: rejected by preinst, nothing written" "$res"

root $((NEW + 700)); l=$(libre); r=$(OP /tmp/rt2.ipk 2)
res=ok; [ "$r" = 0 ] || res="opkg rc=$r"; inr "test -s $AR" || res="$res, archive missing"; [ "$(st)" = "$V" ] || res="$res, state $(st)"
ck "first install, $l KB free: accepted" "$res"

l=$(libre); r=$(OP /tmp/rt99.ipk 3)
res=ok; [ "$r" = 0 ] || res="opkg rc=$r"; inr "test -s $AR" || res="$res, archive missing"; [ "$(st)" = "$V99" ] || res="$res, state $(st)"
ck "upgrade, $l KB free: accepted thanks to the old archive" "$res"
echo "   free after the upgrade: $(libre) KB"

root $((NEW + 300)); OP /tmp/rt2.ipk 4 >/dev/null; l=$(libre); s0=$(sum); r=$(OP /tmp/rt99.ipk 5)
res=ok; [ -n "$s0" ] || res="old version not installed"; [ "$r" != 0 ] || res="$res, opkg rc=0"
grep -q 'not enough flash space' /res/5.out || res="$res, no message"; [ "$(st)" = "$V" ] || res="$res, state $(st)"; [ "$(sum)" = "$s0" ] || res="$res, archive modified"
ck "upgrade, $l KB free: rejected, old version intact" "$res"

grep -h 'not enough flash space\|Aborting' /res/1.out /res/5.out | head -4
echo "Result: $P PASS / $F FAIL"
umount $R/proc; umount $R
