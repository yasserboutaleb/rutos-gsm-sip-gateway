# Architecture

## Overview

```
 softphone ──SIP──► SIP server (Asterisk, FreePBX...)            RUT360 (RutOS 7.14.5)
                      │                                          ┌──────────────────────────────┐
                      │  register: gateway registers (4G NAT)    │ Asterisk 18 (RAM)            │
                      └──────────── or ip: over a VPN ──────────►│  chan_pjsip ◄─► dialplan     │
                                                                 │                 ▲            │
 softphone on the LAN ──SIP (optional)──────────────────────────►│                 │            │
                                                                 │  chan_quectel (patched)      │
                                                                 │   │ USB if 3: AT (calls)     │
                                                                 │   │ USB if 1: serial PCM     │
                                                                 │   ▼                          │
                                                                 │ Quectel EG06-E ◄── gsmd ─────┤ RutOS
                                                                 └──────┬───────────────────────┘ (if 2: AT, URC,
                                                                        │ LTE / VoLTE / 3G / 2G      SMS, USSD, data)
                                                                        ▼
                                                                  mobile network
```

RutOS remains the owner of the modem. `gsmd` keeps the main AT port, unsolicited result codes
(URCs), SMS, USSD and mobile data. The gateway adds a voice path beside it and goes through
`gsmd` for SMS and USSD.

## Components

| Component | Role |
|---|---|
| RutOS `gsmd` / `mobifd` | Modem owner: main AT port (USB interface 2), URCs, SMS storage, USSD, QMI data, Call Utilities. |
| Asterisk 18.15.1 (`rut360gw-runtime`) | SIP stack (`chan_pjsip`, pjproject 2.12.1) and dialplan. It is rebuilt without OpenSSL, shipped as an archive in flash and extracted to RAM at every start. |
| `chan_quectel` (patched) | GSM call driver: call control on USB interface 3, voice as serial PCM on USB interface 1. |
| `rut360gw-config` | Validates `/etc/config/rut360gw`, finds the modem's serial ports by USB interface number, and generates the Asterisk configuration in RAM from templates. |
| `rut360gw-runtime` (script) | Checks (SHA-256) and extracts the embedded runtime. Fallback: downloads the official OpenWrt 21.02 packages. |
| `rut360gw-sms` (Lua) | SMS <-> SIP bridge daemon, SIM purge, USSD (from SIP and from the web page), JSON for the web page's SMS/USSD methods. Uses `gsmctl` and the `gsmd` ubus API, never an AT port. |
| `rut360gw-rutos` | Aligns the RutOS settings the gateway needs and restores them on removal. |
| `rut360gw-fw` | LAN firewall rules: SIP rate limit, and anti-spoofing in `ip` mode. |
| `rut360gw-watchdog` | Restarts Asterisk if the modem device stays missing, uninitialised or stuck. |
| `rut360gw-check` | Read-only self-test. |
| `rut360gw-cli` | Asterisk console of the RAM runtime. |
| procd service `rut360gw` | Instances `asterisk`, `watchdog`, `smsbridge`, and `runtime` (only while the runtime is being prepared by the fallback). |
| Web page + rpcd plugin | `http://<router>/rut360gw/` -> ubus object `rut360gw` (rpcd plugin with its own ACL) -> UCI + `rut360gw-config`. |

## Files on the router

RutOS 7.14 installs packages under **`/usr/local`**, because its root filesystem is read-only.
The scripts detect this prefix at run time, so the same package also runs on plain OpenWrt,
which the test bench uses.

| Path | Content |
|---|---|
| `/etc/config/rut360gw` | The only configuration file (UCI, mode 600, contains the passwords). Kept on uninstall. |
| `/etc/init.d/rut360gw` | procd service (START=99). |
| `/etc/rut360gw/` | Local state, mode 700, kept across firmware upgrades: `rutos.orig` (original RutOS values), `sms.seen` (SMS already relayed, 500 entries maximum), optional `mirrors` (fallback download mirrors). |
| `/usr/local/usr/sbin/rut360gw-*` | The scripts above. |
| `/usr/local/usr/share/rut360gw/templates/` | Asterisk configuration templates (`pjsip.conf`, `extensions.conf`, `quectel.conf`...). |
| `/usr/local/usr/share/rut360gw/modules/chan_quectel.so` | The driver, copied into the runtime at start. |
| `/usr/local/usr/share/rut360gw/runtime.tar.gz` (+ `.sha256`) | Embedded runtime (package `rut360gw-runtime`). |
| `/usr/local/usr/share/rut360gw/bundle.manifest` | SHA-256 list of the fallback OpenWrt packages. |
| `/usr/local/usr/share/rut360gw/SHA256SUMS` | Checksums of the files delivered by the package. |
| `/usr/local/www/rut360gw/` | Web page (`index.html`, `app.js`, `app.css`). |
| `/usr/local/usr/libexec/rpcd/rut360gw`, `/usr/local/usr/share/rpcd/acl.d/rut360gw.json` | API of the web page and its ACL. |
| `/tmp/rut360gw/root/` | **Runtime in RAM**: Asterisk, its modules and libraries (about 4.4 MB). |
| `/tmp/rut360gw/var/lib/asterisk/` | Asterisk database (RAM). |
| `/var/run/rut360gw/etc/` | **Generated Asterisk configuration** (RAM, umask 077), rebuilt at every start. |
| `/var/run/rut360gw/` | Asterisk control socket, runtime state, watchdog state. |

