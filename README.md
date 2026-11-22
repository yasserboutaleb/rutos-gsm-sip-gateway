# rut360gw: GSM/VoLTE to SIP gateway for the Teltonika RUT360

`rut360gw` turns a **Teltonika RUT360** 4G router into a single-line **GSM/VoLTE <-> SIP gateway**.
Calls, SMS and USSD from the router's SIM are bridged to a SIP server (Asterisk, FreePBX...) or
to a softphone on the LAN, while RutOS keeps running normally: mobile data, SMS forwarding,
VPN, failover and the RutOS WebUI keep working.

It is built on **Asterisk 18** (a reduced runtime embedded in the package and extracted to RAM)
and a patched **chan_quectel** driver that coexists with the RutOS modem manager (`gsmd`)
instead of taking the modem over.

## Features

- **Voice calls in both directions** between the mobile network (VoLTE, or 3G/2G fallback) and SIP.
  - Incoming GSM calls ring on the SIP server, on the LAN softphone, or on both. The GSM call
    is answered only when the SIP side answers, so the caller is not charged while nobody
    picks up and reaches the operator's voicemail if there is no answer.
  - If the SIP side is unreachable or busy, the GSM call is rejected as *busy*, so the
    operator's call-forward-on-busy (voicemail) applies.
  - A call with no RTP for 60 s is hung up, so a lost SIP client never leaves a GSM call open
    and charged.
- **Two ways to connect to a SIP server**:
  - `register`: the gateway registers with a username and password. This is recommended and
    works behind the 4G carrier NAT.
  - `ip`: a trusted peer identified by its address, without a password, only over a VPN.
- **SMS <-> SIP MESSAGE bridge.** Received SMS are sent as SIP `MESSAGE`. A SIP `MESSAGE`
  sent to a phone number becomes an SMS. RutOS remains the owner of SMS, so its native
  SMS-to-e-mail forwarding still works.
- **USSD**: dial `*code#` from a softphone and the reply comes back as a SIP message. There is
  also an interactive USSD session in the web page.
- **Web page** at `http://<router>/rut360gw/`, behind the RutOS admin login, with six tabs:
  Dashboard (status and self-test), SMS (messages on the SIM), USSD, Setup, Settings, Logs (call,
  SMS and USSD events).
- **Self-test** (`rut360gw-check`): a read-only check of everything a call or an SMS depends on.
- **Safe on the LAN**: SIP rate limit from the LAN, access list for the LAN softphone,
  anti-spoofing rule in `ip` mode, and nothing opened on the 4G WAN.
- **Self-healing**: a watchdog restarts Asterisk if the modem driver stays stuck, and the
  driver re-initialises the modem by itself after a modem reset.
- **Reversible**: the RutOS settings the gateway changes are saved and restored on uninstall.

## Supported hardware and firmware

| Item | Supported |
|---|---|
| Router | Teltonika **RUT360** |
| Firmware | RutOS **7.14.5** only (`RUT36X_R_00.07.14.5`, OpenWrt 21.02 base, `mips_24kc`) |
| Modem | Quectel **EG06-E** (USB `2c7c:0306`), factory USB composition |
| Flash | about 2 MB free (gateway package about 0.2 MB, runtime package about 1.8 MB) |
| RAM | about 4.4 MB used by the runtime in `/tmp`, and 15 MB must be available when it starts |
| Codecs | G.711 (`ulaw`, `alaw`), narrowband 8 kHz |

The RutOS Package Manager refuses the archive on any other firmware version. Other routers
and modems are not supported. The driver depends on the AT behaviour of the EG06-E firmware,
and the runtime depends on the RutOS 7.14.5 system libraries.

The gateway has been tested with French and Algerian mobile operators, with and without VoLTE.

## Quick start

1. Download the WebUI archive `rut360gw_<version>_RUT36X_R_00.07.14.5.tar.gz` from the releases
   page. Use the **archive**, not the bare `.ipk`. It contains both packages:
   `rut360gw-runtime` and `rut360gw`.
2. In the RutOS WebUI, go to **System > Package Manager > Upload package** and select the
   archive. RutOS warns that the package is not signed by Teltonika: choose **Proceed**. The
   LAN port may drop for about 2 seconds during the installation.
3. Open **`http://<router>/rut360gw/`**, with the trailing slash, and sign in with the RutOS
   admin account.
4. In the **Setup** tab, enter your SIP server details, or leave the server unchecked to use
   only a softphone on the LAN. Then click **Save and activate**.
5. In the **Dashboard** tab, click **Self-test**.

Then configure your SIP server as described in [docs/SIP-SERVER.md](docs/SIP-SERVER.md).

## Documentation

| Document | Content |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Installation, upgrade, uninstall, first setup, reference of every option |
| [docs/SIP-SERVER.md](docs/SIP-SERVER.md) | Asterisk/FreePBX configuration for both modes: calls, SMS, USSD, NAT |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, firewall rules, secrets, known limits |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Self-test lines, common problems, logs |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, files on the router, how the driver coexists with `gsmd`, call/SMS/USSD flows |
| [docs/BUILDING.md](docs/BUILDING.md) | Building from source with the Docker CI, reproducible packages, test bench |
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |

## Status

Version **0.2.0**, the first public release. The gateway handles **one GSM call at a time**.
It has run in production on RUT360 routers, and every build is tested on an emulated bench
(QEMU, simulated modem and SIP server) on both a generic OpenWrt 21.02 root filesystem and the
real RutOS 7.14.5 one.

Asterisk 18 and OpenWrt 21.02 are end-of-life upstream. See [docs/SECURITY.md](docs/SECURITY.md).

## Licence

GPL-2.0-only, like chan_quectel and Asterisk. The chan_quectel sources come from the
`asterisk-chan-quectel` project (chan_dongle lineage), with a patch for RutOS coexistence.

## Disclaimer

- The packages are **not signed by Teltonika**. RutOS shows an "unauthorized package" warning
  when you install them.
- The gateway changes a few RutOS settings, listed in [docs/INSTALL.md](docs/INSTALL.md), and
  freezes automatic firmware update checks. **Do not update RutOS or the modem firmware** while
  it is installed.
- **Calls, SMS and USSD go through your mobile subscription and may cost money.** Protect your
  SIP server and accounts. Anyone who can place calls through the gateway spends your credit.
- Use at your own risk. The software comes with no warranty (see the licence). This project
  is not affiliated with Teltonika, Quectel, Sangoma or the Asterisk project.
