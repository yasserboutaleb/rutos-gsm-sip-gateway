# Security

## Threat model

The gateway can place calls and send SMS on your mobile subscription. Anyone who can drive it
can spend your credit. Its main assets are therefore the SIP access to the gateway and the
gateway's account on your SIP server.

| Network | Exposure |
|---|---|
| **4G WAN** | Nothing is opened. The RutOS `wan` zone rejects incoming traffic and the package adds no WAN rule. In `register` mode, the server's requests and media come back only through the connection-tracking state of the gateway's own outgoing traffic (`REGISTER`, `OPTIONS`, RTP). |
| **LAN** | SIP (UDP 5060) and RTP (UDP 10000-10100 by default) are reachable from the LAN, as is the web page. SIP is rate-limited (see below). Treat LAN devices as semi-trusted. |
| **VPN** (`ip` mode) | The server is trusted by its address, without a password. The VPN, configured in RutOS, is what authenticates it. Open SIP/RTP in the VPN zone only from the server's address. |

## Firewall rules added by the gateway

`rut360gw-fw` manages three UCI firewall rules. It runs at every service start, reloads the
firewall only when a rule changes, and removes them on uninstall. Nothing else in the firewall
is touched. Use `rut360gw-fw show` to compare the expected rules with the rules in place.

| Rule | When | Effect |
|---|---|---|
| `rut360gw_antispoof` | `ip` mode, server enabled, `server.host` is an IPv4 address | Drops any packet coming from the **LAN** with the server's address as source. Without it, a LAN device could impersonate the trusted server and place calls. |
| `rut360gw_sip_lan` | `features.lan_sip_limit` > 0 (default 20), and the `lan` zone accepts its input | Accepts SIP (UDP 5060) from the LAN up to N packets/s, with a burst of 2N. Never added when the `lan` zone rejects or drops its input: there it would open UDP 5060, and SIP from the LAN is left to the zone. With the LAN SIP client enabled on such a LAN, the service logs a warning at start: add your own rule if the client must reach the gateway. |
| `rut360gw_sip_lan_drop` | same | Drops LAN SIP above that limit, which slows password guessing and contains a runaway client. |

## SIP access control on the gateway

- **LAN SIP client** (`local.*`):
  - disabled while its password is empty;
  - digest authentication;
  - accepted **only from the LAN subnet** (and the loopback). The Asterisk ACL is generated
    from `network.lan`;
  - one registered contact at a time.

  The web page generates a random 20-character password.
- **Remote server**, `register` mode: the gateway accepts requests from the server only on its
  registered line (the `line` parameter of its `Contact`), never on the user of the `From` header
  (`identify_by = ip`). Unsolicited requests are rejected.
  Use a long random password for the gateway's account and protect the server (fail2ban or
  similar).
- **Remote server**, `ip` mode: identified by its IP address only, so use it **only over a
  VPN**. The anti-spoofing rule above covers the LAN side.
- **No TLS and no SRTP.** The embedded runtime (Asterisk and pjproject) is built **without
  OpenSSL**, so SIP and RTP between the gateway and the server are unencrypted. When the
  server is not on the LAN, put the traffic inside a VPN (WireGuard, OpenVPN or IPsec
  configured in RutOS), or accept that calls and SMS travel in clear text over the Internet.
- **Hang-up safety**: an answered call that receives no RTP for 60 s is hung up
  (`rtp_timeout`), so a GSM call is never left open, and charged, after the server, the
  network or the client disappears. Set the same timeout on the server.

## Secrets

- All the secrets live in **`/etc/config/rut360gw`** only: the server password and the LAN
  client password. The file has mode 600, set in the package and by its install script.
  `/etc/rut360gw/` has mode 700.
- The generated Asterisk configuration, which contains the passwords, is written to RAM
  (`/var/run/rut360gw/etc`) with a 077 umask.
- `rut360gw-config show` masks the passwords.
- The **Logs** tab never shows SMTP credentials. RutOS logs the whole SMTP dialogue of its
  SMS-to-e-mail forwarding, including the base64 `AUTH` exchange. The log method drops every
  line from `urcd`, every `AUTH PLAIN/LOGIN/CRAM-MD5/XOAUTH2` line and every SMTP `334` reply.
- Passwords are validated before they are written: no `|`, `;`, `\` or newline, which would
  break the generated configuration.

## Web page and API

- The page `http://<router>/rut360gw/` is served by the RutOS web server and uses the RutOS
  login (rpcd session).
- The API is the ubus object `rut360gw`, limited by its own ACL
  (`/usr/share/rpcd/acl.d/rut360gw.json`). The RutOS `admin` account has access.
  `get_config` returns the SIP passwords so that the page can show them, so grant this ACL
  group only to administrators.
- Every field is validated by the API (regular expressions), then the whole configuration is
  validated by `rut360gw-config`. If anything is refused, nothing is saved.
- The page loads no external resource. It contains no inline script or style, and works with
  the strict Content-Security-Policy of the RutOS web server. Text coming from the router
  (SMS, USSD, logs) is inserted as text, never as HTML.

## Untrusted input (SMS, SIP messages, USSD)

- The text of an SMS or a SIP `MESSAGE` is never interpreted by a shell. It is passed
  base64-encoded between Asterisk and the SMS bridge, and every shell argument is quoted.
- Phone numbers are filtered twice: by the dialplan (`+` and digits only), then by the bridge
  (3 to 20 characters). USSD codes are limited to `[0-9*#]`, 64 characters, one request at a
  time, and are refused during a GSM call.
- The gateway does not execute commands received by SMS. The RutOS SMS command feature
  (*SMS Utilities*: reboot, status...) is independent and remains active. Review it in RutOS.

## Robustness

- **Watchdog** (`rut360gw-watchdog`): it checks the modem driver once a minute. If the device
  stays missing, uninitialised, or the Asterisk console stays stuck for 5 checks in a row
  (more than 3 minutes after Asterisk started), it restarts Asterisk only. The modem, mobile
  data and the rest of RutOS are not touched. It restarts at most 3 times in 6 hours, then
  only logs an alert.
- procd restarts Asterisk if it exits (at most 5 times per hour) and restarts the SMS bridge.
- The runtime archive is checked against its SHA-256 at every start. A damaged archive is
  refused. The fallback download checks each file against the SHA-256 in the package
  manifest.
- The gateway never changes:
  - the modem's USB composition, radio settings or APN;
  - the default routes;
  - the AT port and URC routing of `gsmd`;
  - global modem settings (`CSCS`, `CMEE`, `CNMI`, `QINDCFG`...);
  - operator-side call waiting.

## Known limits

- **End-of-life components**: Asterisk 18 and OpenWrt 21.02 (the base of RutOS 7.14.5) no longer
  receive upstream security fixes. Because the runtime is rebuilt from source by this project's
  CI, an Asterisk fix can still be backported, but it is not automatic. Keep SIP access to the
  gateway limited to the LAN and a VPN.
- **Frozen firmware**: the gateway disables automatic RutOS and modem update checks, because
  it only supports RutOS 7.14.5. The router therefore does not receive Teltonika firmware
  updates while the gateway is installed.
- Asterisk runs as root, like the rest of RutOS.
- The packages are not signed by Teltonika. Check the SHA-256 sums published with each
  release. The build is reproducible: see [BUILDING.md](BUILDING.md).

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use the repository's private
vulnerability reporting (GitHub *Security > Report a vulnerability*), or contact the
maintainer privately.
