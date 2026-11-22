# Installation and configuration

## Requirements

| Item | Value |
|---|---|
| Router | Teltonika RUT360, firmware **`RUT36X_R_00.07.14.5`** (RutOS 7.14.5) |
| Modem | Quectel EG06-E (`2c7c:0306`), factory USB composition |
| Flash | about 2 MB free: `rut360gw` about 0.2 MB, `rut360gw-runtime` about 1.8 MB |
| RAM | 15 MB available when the gateway starts, about 4.4 MB used afterwards |
| Network | none needed to start: the Asterisk runtime ships with the package |
| SIP side | a SIP server ([SIP-SERVER.md](SIP-SERVER.md)), or only a softphone on the router's LAN |

> **Do not update the RutOS firmware or the modem firmware.** The runtime, the driver and the
> SMS bridge depend on RutOS 7.14.5 (its OpenWrt 21.02 libraries and the `gsmd` interface) and
> on the AT behaviour of the EG06-E firmware. The gateway disables the automatic RutOS update
> check and the modem update notification (see [RutOS settings](#rutos-settings-changed-by-the-gateway)).
> If you update the firmware anyway, reinstall the package afterwards, once a version that
> supports the new firmware is released.

## Install

The RutOS Package Manager expects a Teltonika archive, not a bare `.ipk`.

1. Download `rut360gw_<version>_RUT36X_R_00.07.14.5.tar.gz` from the release page. Check it
   against the published SHA-256 sums.
2. RutOS WebUI: **System > Package Manager > Upload package**, then select the archive.
3. RutOS warns *"Unauthorized package: NOT digitally signed and authorized by Teltonika"*.
   Choose **Proceed**.
4. The archive installs `rut360gw-runtime` first, then `rut360gw`. If the installed
   `rut360gw-runtime` already has the same version, it is skipped. The LAN port may drop for
   about 2 seconds while RutOS reapplies its network configuration.

The Package Manager also checks that:

- the router is a RUT360;
- the firmware is exactly `RUT36X_R_00.07.14.5`;
- there is enough flash space;
- the version is strictly newer than the one installed.

After installation, the service is enabled at boot. It stays idle while
`rut360gw.main.enabled=0`, which is the default.

Command-line alternative, as root over SSH, with both `.ipk` files copied to the router:

```sh
opkg install rut360gw-runtime_<version>_mips_24kc.ipk rut360gw_<version>_mips_24kc.ipk
```

## First setup (web page)

1. Open **`http://<router>/rut360gw/`**, with the trailing slash, and sign in with the RutOS
   admin account. The page is in English. It is served by the RutOS web server, on the LAN.
2. Go to the **Setup** tab.
   - **Use a remote SIP server**: tick it to connect to Asterisk, FreePBX... Leave it unticked
     to use only a softphone on the LAN.
   - **Connection**:
     - *Register with a username and password*: recommended, works behind the 4G NAT.
     - *Trusted peer over a VPN*: no password. Use it only through a VPN that you configure in
       RutOS yourself.
   - **Server address** and **SIP port** (UDP).
   - **Username** and **Password**: the gateway's account on the server (`register` mode).
   - **Extension that receives GSM calls and SMS**: an extension on the server, for example
     `101`.
   - **Gateway address in the VPN** (`ip` mode only).
   - **Incoming GSM calls ring**: on the SIP server, on the LAN softphone, or on both.
   - **Country (call tones)**.
3. Click **Save and activate**. The router validates every value first. A refused value
   changes nothing.
4. Configure the server side as described in [SIP-SERVER.md](SIP-SERVER.md).
5. **Dashboard > Self-test**: every line should be `OK`. `WARN` lines do not prevent calls.
   See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

The other tabs:

| Tab | Content |
|---|---|
| **Dashboard** | Status of the gateway, modem, network, VoLTE, data, SIP server, SMS bridge, SIM storage, incoming-call blocking by RutOS, signal and RAM. Buttons: *Fix RutOS settings*, *Refresh*, *Restart gateway*, *Self-test*. |
| **SMS** | Messages on the SIM (relayed, kept or incomplete) and storage gauge. Delete one SMS or all of them. Shows the state of RutOS e-mail forwarding. |
| **USSD** | Interactive USSD session: send a code (`*100#`), then answer the operator's menus. *Clear session* closes it. Refused during a GSM call. |
| **Settings** | Gateway on/off, *Manage the RutOS settings*, country, SMS bridge, SIM purge and its delay, USSD, ringback tone, and the LAN SIP client (username, password, *Generate new password*, disable). |
| **Logs** | Event log, newest first: calls (direction, masked number, result, duration), SMS, USSD, gateway starts, problems. Filters, and the raw log on request. |

### Softphone on the LAN

A softphone on the router's LAN (Linphone, Zoiper...) can register directly with the gateway.
It does not need a SIP server.

| Setting | Value |
|---|---|
| SIP server / domain | the router's LAN address, UDP port 5060 |
| Username | `local.username` (default `rut360`) |
| Password | **Settings > LAN SIP client** (empty = client disabled) |

The gateway accepts this client only from the LAN subnet. The softphone can:

- call national or `+` international numbers through the mobile network;
- call `600` to hear its own voice echoed by the gateway, at no GSM cost;
- send SIP messages to phone numbers, which go out as SMS.

When no SIP server is enabled, received SMS go to this client. USSD codes dialled from a
softphone are only handled when they come through the SIP server; from the LAN, use the
**USSD** tab.

## RutOS settings changed by the gateway

With `main.manage_rutos=1` (the default), the gateway sets these RutOS settings at every
service start:

| RutOS setting | Change | Why |
|---|---|---|
| Call Utilities (`call_utils.call`) | the `action` option is removed and `enabled` is set to `0` | On RutOS 7.14, `mobifd` hangs up every incoming call as soon as `action` exists, even with `ignore` and even when disabled. Only its absence lets calls ring. Applying the change reloads `mobifd`, which reconnects mobile data and VoLTE (about 1 to 2 minutes). This is done only when the setting actually changes. |
| SMS-to-e-mail forwarding (`sms_gateway.to_smtp.delete_sms`) | set to `0` | Otherwise RutOS deletes the SMS before the bridge relays it. Forwarding itself stays as configured. The bridge cleans the SIM itself (see `features.sms_purge`). |
| RutOS FOTA check (`rut_fota.config.enabled`) | set to `0` | The firmware must stay on 7.14.5. |
| Modem update notification (`dfota.config.notify`) | set to `0` | The modem firmware must stay on the validated version. |

The original values are saved once in `/etc/rut360gw/rutos.orig` and restored on uninstall.
With `manage_rutos=0`, the gateway only warns, in the system log and on the Dashboard, which
then shows a *Fix RutOS settings* button. On the command line, use
`rut360gw-rutos status|align|restore`.

Saving the RutOS *Call Utilities* page again may add the `action` option back. The gateway
removes it again at the next service start, and the self-test reports it in the meantime.

## Upgrade

Upload the newer WebUI archive in the same way (**System > Package Manager**).

- Your settings in `/etc/config/rut360gw` are kept.
- The runtime package is installed only when its version changes. Otherwise it is skipped.
  It also checks for enough flash space itself, taking into account the old archive it
  replaces. If there is not enough space, nothing is modified and the old version stays.
- If the gateway is enabled, it restarts a few seconds after the installation.
- A version is accepted only if it is strictly newer than the installed one.

## Uninstall

RutOS WebUI: **System > Package Manager**, remove `rut360gw`, then `rut360gw-runtime`.
Or on the command line:

```sh
opkg remove rut360gw
opkg remove rut360gw-runtime
```

| On uninstall | What happens |
|---|---|
| Service | Stopped and disabled. The modem's serial voice is switched off (`AT+QPCMV=0,0`). |
| RutOS settings | Original values restored from `/etc/rut360gw/rutos.orig`: Call Utilities, `delete_sms`, FOTA check, modem notification. If Call Utilities are restored, `mobifd` is reloaded (data and VoLTE reconnect in about 1 to 2 minutes). Incoming calls are then handled by RutOS again, as before the installation. |
| Firewall | The rules added by the gateway (`rut360gw_*`) are removed and the firewall reloaded. |
| Files | Package files removed, the web page included. |
| **Kept** | `/etc/config/rut360gw` (your settings and passwords) and `/etc/rut360gw/` (record of relayed SMS), so that a reinstall needs no setup. The runtime extracted to RAM stays in `/tmp` until the next reboot. |

Full cleanup after uninstall:

```sh
rm -f /etc/config/rut360gw
rm -rf /etc/rut360gw /tmp/rut360gw /var/run/rut360gw
```

## Configuration reference: `/etc/config/rut360gw`

All the settings are in this single UCI file. It has mode 600 because it holds the passwords.
The web page writes the same options.

Command-line change:

```sh
uci set rut360gw.features.gsm_in=both
rut360gw-config apply
```

`rut360gw-config apply` validates the configuration and generates the Asterisk files in RAM.
If the configuration is valid, it commits it and restarts the service. If a value is invalid,
nothing is committed and the service keeps running on the old configuration. Use
`uci changes rut360gw` and `uci revert rut360gw` to inspect or cancel your changes.

**Do not use `reload_config`**: on RutOS it also reloads the network, and the LAN port
renegotiates for a few seconds.

On RutOS 7.14, the commands are installed in `/usr/local/usr/sbin/`.

### `main`

| Option | Default | Meaning |
|---|---|---|
| `main.enabled` | `0` | `1` = the service starts, at boot and through `/etc/init.d/rut360gw start`. |
| `main.country` | `fr` | Call progress tones: `fr`, `dz`, or any two-letter country of Asterisk's `indications.conf`. |
| `main.manage_rutos` | `1` | `1` = the gateway adjusts the RutOS settings it needs, saves the original values and restores them on uninstall. `0` = warning only. See [above](#rutos-settings-changed-by-the-gateway). |

### `modem`

| Option | Default | Meaning |
|---|---|---|
| `modem.usb_id` | `2c7c:0306` | Expected modem (USB vendor:product). `2c7c:0306` is the RUT360's EG06-E. |
| `modem.audio_if` | `1` | USB interface used for serial PCM voice (`AT+QPCMV=1,0`). Interface 1 is the NMEA port. |
| `modem.data_if` | `3` | USB interface used for call control (secondary AT port). **Interface 2 is the AT port of RutOS `gsmd` and is always refused.** |
| `modem.clcc_poll` | `1000` | Call tracking: `AT+CLCC` polling period in ms. Modem events (URCs) belong to `gsmd`. |

Serial ports are found by USB interface number, not by `ttyUSBn` name. Check them with
`rut360gw-config ports`.

### `server`: remote SIP server

| Option | Default | Meaning |
|---|---|---|
| `server.enabled` | `0` | `1` = use a remote SIP server (Asterisk, FreePBX...). It receives incoming GSM calls, SMS and USSD replies, and can place calls through the gateway. `0` = LAN softphone only. |
| `server.mode` | `register` | `register`: the gateway registers with `username`/`password`. Recommended, works behind NAT. `ip`: trusted peer identified by its address, without a password, only behind a VPN. In `ip` mode the gateway also drops that address when it comes from the LAN. |
| `server.host` | *(empty)* | Server address: host name or IP. In `ip` mode it must be an IPv4 address: the server's address inside the VPN. |
| `server.port` | `5060` | Server SIP port (UDP). |
| `server.username` | *(empty)* | The gateway's account on the server (`register` mode). Letters, digits, `_ . + -`. |
| `server.password` | *(empty)* | Password of that account (`register` mode). It must not contain `\|`, `;`, `\` or a newline; the web page also refuses `"`. |
| `server.extension` | *(empty)* | Extension on the server that receives incoming GSM calls, SMS and USSD replies. Required when the server is enabled. |
| `server.local_address` | *(empty)* | `ip` mode only: the gateway's IPv4 address inside the VPN. It is used as the domain of the `From` header of SMS. |
| `server.codec` | `ulaw` | Codec towards the server: `ulaw`, `alaw`, or both (`ulaw,alaw`). |

### `local`: LAN SIP client

| Option | Default | Meaning |
|---|---|---|
| `local.username` | `rut360` | Username of the LAN softphone. |
| `local.password` | *(empty)* | Its password. Empty = LAN client disabled. The web page generates a random one (*Generate new password*). It must not contain `\|`, `;`, `\` or a newline. |

### `features`

| Option | Default | Meaning |
|---|---|---|
| `features.gsm_in` | `auto` | Where incoming GSM calls ring: `server`, `local` (LAN softphone), or `both` (the first to answer takes the call). `auto` = the server if it is enabled, otherwise the LAN softphone. With no destination, incoming calls are rejected as busy. |
| `features.lan_sip_limit` | `20` | Firewall: at most N SIP packets per second (UDP 5060) from the LAN, with a burst of 2N. The rest is dropped. `0` = no limit. Range 0 to 9999. |
| `features.sms_bridge` | `1` | SMS <-> SIP bridge. |
| `features.ussd` | `1` | USSD: `*codes` dialled through the SIP server, and the USSD tab. A USSD request may cut mobile data for about 45 s (2G/3G fallback). |
| `features.sms_purge` | `1` | SIM purge: an SMS relayed successfully is deleted from the SIM after `sms_purge_delay`. These SMS are never purged automatically: SMS present before installation, SMS that could not be relayed, incomplete SMS. |
| `features.sms_purge_delay` | `300` | Delay before purging, in seconds (60 to 86400 in the web page). It gives RutOS e-mail forwarding time to run. |
| `features.ringback` | `network` | Ringback tone on outgoing calls. `network`: the network's own tone and announcements, like a phone; with VoLTE the network sends none, so there is silence until the call is answered. `local`: generated by the gateway as soon as the number is dialled; heard with VoLTE too, but the operator's announcements are lost. |
| `features.rtp_start` | `10000` | First RTP port. |
| `features.rtp_end` | `10100` | Last RTP port. |

### SMS by e-mail

To receive SMS by e-mail as well, use the native RutOS feature: **Services > Mobile Utilities
> SMS Gateway > SMS Forwarding**, type *To Email*, with an SMTP account declared in RutOS.
Leave **"Delete SMS after forwarding"** unticked. The SMS bridge cleans the SIM after relaying
(`features.sms_purge`). The **SMS** tab warns about a wrong setting.

## Runtime package notes

- `rut360gw-runtime` holds a compressed archive (about 1.8 MB in flash) of Asterisk 18.15.1 and
  pjproject 2.12.1, rebuilt without OpenSSL, with their OpenWrt 21.02 dependencies.
- At every gateway start, the archive is checked against its SHA-256 and extracted to RAM
  (`/tmp/rut360gw/root`, about 4.4 MB), in a few seconds, without network. 15 MB of available
  RAM is required.
- **Fallback**: if the runtime package is missing or its archive is damaged, the gateway
  downloads the official OpenWrt 21.02 packages (about 4.3 MB, 10.7 MB extracted, 30 MB of
  available RAM required). Each file is checked against the SHA-256 in the package manifest.
  It retries every 2 minutes without limit, then starts by itself. Extra mirrors can be listed
  in `/etc/rut360gw/mirrors`, one base URL per line, tried before `downloads.openwrt.org` and
  `archive.openwrt.org`. Nothing is written to flash.
- **Flash space**: the runtime package declares `Installed-Size: 0`, because opkg and the
  WebUI would compare its full size with the free space without deducting the version already
  installed. Its `preinst` script does the real check instead:
  `free >= new archive + 256 KB - 85 % of the old archive`. If the check fails, opkg aborts and
  the installed version stays intact. The message gives the sizes.
- **Updates**: the runtime changes rarely. The WebUI archive always contains it, but it is only
  installed when its version changes. A new runtime is used at the next gateway start, which
  the `rut360gw` package triggers right after.

## Useful commands

| Command | Purpose |
|---|---|
| `rut360gw-check` | Self-test: one `OK`/`WARN`/`FAIL` line per check, then the verdict. Read-only. |
| `rut360gw-config apply` | Validate, commit and restart. |
| `rut360gw-config show` | Effective configuration, with passwords masked. |
| `rut360gw-config ports` | Detected modem serial ports. |
| `rut360gw-cli "<command>"` / `rut360gw-cli` | Asterisk console: one command, or interactive. |
| `rut360gw-runtime status` / `state` | Runtime in RAM and memory, or the state: `ready`, `downloading`, `waiting_network`, `low_memory`, `absent`. |
| `rut360gw-rutos status` | RutOS settings that interfere with the gateway (no output = OK). |
| `rut360gw-fw show` | Expected firewall rules and rules in place. |
| `rut360gw-watchdog check` | One watchdog check: `ok`, or the faulty state. |
| `/etc/init.d/rut360gw restart` | Restart the gateway. |
| `logread -e rut360gw` | Gateway logs. |
