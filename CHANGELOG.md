# Changelog

## 0.2.3: long SMS fix

The runtime is unchanged (18.15.1-4): the WebUI upgrade reinstalls only `rut360gw`, and the settings
are kept.

- **Long SMS and USSD replies relayed with an empty text.** The bridge handed the whole text to
  Asterisk in one console command (`asterisk -rx`). The console reads a command in a 512-byte
  buffer and silently ignores a longer one. Any SMS over about 336 bytes (about 290 Latin
  characters, or 150 Arabic ones) and any long USSD reply reached the SIP server with an empty text. The
  relay still counted as a success, so the SMS was then purged from the SIM, and only the RutOS
  e-mail forwarding kept its text. The text now goes in pieces of 400 base64 characters, and
  every write is checked. Texts up to 3000 bytes are relayed in full; a longer one is truncated
  and marked `[truncated]`. An empty text is never sent: the attempt fails and the SMS stays on
  the SIM. The bench relays a long Arabic SMS and USSD reply through the real Asterisk console.

## 0.2.2: firewall fix

The runtime is unchanged (18.15.1-4): the WebUI upgrade reinstalls only `rut360gw`, and the settings
are kept.

- **Firewall: UDP 5060 no longer opened on a closed LAN.** The `rut360gw_sip_lan` rule *accepts*
  SIP from the LAN up to `features.lan_sip_limit` packets/s. On a `lan` zone that rejects its
  input (a hardened LAN with untrusted hosts), it opened UDP 5060 to the LAN. It is now added only
  when the `lan` zone accepts its input (its own policy, otherwise the firewall default); elsewhere
  SIP from the LAN is left to the zone. A warning is logged at start when the LAN SIP client is
  enabled on such a zone. The RutOS default (`lan` input `ACCEPT`) is unchanged.

## 0.2.1: security fix

**Upgrade if the gateway uses a remote SIP server in `register` mode.** In 0.2.0, any host on the
LAN could pose as the server, without a password, and place GSM calls or send SMS at the SIM's
expense. `ip` mode and the LAN SIP client alone were not affected. The runtime is unchanged
(18.15.1-4): the WebUI upgrade reinstalls only `rut360gw`, and the settings are kept.

- **Remote server in `register` mode: spoofing from the LAN.** The `server` endpoint kept Asterisk's
  default identification (`username,ip`), so a LAN client sending `From: server` was taken for the
  server, without a password, and could call a GSM number or send an SMS. The server is now
  identified only by its address (`ip` mode) or by its registration line (`register` mode, the
  `line` parameter of the registered contact): `identify_by = ip` in both modes. The bench sends a
  spoofed call and SMS (refused) and an SMS from the real server on its line (accepted).
- **Only the filtered number reaches `Dial()`.** Calls from the LAN client or the SIP server passed
  `${EXTEN}` as is: a `&` added a destination and a `,` added options. The call is now refused when
  the number holds anything but digits and `+`. Only an authenticated caller could do this.
- **LAN SIP client named after its username.** The endpoint and AOR were called `linphone`, while
  the documentation has the softphone configured with `local.username` (default `rut360`). Asterisk
  identifies a client by the user of its From header and registers the AOR of its To header, so a
  softphone configured as documented matched no endpoint (endless 401). The gateway's own section
  names (`server*`, `global`, `transport-udp`, `local-auth`) are refused as a username.
- **Driver: out-of-bounds read in `enum2str_def()`.** Asterisk's `S_COR()` evaluates
  `names[value]` before its condition, so an unset value (registration state -1 before the module
  registers) was read about 4 GiB past the array: `quectel show device state` crashed Asterisk on
  64-bit hosts. On the RUT360 (32-bit MIPS) the address wraps to the word before the array, with no
  visible effect. The bound is now checked first, for every enum-to-text conversion.
- **Driver: call state URCs alongside `AT+CLCC` polling.** On a module that also sends
  `+QIND "ccinfo"` URCs (EC25 in URC mode), the "dialing" URC can arrive before the OK of `ATD`;
  the poll logic recorded the outgoing call as unknown and hung it up. A URC may now attach a call
  still being dialled, and only the poll declares a call unknown. No change on the RUT360, whose
  URCs go to `gsmd`. The bench simulates the URC mode.
