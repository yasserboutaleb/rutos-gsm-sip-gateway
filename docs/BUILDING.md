# Building from source

Everything is built and tested locally in Docker by one script, `ci/run-local.sh`. It needs no
CI service. Every input is downloaded from its official source and checked against a pinned
SHA-256.

## Requirements

- Linux x86-64, or Windows with Git Bash. The scripts are POSIX `sh`; run them from Git Bash
  on Windows.
- Docker. The test bench needs **privileged** containers, to register `qemu-mips` through
  `binfmt_misc`.
- About 3 GB of disk: the CI image, two OpenWrt SDK volumes and the download cache `dl/`.
- Internet access for the first run: OpenWrt SDK, package feeds and sources, RutOS firmware
  image.

## One-time preparation: RutOS root filesystem

The `runtime` and `integration-rutos` stages check the embedded runtime against the **real**
RutOS 7.14.5 root filesystem: libraries, symbols, opkg behaviour. Extract it once from the
official Teltonika firmware image:

```sh
sh build/extract-rutos-rootfs.sh RUT36X_R_00.07.14.5 <MD5 published by Teltonika>
```

The script:

1. downloads `RUT36X_R_00.07.14.5_WEBUI.bin` from Teltonika's firmware server;
2. refuses it if its MD5 differs from the one published on the Teltonika wiki
   (*RUT360 Firmware Downloads*);
3. extracts its squashfs into `dl/firmware/rootfs-7.14.5/`.

Nothing from the image is executed outside the emulated test bench.

## Running the CI

```sh
sh ci/install-hooks.sh          # once per clone: pre-commit hook
sh ci/run-local.sh              # all stages
sh ci/run-local.sh lint unit    # selected stages
```

The first full run takes a while: about 10 to 15 minutes, plus 20 to 30 minutes for the first
`runtime` stage, which builds the SDK feeds. Later runs reuse the Docker volumes and the
`dl/` cache and take a few minutes. The exit code is the number of failed stages. Results and
logs go to `out/ci/`.

