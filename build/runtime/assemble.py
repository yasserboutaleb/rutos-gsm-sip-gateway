#!/usr/bin/env python3
"""assemble.py — assembles the rut360gw embedded runtime ("runtime" stage of ci/run-local.sh).

Inputs:
  --ipk      packages built by build/runtime/build.sh (asterisk*, libpj*: without OpenSSL)
  --bundle   OFFICIAL bundle packages (sha256-checked by the fetch stage): dependencies that are
             not rebuilt (libedit, jansson, libuuid...); their asterisk* and libpj* are ignored
  --stubs    compiled stub libraries (libxml2.so.2, libasound.so.2, libncursesw.so.6)
  --chan     chan_quectel.so: used to compute dependencies, but NOT put in the archive
             (the rut360gw package ships it)
  --modules  the package's modules.conf: asterisk + these modules = starting point of the closure
  --rootfs   filesystem of each supported firmware (libraries provided by RutOS)
Steps: extraction, removal of unused dependencies (prune.py), stubs, dependency closure,
BLOCKING symbol check (every imported symbol must be defined, for every firmware), then a
reproducible tar.gz archive (fixed order, owner 0, fixed date).
"""
import argparse, gzip, hashlib, io, os, re, shutil, subprocess, sys, tarfile, tempfile

ap = argparse.ArgumentParser()
ap.add_argument("--ipk", required=True)
ap.add_argument("--bundle", required=True)
ap.add_argument("--stubs", required=True)
ap.add_argument("--chan", required=True)
ap.add_argument("--modules", required=True)
ap.add_argument("--rootfs", action="append", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--report", required=True)
ap.add_argument("--epoch", type=int, default=0)
a = ap.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__))
errors = []
log = []


def say(msg):
    print(msg)
    log.append(msg)


def fail(msg):
    say("ERROR: " + msg)
    errors.append(msg)


def extract_ipk(path, dest):
    """OpenWrt 21.02 .ipk = tar.gz containing data.tar.gz"""
    with tarfile.open(path, "r:gz") as outer:
        data = outer.extractfile("./data.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as inner:
        inner.extractall(dest)


def needed(path):
    out = subprocess.run(["readelf", "-d", "-W", path], capture_output=True, text=True).stdout
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", out)


def dynsyms(path):
    """(defined, global undefined) from the dynamic table: readelf -D, as OpenWrt binaries
    have no section headers."""
    out = subprocess.run(["readelf", "-D", "-s", "-W", path], capture_output=True, text=True).stdout
    d, u = set(), set()
    for line in out.splitlines():
        f = line.split()
        if len(f) < 8 or not f[0].endswith(":") or f[0] == "Num:":
            continue
        name = f[7].split("@")[0]
        if not name:
            continue
        if f[6] == "UND":
            if f[4] == "GLOBAL":
                u.add(name)
        else:
            d.add(name)
    return d, u


def is_elf(p):
    try:
        with open(p, "rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


W = tempfile.mkdtemp(prefix="rt-")
R = os.path.join(W, "root")
os.makedirs(R)

# 1. rebuilt packages, then official dependencies (except what was rebuilt)
ipks = sorted(f for f in os.listdir(a.ipk) if f.endswith(".ipk"))
if not any(f.startswith("asterisk_") for f in ipks):
    fail("asterisk_*.ipk missing from " + a.ipk)
for f in ipks:
    extract_ipk(os.path.join(a.ipk, f), R)
deps = sorted(f for f in os.listdir(a.bundle) if f.endswith(".ipk") and not f.startswith(("asterisk", "libpj")))
for f in deps:
    extract_ipk(os.path.join(a.bundle, f), R)
say(f"packages: {len(ipks)} rebuilt, {len(deps)} official (dependencies)")
MODDIR = os.path.join(R, "usr/lib/asterisk/modules")
shutil.copyfile(a.chan, os.path.join(MODDIR, "chan_quectel.so"))

# 2. never-used dependencies removed from the binaries
r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "prune.py"), R,
                    os.path.join(a.rootfs[0], "usr/lib"), os.path.join(a.rootfs[0], "lib")],
                   capture_output=True, text=True)
if r.returncode:
    fail("prune.py: " + r.stderr.strip())
say(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "prune.py: no output")

# 3. stubs in place of the real libraries (same name, content replaced)
for s in sorted(os.listdir(a.stubs)):
    t = os.path.realpath(os.path.join(R, "usr/lib", s))
    if not t.startswith(R + os.sep) or not os.path.isfile(t):
        fail(f"stub {s}: original library missing from the runtime")
        continue
    shutil.copyfile(os.path.join(a.stubs, s), t)
    say(f"stub: {s} -> {os.path.relpath(t, R)} ({os.path.getsize(t)} B)")