- **Driver: SMS announced while another one is read.** A `+CMTI` received during an `AT+CMGR` was
  dropped, and the message was only read at the next start of the device (the second part of a long
  SMS, for example). It is now queued (up to 8) and read once the current read is over. No change
  on the RUT360, where `sms = off` and RutOS handles SMS.
- Outgoing SMS and USSD checks compare lengths instead of strings: a `"` in the number broke the
  expression (harmless, the filtered value was already the one used).

The driver changes are also on the public fork
[yasserboutaleb/asterisk-chan-quectel](https://github.com/yasserboutaleb/asterisk-chan-quectel)
(commits `aa4543a`, `6e11254`, `a645433`).

## 0.2.0: first public release

First public release of `rut360gw`, a GSM/VoLTE <-> SIP gateway for the Teltonika RUT360
(RutOS 7.14.5, Quectel EG06-E), built on an embedded Asterisk 18 runtime and a patched
chan_quectel driver that coexists with RutOS `gsmd`.

- **Generic remote SIP server** (UCI section `server`), in two modes:
  - `register`: the gateway registers with a username and password and receives calls on its
    registered line, through the 4G NAT. Incoming GSM calls carry the caller number as the
    display name and in `P-Asserted-Identity`. Received SMS are sent as authenticated SIP
    `MESSAGE`s.
  - `ip`: a trusted peer identified by its address, for use over a VPN configured in RutOS.
- **`features.gsm_in`**: incoming GSM calls ring on the server, on the LAN softphone, or both.
  Without a server, received SMS go to the LAN softphone.
- **Voice**:
  - the GSM call is answered only when the SIP side answers;
  - an unreachable or busy SIP side makes the gateway reject the GSM call as busy, so the
    operator's voicemail applies;
  - 60 s without RTP on an answered call hangs it up;
  - selectable ringback tone (`features.ringback`).
- **SMS <-> SIP bridge**, with SIM purge after a successful relay. **USSD** from a softphone
  and from an interactive session in the web page.
- **Web page** `http://<router>/rut360gw/`: Dashboard with a self-test, SMS, USSD, a single
  Setup form, Settings, and an event log.
- **LAN firewall rules** (`rut360gw-fw`):
  - SIP rate limit from the LAN (`features.lan_sip_limit`, 20 packets/s by default);
  - in `ip` mode, the server's address is dropped when it comes from the LAN (anti-spoofing).

  The LAN SIP client is accepted only from the LAN subnet.
- **RutOS integration** (`main.manage_rutos`):
  - removes the Call Utilities action that makes `mobifd` hang up incoming calls;
  - stops e-mail forwarding from deleting SMS;
  - freezes the RutOS FOTA check and the modem update notification.

  The original values are restored on uninstall.
- **Robustness**:
  - a watchdog restarts Asterisk if the modem device stays missing, uninitialised or stuck;
  - the driver re-initialises the modem after a modem reset;
  - call tracking by `AT+CLCC` polling handles late-listed calls, refused hang-ups and
    reused call indexes.
- **Embedded runtime** (`rut360gw-runtime`): Asterisk 18.15.1 and pjproject 2.12.1 rebuilt
  without OpenSSL, about 1.8 MB in flash, extracted to RAM at start, with no network needed.
  The official OpenWrt 21.02 packages are a verified fallback.
- English throughout: comments, log messages, Asterisk templates, default configuration and
  web page.
- Reproducible builds, and a local Docker CI with a QEMU bench (simulated modem, simulated
  SIP server requiring digest authentication) on generic OpenWrt 21.02 and on the real RutOS
  7.14.5 root filesystem.

Earlier versions (0.1.x) were private builds used in production on RUT360 routers. Their
fixes are included in this release. They were tied to a specific private server setup, which
0.2.0 replaces with the generic `server` section. A private 0.1.x configuration is converted
automatically on upgrade: `rut360gw-config migrate` turns it into the `server` section in
`ip` mode.