| Stage | What it does |
|---|---|
| `fetch` | Downloads and checks (SHA-256) the OpenWrt 21.02.7 SDK, the `malta-be` root filesystem used by the bench, and the official OpenWrt 21.02 packages of the fallback runtime (`ci/inputs.sha256`, `bundle.manifest`). Cached in `dl/`. |
| `lint` | `sh -n` and `shellcheck -S error` on the shell scripts, `luac -p` on the Lua bridge, Python syntax, and `ci/check-webui.py`: web page ACL, no CDN, no inline script or style, no `innerHTML`. |
| `unit` | Self-test of the SMS/USSD bridge (`rut360gw-sms selftest`): base64, shell quoting, `gsmctl` parsing, USSD decoding, JSON, SIM purge rules. |
| `sources` | Copies the pinned chan_quectel sources (`third_party/chan_quectel`, never modified) and applies `patches/0001-chan_quectel-rutos-coexistence.patch` into `work/`. |
| `driver` | Builds `chan_quectel.so` with the OpenWrt 21.02.7 SDK (Docker volume `rut360-sdk`) against the official Asterisk 18 package. Also builds the two test shims of the bench. |
| `runtime` | Builds Asterisk 18.15.1 and pjproject 2.12.1 **without OpenSSL** (OpenWrt 21.02 recipes, patches in `build/runtime/patches/`, separate volume `rut360-sdk-runtime`). It then assembles the embedded runtime (`build/runtime/assemble.py`). The stage **fails** if any library or symbol is missing on the RutOS root filesystem. Output: `out/runtime/runtime.tar.gz` and the report `runtime.txt`. |
| `package` | Builds `rut360gw`, `rut360gw-runtime` and the WebUI archive **twice**. The SHA-256 sums must be identical. |
| `integration` | QEMU bench on a generic OpenWrt 21.02 root filesystem, with the **fallback** runtime (official packages). See [Test bench](#test-bench). |
| `integration-rutos` | The same bench on the extracted **RutOS 7.14.5** root filesystem, with the **embedded** runtime. A damaged archive must be refused. It then runs `tests/opkg-runtime-test.sh`: the firmware's own opkg installs and upgrades `rut360gw-runtime` on a simulated flash that is either too small or large enough, to test the free-space check. Skipped if no RutOS root filesystem is extracted. |
| `secrets` | Searches tracked files for secrets (private keys, WireGuard and age keys, literal passwords in UCI and Asterisk files, tokens). Patterns come from `ci/secret-patterns.txt`, or from the file named by `RUT360GW_SECRET_PATTERNS` (e.g. your own list kept outside the repository). |

The pre-commit hook works without Docker. It refuses settings and key files (`*.uci`, `*.env`,
`*.key`, `*.pub`), lines that match the sensitive patterns, and shell scripts with syntax
errors.

## Build outputs

| File | Use |
|---|---|
| `out/rut360gw_<version>_mips_24kc.ipk` | Scripts, web page, driver. For `opkg install`. |
| `out/rut360gw-runtime_<runtime version>_mips_24kc.ipk` | Embedded Asterisk runtime. A dependency of `rut360gw`. |
| `out/rut360gw_<version>_RUT36X_R_00.07.14.5.tar.gz` | **WebUI archive** for *System > Package Manager*. It contains both `.ipk` files and a Teltonika `main` manifest. |

The package version is `<x.y.z>-r<commit count>.g<commit>`. It increases with every commit,
because the Package Manager only accepts a strictly newer version. The runtime version is in
`build/runtime/VERSION`. Increase it whenever the runtime content changes: recipes, stubs,
`modules.conf` or dependencies. Otherwise the WebUI considers the runtime up to date and
skips it.

The packages can also be built directly, once the driver and the runtime exist:

```sh
CHAN_SO=out/chan_quectel.so RUNTIME_TGZ=out/runtime/runtime.tar.gz sh package/rut360gw/build-ipk.sh out
```

Without `RUNTIME_TGZ`, only `rut360gw` is built. It has no runtime dependency and then uses
the fallback download.

### WebUI archive format

The RutOS Package Manager refuses a bare `.ipk`. It expects a `tar.gz` containing:

- a `main` file with these fields:
  - `Package`, `Version`, `Router`, `Firmware`, `tlt_name`;
  - `ipk_file: <file.ipk>:<sha256>`, required by RutOS 7.14;
  - `ipk_deps: <file.ipk>:<sha256> ...`: packages installed before `ipk_file` in the same
    opkg command, which is how `rut360gw-runtime` is delivered;
- the listed `.ipk` files.

The SHA-256 is computed over `control.tar.gz` followed by `data.tar.gz`. `Firmware` must be
identical to the router's `/etc/version`, so the archive is produced for each version listed
in `package/rut360gw/FIRMWARES`.

## Reproducibility

The builds are reproducible: the same commit gives the same SHA-256 for every package.

- Packages: fixed file modes, sorted entries, owner 0, timestamps taken from the last commit,
  `gzip -n`.
- `out/runtime/runtime.tar.gz`: fixed order, owner 0, date of the last commit touching
  `build/runtime` or `modules.conf`.
- `chan_quectel.so`: pinned SDK and sources, so the build is identical from one run to the
  next.
- Checksums of the delivered files: `/usr/share/rut360gw/SHA256SUMS` in the package.

The `package` stage builds twice and compares the sums. To check a release, build the tagged
commit and compare your sums with the published ones.

### Embedded runtime details

Asterisk imports some functions from libraries it never calls in this configuration. The
runtime replaces those libraries with small stubs (`build/runtime/stubs/`):

| Stub | Replaces | Why it is safe |
|---|---|---|
| `xml2.c` | libxml2 | Used only for XML documentation, which is disabled at build time. |
| `asound.c` | ALSA | Used only by the driver's UAC mode. `uac = off` is fixed in `quectel.conf`. |
| `termcap.c` | ncurses termcap | Used for the line editing of the console (`asterisk -r`). It uses fixed VT100 sequences. |

musl resolves every symbol at load time. An incomplete stub therefore prevents Asterisk from
starting. It cannot break a call in progress, and the `runtime` stage detects it before
packaging. Enabling TLS, SRTP, UAC or an XML module requires revisiting the runtime.

## Test bench

`tests/run-qemu-test.sh` runs the real packages under `qemu-mips` (user-mode emulation) in a
privileged container. It needs no router, modem or SIP server.

It uses:

- **`tests/fake_eg06.py`**: a simulated EG06-E on pseudo-terminals. Like the real interface 3,
  it sends no URCs. It simulates calls in both directions, late listing, refused hang-ups,
  index reuse, `+CME ERROR`, refused `AT+QPCMV?` after a reset, and a call left open at
  startup. It also checks that global modem settings are never changed.
- **`tests/fake_registrar.py`**: a SIP server that requires digest authentication, like a
  PBX. It accepts `REGISTER`, presents incoming GSM calls (with the caller number in
  `P-Asserted-Identity`) and answers busy, receives authenticated `MESSAGE`s, and sends a call
  on the registered line and cancels it.
- **`tests/sip_client.py`**: a LAN SIP client: `REGISTER`, RTP echo on `600`, `MESSAGE` to the
  SMS bridge, SIP -> GSM call.

Scenarios covered include:

- installation and configuration generation in both modes, including refused values;
- firewall rules: order, idempotence, `lan_sip_limit=0`, a `lan` zone that rejects its input (UDP 5060 left closed), removal;
- the LAN client access list;
- the RTP timeout;
- busy rejection of incoming calls;
- dialplan module dependencies.

Two test shims (`tests/qemu-shim/`) work around `qemu-user` limits (`TIOCGEXCL`,
`getifaddrs()`). They are never installed on a router.

The bench does not cover the radio, real 4G/VoLTE behaviour or the modem's real serial audio.
Those can only be tested on hardware.