Nothing is written to flash during normal operation. Logs go to the RutOS log in RAM.

## How chan_quectel coexists with gsmd

The EG06-E exposes several USB interfaces in its factory composition:

| Interface | Owner | Use |
|---|---|---|
| 0 | none | Diagnostics (DM). |
| 1 (NMEA) | **rut360gw** | Voice as serial PCM, 8 kHz / 16-bit (`AT+QPCMV=1,0`). |
| 2 (AT) | **RutOS gsmd** | Main AT port and all URCs. **Never opened by rut360gw.** |
| 3 (AT) | **rut360gw** | Secondary AT port: `ATD`, `ATA`, `AT+QHUP`, `AT+CLCC` polling. |
| 4 | RutOS | QMI mobile data. |

`ttyUSBn` numbering is not guaranteed after a USB re-enumeration, so `rut360gw-config` finds
the ports by interface number. Interface 2 is refused by the configuration validator.

The patch adds four driver options. They are all set in the generated `quectel.conf`:

| Option | Effect |
|---|---|
| `sms = off` | The driver does not touch SMS. They stay owned by RutOS. |
| `urc_cfg = off` | The driver does not change `+QINDCFG`, a modem-wide setting: URCs keep going to `gsmd`. |
| `shared_cfg = off` | The driver does not change modem-wide settings owned by `gsmd`: `CSCS`, `CMEE`, `CSSN`, `VTD`, `COPS`, `CREG`, `CEREG`, `QTONEDET`. |
| `clcc_poll = 1000` | Call tracking by polling `AT+CLCC` every second. The driver never sees `RING` or call-state URCs, because they go to `gsmd`. |

In addition, the driver:

- does not reset the modem (`resetmodem = no`, no `ATZ`);
- does not change call waiting on the operator side;
- treats `+CME ERROR:` as a final response.

Using serial PCM voice means the USB composition never has to change, which could interrupt
4G, and no kernel sound module is needed. When the service stops, serial voice is switched off
again (`AT+QPCMV=0,0`).

### Call tracking by polling

Because URCs belong to `gsmd`, the driver infers every call state from `AT+CLCC`:

- **Incoming call**: a new ringing line appears in the poll.
- **End of call**: the call is absent from two consecutive polls.
- **Outgoing call index**: it is known only once `AT+CLCC` lists the call. The call has 10 s
  to appear after `ATD` is accepted, because without VoLTE the switch to 3G delays it.
  Until then, the driver never sends a provisional index to the modem.
- **Hang-up**: `AT+QHUP=<cause>,<index>`. A call not listed yet is hung up with `AT+CHUP` if it
  is the only one. If the modem refuses the hang-up and keeps the call, the driver hangs up
  again every 3 s, alternating `AT+CHUP` and `AT+QHUP`.
- **Unknown call**: any call the modem lists but the driver does not know is hung up, because
  nobody is on the SIP side. This happens, for example, after Asterisk restarts during a call.
- **Reused index**: the modem gives a new call the index of the previous one as soon as that
  call ends. A line with a known index but another direction or state is treated as a new
  call.
- **Serial voice refused** (`NoVoice`): the modem refuses `AT+QPCMV` during a call. The driver
  retries every 5 s once no call is in progress.
- **Modem reset**: if `AT+QPCMV?` is refused at initialisation, a new initialisation is
  scheduled every 15 s, at most 20 times.

## Call flows

**Incoming GSM call**

1. The network rings the EG06-E.
2. The driver sees the call in `AT+CLCC` and starts the `from-gsm` context.
3. The gateway dials the destinations of `features.gsm_in`:
   - `PJSIP/<server.extension>@server`, with the caller number as the display name and in
     `P-Asserted-Identity` in `register` mode;
   - and/or the LAN client.
4. The GSM call is answered (`ATA`) only when the SIP side answers.
5. If the SIP side is unreachable, congested or busy, the call is rejected with cause 17 (busy,
   `AT+QHUP=17`). After 60 s with no answer, it is a normal hang-up.

