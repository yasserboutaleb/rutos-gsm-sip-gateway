# Troubleshooting

Start with the **self-test**: **Dashboard > Self-test** in the web page, or `rut360gw-check`
over SSH. It is read-only: it places no call and sends no SMS. It prints one line per check,
then a verdict:

- `OK`: the check passed.
- `WARN`: worth a look, but calls can still work.
- `FAIL`: something a call or an SMS depends on is broken.

In the first 2 to 3 minutes after a boot or a restart, the modem is still initialising and
the registration is still in progress. Run the self-test again a little later before acting
on a `FAIL`.

## Self-test lines

| Line | If not OK |
|---|---|
| `package / API` | The rpcd API is missing. Run `/etc/init.d/rpcd reload`, or reinstall the package. |
| `start at boot` | Run `/etc/init.d/rut360gw enable`. |
| `gateway activated` | `rut360gw.main.enabled=0`: use **Setup > Save and activate**, or **Settings > Gateway enabled**. |
| `runtime (RAM)` | `waiting_network`: the embedded runtime is missing or damaged, and the fallback download has no mobile data yet. It retries every 2 minutes. Reinstall the WebUI archive if `rut360gw-runtime` is missing (`opkg list-installed \| grep rut360gw`). `low_memory`: less than 15 MB of RAM is available. Look for what fills `/tmp` (`free`, `df /tmp`). |
| `Asterisk` | Stopped. Read `logread -e rut360gw` for the reason, often an invalid configuration (`rut360gw-config generate` prints it). |
| `chan_quectel driver` | The driver module is not loaded. Restart the gateway. If it persists, reinstall the package. |
| `SMS bridge` | The SMS bridge daemon is not running (`features.sms_bridge=1`). Restart the gateway. |
| `modem (gateway)` | `initialising`: wait a minute. `NoVoice`: the modem refused serial voice, usually because a call was still open when Asterisk started. The driver retries every 5 s while no call is in progress. If it lasts, run `/etc/init.d/rut360gw restart`. `Not initialized`: see [below](#modem-not-initialized). |
| `mobile data` (WARN) | No mobile data connection. Calls may still work. Data is only needed for a remote server reached over 4G. |
| `VoLTE` (WARN) | Not active: calls fall back to 3G/2G. Each call then interrupts mobile data for 10 to 15 s. |
| `mobile failover (<interface>)` (WARN) | Without VoLTE, every call stops mobile data for 10 to 15 s. If RutOS Failover declares the mobile link down within less than 30 s, the link to the server and the call audio drop at every call whenever the mobile link is the only one left. In **Network > Failover**, raise *Down* for the mobile interface to the value shown. |
| `SIM SMS storage` (WARN) | More than 80 % full. Delete old SMS in the **SMS** tab, and check *Settings > Delete relayed SMS*. |
| `incoming calls` | RutOS Call Utilities will hang up incoming calls. See [below](#incoming-calls-hang-up-or-go-to-voicemail). |
| `RutOS settings` | A RutOS setting interferes with the gateway: Call Utilities action, e-mail forwarding deleting SMS, update checks enabled. Click **Dashboard > Fix RutOS settings**, or set `main.manage_rutos=1`. |
| `SIP server registration` | See [below](#not-registered-on-the-sip-server). |
| `SIP server` (WARN, register mode) | The server does not answer `OPTIONS`. Some servers do not, and calls still work while the gateway is registered. |
| `SIP server reachable` / `SIP trunk (server)` (ip mode) | No ping or no `OPTIONS` reply through the VPN. Check that the RutOS VPN is up, that `server.host` is the server's VPN address, and that the VPN firewall zone accepts UDP 5060 from the server. |
| `SIP server` (no server) | Neither a remote server nor a LAN client is configured, so nobody can take calls. Use the **Setup** tab, or set a LAN client password. |
| `free RAM` | Below 25 MB is a warning, below 12 MB a failure. Asterisk refuses calls below 8 MB. Find what uses the RAM. |
| `/tmp (RAM)` (WARN) | `/tmp` is more than 70 % full. |
| `debug traces` (WARN) | An Asterisk log channel to `/tmp` is still active. Remove it (`rut360gw-cli "logger show channels"`, then `logger remove channel ...`) or restart the gateway. |
| `web page` | `/rut360gw/` is not served. Reinstall the package. |

## Common problems

### Not registered on the SIP server

The self-test shows `SIP server registration: Unregistered` or `Rejected`.

- Check the address, port, username and password in **Setup**. A `Rejected` status usually
  means wrong credentials. After a `403 Forbidden`, the gateway retries every 10 minutes.
  Otherwise it retries every minute.
- Is the server reachable from the router? Try `ping <server>` over SSH, and check DNS if
  you use a host name.
- On the server, look at the security log. fail2ban or a similar tool may have banned the
  router's public address after failed attempts.
- Details: `rut360gw-cli "pjsip show registrations"`. For a SIP trace, open the interactive
  console (`rut360gw-cli`) and type `pjsip set logger on`. The SIP messages appear in that
  console. Type `pjsip set logger off` when done.

### Incoming calls hang up or go to voicemail

The caller hears it ring briefly, or goes straight to voicemail, and the SIP side never
rings.

- **RutOS Call Utilities.** On RutOS 7.14, `mobifd` applies the Call Utilities `action`
  option to every incoming call, even when Call Utilities are disabled. Only the absence of
  that option lets the call ring.
  - With `main.manage_rutos=1` (the default), the gateway removes it at start.
  - Otherwise, click **Dashboard > Fix RutOS settings**, or run `rut360gw-rutos align`.
  - `mobifd` must then reload, which happens automatically: mobile data and VoLTE reconnect
    in about 1 to 2 minutes, and calls go to voicemail in the meantime.
  - Saving the RutOS *Call Utilities* page again may add the option back.
- **Nobody can take the call.** If the destination (server or LAN client) is not registered,
  is unreachable or busy, the gateway rejects the GSM call as *busy* on purpose, so the
  operator forwards it to voicemail. Check `features.gsm_in`, the registration, and the
  server's dialplan for `server.extension`.

### Call connects but there is no audio (or one-way audio)

This is almost always NAT or SDP addressing between the server and the gateway or softphone.

- Server endpoint for the gateway: `direct_media = no`, `rtp_symmetric = yes`,
  `force_rport = yes`. In register mode, add `rewrite_contact = yes`.
- If the server is behind NAT: check `external_media_address` and `local_net`. In register
  mode, `local_net` must not include the address the server sees for the gateway. In ip mode,
  it must include the VPN subnet.
- If the server runs in a container whose proxy rewrites source addresses, use host
  networking.
- In ip mode, the VPN zone on the router must accept the RTP range (UDP 10000-10100 by
  default) from the server.
- Call **9600** from the softphone through the server. You should hear the gateway echo your
  voice without using GSM. If the echo works but real calls have no audio, check the modem
  side: `rut360gw-cli "quectel show devices"`.
- See [SIP-SERVER.md](SIP-SERVER.md#nat).

### Hang-up not propagated / call stays open

An answered call with no RTP for 60 s is hung up by the gateway. Set `rtp_timeout = 60` on
the server endpoints too, so that a softphone does not stay connected when the gateway
disappears.

### SMS from the server are not sent (register mode)

In register mode, the gateway accepts a `MESSAGE` from the server only when it targets the
**registered contact**, which carries the `line` parameter. A `MESSAGE` addressed to
`sip:<number>@<gateway address>` is rejected. Use the `MessageSend` example in
[SIP-SERVER.md](SIP-SERVER.md#extensionsconf-server), which replaces the user part of the
registered contact with the destination number.

Other causes:

- the number is not digits with an optional leading `+`;
- the SIM has no SMS credit;
- `features.sms_bridge=0`.

On the gateway, see `logread -e rut360gw-sms`. If sending fails, the gateway sends back a
`MESSAGE` saying *"SMS to <number> could not be sent"*.

### Received SMS do not reach the softphone

- The **SMS** tab shows each SMS on the SIM and whether it was relayed.
- The SMS goes to `server.extension` on the server, or to the LAN client when no server is
  enabled. Check the server's `message_context` for the gateway endpoint.
- SMS that were already on the SIM before the installation are never relayed or purged.
- RutOS e-mail forwarding with *Delete SMS after forwarding* removes SMS before the bridge
  sees them. The gateway resets this setting when `main.manage_rutos=1`.
- A full SIM blocks new SMS. Delete old ones in the **SMS** tab.

### USSD

- USSD is refused during a GSM call. Only one request is handled at a time: the reply is
  awaited for up to 45 s, and the lock expires by itself after 2 minutes.
- Some networks do not serve USSD over VoLTE, or fall back to 2G/3G for it. Mobile data is
  then cut for about 45 s. "No answer from the network" or status 4/5 usually comes from the
  operator.
- USSD dialled from the LAN softphone is not handled. Use the server, or the **USSD** tab.

### Modem "Not initialized"

After a modem reset (by RutOS, a firmware glitch, or a reconnect), the modem may refuse
`AT+QPCMV?` while it restarts. The driver then schedules a new initialisation every 15 s,
up to 20 times (about 5 minutes). It recovers by itself as soon as the modem answers. If it
lasts longer, the watchdog restarts Asterisk (see below). Check the state with
`rut360gw-cli "quectel show devices"`: the `eg06` device should be `Free`.

### Watchdog restarts

The log shows `safety net: ... restarting Asterisk`. The watchdog checks once a minute. It
restarts Asterisk when the modem device has been missing, uninitialised, or the Asterisk
console stuck for 5 minutes. A restart now and then after a modem reset is expected.

After 3 restarts in 6 hours, it stops and logs `no more automatic restart`. In that case:

1. run `rut360gw-check`;
2. look at the modem (`rut360gw-cli "quectel show devices"`, the RutOS mobile status page);
3. run `/etc/init.d/rut360gw restart`.

A single check: `rut360gw-watchdog check`.

### Outgoing calls: no ringback tone

With VoLTE, the network sends no ringback tone, so the caller hears silence until the call is
answered. This is the default behaviour (`features.ringback=network`), which keeps the
operator's announcements. Choose **Settings > Ringback tone > Generated by the gateway**
(`local`) to hear a tone.

### Installation problems

| Symptom | Cause and action |
|---|---|
| "Package installation failed" | A bare `.ipk` was uploaded instead of the WebUI archive, or the version is not newer than the installed one. Upload `rut360gw_<version>_RUT36X_R_00.07.14.5.tar.gz`. Details: `logread -e opkg`. |
| "Not compatible with Firmware" | The router does not run exactly `RUT36X_R_00.07.14.5`. Other firmware versions are not supported. |
| `rut360gw-runtime: not enough flash space ... Nothing was modified.` | Free some flash space (`df -k /usr/local`, remove unused packages), then try again. Do not force with `--force-space`. |
| Log `embedded runtime damaged (sha256)` | The runtime archive in flash is corrupted. Reinstall the WebUI archive. Meanwhile the gateway downloads the official runtime packages (fallback). |
| Page `/rut360gw/` returns *Not Found* or *Access denied* | Use the trailing slash. Sign in again with the RutOS admin account. After a manual install, run `/etc/init.d/rpcd reload`. |
| The LAN port drops for 2 s during an install or a settings change | RutOS reapplies its network configuration during `opkg install`. Never use `reload_config`; use `rut360gw-config apply`. |
| Configuration refused | `rut360gw-config generate` prints the invalid value, and nothing is committed. `rut360gw-config show` shows the current settings. |
| `modem 2c7c:0306: interface N not found` | The modem is missing or was re-enumerated. Check `rut360gw-config ports`. Interface 2 is never allowed. |

## Reading the logs

- **Web page > Logs**: a readable event log, newest first. It shows:
  - one line per finished call: direction, number with only the first 4 characters shown,
    result, talk time;
  - SMS and USSD events;
  - gateway starts and problems.

  Filters: *Calls*, *SMS*, *USSD*, *Gateway*, *Problems*. **Show raw log** shows the raw
  lines. The RutOS log is in RAM and is cleared at reboot.
- **SSH**:

  ```sh
  logread -e rut360gw          # gateway, SMS bridge, firewall, RutOS alignment, calls
  logread -e asterisk          # Asterisk and the driver
  logread -f                   # follow live
  ```

- **Asterisk console** (`rut360gw-cli "<command>"`, or `rut360gw-cli` for an interactive console):

  | Command | Shows |
  |---|---|
  | `quectel show devices` | Modem device state (`Free`, `Ring`, `Dialing`, `NoVoice`, `Not initialized`...) |
  | `quectel show device state eg06` | Detailed modem state (voice, signal, registration) |
  | `pjsip show registrations` | Registration with the server (register mode) |
  | `pjsip show endpoints` / `pjsip show contacts` | Server and LAN client endpoints, and their contacts |
  | `core show channels` | Calls in progress |
  | `pjsip set logger on` / `off` | SIP trace, shown in the interactive console (`rut360gw-cli` with no argument) |

  Asterisk itself sends only warnings and errors to the system log. Its verbose output is
  shown in the interactive console.
- `rut360gw-config show` shows the effective configuration (passwords masked).
- `rut360gw-runtime status` shows the runtime, the available RAM, and the `/tmp` and flash
  usage.