# 4. dependency closure, starting from asterisk and the loaded modules
def in_root(name):
    for d in ("usr/lib", "lib"):
        p = os.path.join(R, d, name)
        if os.path.lexists(p):
            return p
    return None


def in_sys(rootfs, name):
    for d in ("usr/lib", "lib"):
        p = os.path.join(rootfs, d, name)
        if os.path.exists(p):
            return os.path.realpath(p)
    return None


mods = re.findall(r"^load\s*=>\s*(\S+\.so)", open(a.modules).read(), re.M)
queue = [os.path.join(R, "usr/sbin/asterisk")] + [os.path.join(MODDIR, m) for m in mods]
keep, sysnames, seen = set(), set(), set()
while queue:
    f = queue.pop(0)
    if f in seen:
        continue
    seen.add(f)
    if not os.path.exists(f):
        fail("module missing from the runtime: " + os.path.relpath(f, R))
        continue
    keep.add(f)
    for n in needed(f):
        p = in_root(n)
        if p:
            keep.add(p)
            queue.append(os.path.realpath(p))
        elif in_sys(a.rootfs[0], n):
            sysnames.add(n)
        else:
            fail(f"library not found: {n} (needed by {os.path.relpath(f, R)})")
real = sorted({os.path.realpath(p) for p in keep})
say(f"closure: {len(real)} ELF files, {len(mods)} modules; firmware libraries: {' '.join(sorted(sysnames))}")

# 5. symbol check, for EACH supported firmware (musl binds everything at load time:
#    a missing symbol prevents Asterisk or a module from loading)
cache = {}
for rootfs in a.rootfs:
    files = list(real)
    for n in sorted(sysnames):
        p = in_sys(rootfs, n)
        if not p:
            fail(f"{os.path.basename(rootfs)}: firmware library missing: {n}")
        else:
            files.append(p)
    defined, undef = set(), {}
    for f in files:
        if f not in cache:
            cache[f] = dynsyms(f)
        d, u = cache[f]
        defined |= d
        for s in u:
            undef.setdefault(s, f)
    missing = sorted(s for s in undef if s not in defined)
    if missing:
        fail(f"{os.path.basename(rootfs)}: {len(missing)} unresolved symbol(s): " +
             ", ".join(f"{s} ({os.path.relpath(undef[s], R) if undef[s].startswith(R) else undef[s]})" for s in missing[:20]))
    else:
        say(f"{os.path.basename(rootfs)}: {len(undef)} imported symbols, 0 unresolved")

# 6. archive content: kept files, their links, and indications.conf (read by rut360gw-config
#    and the web page for the tones of every country other than the built-in fr and dz)
members = set(os.path.relpath(p, R) for p in real)
for d, _, fs in os.walk(R):
    for n in fs:
        p = os.path.join(d, n)
        if os.path.islink(p) and os.path.realpath(p) in real:
            members.add(os.path.relpath(p, R))
IND = "etc/asterisk/indications.conf"
if os.path.isfile(os.path.join(R, IND)):
    members.add(IND)
else:
    fail(IND + " missing: rut360gw-config could no longer generate the tones of other countries")
members.discard("usr/lib/asterisk/modules/chan_quectel.so")
dirs = set()
for m in members:
    d = os.path.dirname(m)
    while d:
        dirs.add(d)
        d = os.path.dirname(d)

if errors:
    open(a.report, "w").write("\n".join(log) + "\n")
    sys.exit(f"assembly rejected: {len(errors)} error(s)")

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as t:
    for m in sorted(dirs | members):
        p = os.path.join(R, m)
        ti = t.gettarinfo(p, "./" + m)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        ti.mtime = a.epoch
        if ti.isdir():
            ti.mode = 0o755
        elif ti.isreg():
            ti.mode = 0o755 if is_elf(p) else 0o644
        if ti.isreg():
            with open(p, "rb") as fh:
                t.addfile(ti, fh)
        else:
            t.addfile(ti)
raw = buf.getvalue()
with open(a.out, "wb") as fo:
    with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=fo, mtime=0) as gz:
        gz.write(raw)
size = sum(os.path.getsize(os.path.join(R, m)) for m in members if not os.path.islink(os.path.join(R, m)))
sha = hashlib.sha256(open(a.out, "rb").read()).hexdigest()
say(f"archive: {len(members)} entries, {size // 1024} KiB extracted, tar {len(raw) // 1024} KiB, "
    f"gzip {os.path.getsize(a.out) // 1024} KiB, sha256 {sha}")
top = sorted(((os.path.getsize(os.path.join(R, m)), m) for m in members if not os.path.islink(os.path.join(R, m))), reverse=True)
log.append("largest files (KiB):")
log += [f"  {s // 1024:6d} {m}" for s, m in top[:15]]
open(a.report, "w").write("\n".join(log) + "\n")
shutil.rmtree(W)