RutOS Call Utilities must not have an `action` set, or `mobifd` hangs the call up first.
See [INSTALL.md](INSTALL.md#rutos-settings-changed-by-the-gateway).

**Outgoing call**

1. The server (context `from-server`) or the LAN client (context `from-sip`) sends an
   `INVITE` to a number.
2. The gateway runs `Dial(Quectel/eg06/<number>)`, which sends `ATD` on interface 3.
3. Early media carries the network's ringback and announcements, or a locally generated tone
   with `features.ringback=local`.

**Call in progress**

- Audio: RTP (G.711) <-> Asterisk <-> serial PCM on interface 1.
- 60 s without RTP on an answered call means a hang-up (`rtp_timeout`).
- When the call ends, the gateway writes one event line to the log (`rut360gw-call`):
  direction, masked number, result and talk time.

## SMS and USSD flows

**Received SMS -> SIP**

1. `gsmd` stores the SMS on the SIM.
2. The `rut360gw-sms` daemon lists the SMS every 10 s (`gsmctl -S -l all`). Each new,
   complete SMS is stored in the Asterisk database: text in base64, sender filtered. The
   Asterisk console ignores a command longer than 512 bytes, so the text goes in pieces of
   400 base64 characters, 10 at most (3000 bytes of text; a longer text is truncated and
   marked `[truncated]`). Every write is checked.
3. The daemon starts the `sms-to-sip` context, which joins the pieces. An empty text is never
   sent: the attempt fails and the SMS stays on the SIM. The `msg-to-sip` context sends a
   `MESSAGE` to `server.extension` on the server, or to the LAN client when no server is
   enabled.
4. If the `MESSAGE` succeeds, the SMS is recorded in `/etc/rut360gw/sms.seen`. If
   `features.sms_purge=1`, it is deleted from the SIM after `sms_purge_delay` seconds. The
   delay leaves time for RutOS e-mail forwarding.
5. If it fails, the bridge tries again, up to 5 attempts, and the SMS stays on the SIM.

The bridge never relays or purges the SMS already present when it first starts.

**SIP -> SMS**

1. A `MESSAGE` to a number arrives from the server or the LAN client, in the `sms-out`
   context.
2. The number is filtered (digits and `+`) and the text is base64-encoded.
3. `rut360gw-sms send` validates the number again and sends the SMS with `gsmctl -S -s`.
4. If sending fails, a `MESSAGE` *"SMS to <number> could not be sent"* goes back to the
   sender.

**USSD from SIP**

1. The server sends an `INVITE` to `*code#`.
2. The gateway filters the code, answers with a short beep and hangs up.
3. In the background, `rut360gw-sms ussd` sends the request through the `gsmd` ubus API
   (`set_ussd`) and waits up to 45 s for the reply written by `gsmd`. UCS-2 replies are
   decoded.
4. The reply is sent as a `MESSAGE` from `ussd` to `server.extension`.

Only one request runs at a time, and requests are refused during a GSM call, because USSD can
force a 2G/3G fallback.

**USSD from the web page**: the same path, with an interactive session (code, then menu
answers). The history is kept in RAM (40 entries).

## Startup sequence

1. procd starts `/etc/init.d/rut360gw` (START=99). Nothing happens while `main.enabled=0`.
2. Runtime:
   - The embedded archive is checked and extracted to `/tmp/rut360gw/root`, without network.
     15 MB of available RAM is required.
   - If that fails, a `runtime` instance prepares the runtime in the background (fallback
     download) and retries every 2 minutes, without limit. It reports its state as
     `waiting_network` or `low_memory`, then restarts the service. The router's boot is never
     blocked.
3. `rut360gw-config generate` writes the Asterisk configuration to `/var/run/rut360gw/etc`.
   The service stops there if the configuration is invalid.
4. `rut360gw-fw apply` updates the LAN firewall rules, only if they changed.
5. `rut360gw-rutos align` aligns the RutOS settings (if `main.manage_rutos=1`). Remaining
   problems are logged as warnings.
6. procd starts Asterisk (respawn up to 5 times per hour), the watchdog, and the SMS bridge.
7. `chan_quectel` opens interfaces 1 and 3, enables serial voice and starts polling
   `AT+CLCC`.

A change to `/etc/config/rut360gw` followed by `rut360gw-config apply` regenerates the
configuration and restarts the service.

## Design decisions

| Decision | Why |
|---|---|
| Serial PCM voice instead of USB audio (UAC) | No USB composition change, which could cut 4G, and no kernel sound module. |
| Asterisk extracted to RAM | The RUT360 has only a few MB of free flash. |
| Reduced runtime without OpenSSL, in its own package | Starts without Internet, takes 1.8 MB in flash and 4.4 MB in RAM, instead of 10.7 MB for the official packages. In a separate package, because opkg refuses an upgrade larger than the free space without deducting the installed version: inside `rut360gw`, it would block every update. The trade-off is that there is no TLS or SRTP. |
| Polling `AT+CLCC` | URCs are routed to `gsmd`, and changing that would break RutOS. |
| SMS and USSD through `gsmd` | A single owner, so there is no conflict on the SIM and RutOS features keep working. |
| One configuration file, generated Asterisk configuration | Settings are validated in one place, and the generated files are rebuilt at every start, so they cannot drift. |
