# Changelog

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
