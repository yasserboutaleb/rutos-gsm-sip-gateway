#!/usr/bin/env python3
"""prune.py — rut360gw embedded runtime (called by build/runtime/assemble.py).
After-the-fact equivalent of --as-needed, for "sstripped" ELF files (no section headers,
which patchelf rejects): removes from an ELF every DT_NEEDED whose library provides NONE of
that ELF's undefined symbols. libc and libgcc_s are always kept.
Why: pjproject and Asterisk are linked without --as-needed (their -l flags come before it), hence
dependencies that are never used (pjsua, pjsua2 and its C++ library, audiodev, OpenSSL...).
The dynamic table (PT_DYNAMIC) is rewritten in place: remaining entries keep their order and are
padded with DT_NULL. No address moves.
Usage: prune.py <root> <system lib dir>..."""
import os, struct, subprocess, sys

root, sysdirs = sys.argv[1], sys.argv[2:]
KEEP = {"libc.so", "libgcc_s.so.1"}


def syms(path):
    """(defined, global undefined) from the dynamic table (readelf -D: no sections needed)."""
    out = subprocess.run(["readelf", "-D", "-s", "-W", path], capture_output=True, text=True).stdout
    defined, undef = set(), set()
    for line in out.splitlines():
        f = line.split()
        if len(f) < 8 or not f[0].endswith(":") or f[0] == "Num:":
            continue
        name = f[7].split("@")[0]
        if not name:
            continue
        if f[6] == "UND":
            if f[4] == "GLOBAL":
                undef.add(name)
        else:
            defined.add(name)
    return defined, undef


class Elf:
    def __init__(self, path):
        self.path = path
        self.d = bytearray(open(path, "rb").read())
        d = self.d
        assert d[:4] == b"\x7fELF" and d[4] == 1, "ELF32 expected"
        self.e = ">" if d[5] == 2 else "<"
        phoff, = struct.unpack_from(self.e + "I", d, 28)
        phentsize, phnum = struct.unpack_from(self.e + "HH", d, 42)
        self.loads, self.dyn = [], None
        for i in range(phnum):
            t, off, vaddr, _, filesz, _, _, _ = struct.unpack_from(self.e + "8I", d, phoff + i * phentsize)
            if t == 1:
                self.loads.append((vaddr, off, filesz))
            elif t == 2:
                self.dyn = (off, filesz)
        self.entries = []
        if self.dyn:
            off, size = self.dyn
            for j in range(size // 8):
                tag, val = struct.unpack_from(self.e + "iI", d, off + 8 * j)
                self.entries.append((tag, val))
                if tag == 0:
                    break
        strtab = [v for t, v in self.entries if t == 5]
        self.stroff = self.v2o(strtab[0]) if strtab else None

    def v2o(self, va):
        for vaddr, off, filesz in self.loads:
            if vaddr <= va < vaddr + filesz:
                return off + va - vaddr
        raise ValueError("address outside any segment")

    def name(self, v):
        s = self.d[self.stroff + v:]
        return s[:s.index(0)].decode()

    def needed(self):
        return [self.name(v) for t, v in self.entries if t == 1]

    def remove(self, libs):
        new = [(t, v) for t, v in self.entries if not (t == 1 and self.name(v) in libs)]
        n = len(self.entries) - len(new)
        new += [(0, 0)] * n
        off, _ = self.dyn
        for j, (t, v) in enumerate(new):
            struct.pack_into(self.e + "iI", self.d, off + 8 * j, t, v)
        open(self.path, "wb").write(self.d)
        return n


def find(lib):
    for d in [os.path.join(root, "usr/lib"), os.path.join(root, "lib"), *sysdirs]:
        p = os.path.join(d, lib)
        if os.path.exists(p):
            return os.path.realpath(p)
    return None


def is_elf(p):
    try:
        with open(p, "rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


cache, removed = {}, 0
for d, _, files in os.walk(root):
    for n in sorted(files):
        p = os.path.join(d, n)
        if os.path.islink(p) or not is_elf(p):
            continue
        elf = Elf(p)
        if not elf.dyn:
            continue
        _, und = syms(p)
        drop = []
        for lib in elf.needed():
            lp = find(lib)
            if lib in KEEP or lp is None:
                continue
            if lp not in cache:
                cache[lp] = syms(lp)[0]
            if not (und & cache[lp]):
                drop.append(lib)
        if drop:
            removed += elf.remove(set(drop))
            print(f"removed: {' '.join(drop)} from {os.path.relpath(p, root)}")
print(f"== unused links removed: {removed}")
