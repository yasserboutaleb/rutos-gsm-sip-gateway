# Configuring the SIP server

This page shows how to connect the gateway to an **Asterisk** server with `chan_pjsip`
(Asterisk 16 or later), in both modes, and gives notes for FreePBX. It also describes the
exact SIP messages the gateway sends and accepts, so that you can adapt it to another server.

Example values used on this page:

| Value | Example |
|---|---|
| SIP server | `pbx.example.com` |
| Gateway account on the server (`register` mode) | `gw1` |
| Extension of the user's softphone, which receives GSM calls and SMS | `101` |
| VPN subnet (`ip` mode) | `10.8.0.0/24`: server `10.8.0.1`, gateway `10.8.0.2` |

## What the gateway sends and accepts

| Direction | Request | Details |
|---|---|---|
| Gateway -> server: **incoming GSM call** | `INVITE sip:<server.extension>@<server.host>:<port>` | **register**: `From: "<caller number>" <sip:<username>@<server.host>>`, plus `P-Asserted-Identity` with the caller number. The gateway answers digest challenges with its account. **ip**: `From: <sip:<caller number>@<gateway address>>`. The gateway rings the server for up to 60 s, and the GSM call is answered only when the server answers. If the server replies busy, is unreachable or congested, the GSM call is rejected as **busy** (cause 17), so the operator's forward-on-busy or voicemail applies. If there is no answer, it is a normal hang-up. |
| Server -> gateway: **outgoing call** | `INVITE sip:<number>@<gateway>` | Number: digits, optionally with a leading `+` (pattern `[+0-9]...`). Dialled for up to 120 s. Ringback: see `features.ringback`. |
| Server -> gateway: **USSD** | `INVITE sip:*<code>#@<gateway>` | Request user starting with `*` or `#`, containing only digits, `*` and `#` (`%23` is accepted for `#`). The gateway answers, plays a short beep, hangs up, and sends the network's reply as a `MESSAGE` to `server.extension`. |
| Server -> gateway: **echo test** | `INVITE sip:9600@<gateway>` | The gateway answers and echoes the audio back, without using the mobile network. It checks the server <-> gateway audio path. |
| Gateway -> server: **received SMS** | `MESSAGE sip:<server.extension>@<server.host>` | Body: `SMS from <sender> (<date>):` followed by the text. **register**: `From: "<sender>" <sip:<username>@<server.host>>`, the sender is the display name, and the gateway answers digest challenges. **ip**: `From: <sip:<sender>@<server.local_address>>`. USSD replies use the sender `ussd`. Failure notices use the sender `gsm-rut360`. |
| Server -> gateway: **SMS to send** | `MESSAGE sip:<number>@<gateway>` | The body is sent as an SMS to `<number>` (digits and an optional `+`). If sending fails, the gateway sends back a `MESSAGE` *"SMS to <number> could not be sent"*. |
| Gateway -> server | `REGISTER` (**register** mode only) | Every 300 s, `Contact` with a `line` parameter. Retried every 60 s after a failure, and every 600 s after a 403. |
| Gateway -> server | `OPTIONS` | Every 60 s (qualify). |

Media: RTP/AVP, G.711 (`server.codec`: `ulaw` and/or `alaw`), DTMF RFC 4733, no SRTP.
The gateway hangs up an answered call after **60 s without RTP** (`rtp_timeout`). Use the same
setting on the server side.

### How the gateway recognises its server

- **register mode**: the gateway accepts a request from the server only when it arrives on
  the **registered line**: the Request-URI must carry the `line` parameter of the `Contact`
  the gateway registered. Any other request is rejected, so nobody else can call or send SMS
  through the gateway.
  - Calls: dialling `PJSIP/<number>@gw1` sends the call to the registered contact, with the
    user part replaced by the number. This works without anything special.
  - **SIP MESSAGE: `MessageSend()` must target the registered contact explicitly.** Replace
    the user part of the contact with the destination number. A message sent to
    `sip:<number>@<gateway>` without the `line` parameter is rejected. See the example below.
- **ip mode**: the gateway identifies the server by its source IP address (`server.host`),
  without authentication. Use it **only over a VPN**. The gateway drops packets carrying the
  server's address that arrive from its LAN.

## Register mode (recommended)

The gateway registers with the server like a phone, which works through the 4G carrier NAT.

Gateway settings (**Setup** tab):

- *Use a remote SIP server*: on;
- *Connection*: register;
- *Server address*: `pbx.example.com`;
- *SIP port*: `5060`;
- *Username*: `gw1`;
- *Password*: the secret below;
- *Extension*: `101`.

### `pjsip.conf` (server)

```ini
; ---- the gateway: registers as gw1, receives calls/SMS for the mobile network
[gw1]
type = endpoint
context = from-gw1                 ; incoming GSM calls
message_context = from-gw1-msg     ; received SMS and USSD replies
disallow = all
allow = ulaw                       ; same as rut360gw.server.codec
auth = gw1-auth
aors = gw1
direct_media = no
rtp_symmetric = yes                ; the gateway is behind NAT: send RTP back where it comes from
force_rport = yes
rewrite_contact = yes              ; see "NAT" below
rtp_timeout = 60                   ; hang up if the gateway disappears during a call
dtmf_mode = rfc4733

[gw1-auth]
type = auth
auth_type = userpass
username = gw1
password = <long random secret>

[gw1]
type = aor
max_contacts = 1                   ; one contact only: MessageSend targets it
remove_existing = yes
qualify_frequency = 60

; ---- the user's softphone
[101]
type = endpoint
context = from-phones
message_context = from-phones-msg
disallow = all
allow = ulaw,alaw
auth = 101-auth
aors = 101
direct_media = no
rtp_symmetric = yes
force_rport = yes
rewrite_contact = yes
rtp_timeout = 60
dtmf_mode = rfc4733

[101-auth]
type = auth
auth_type = userpass
username = 101
password = <another secret>

[101]
type = aor
max_contacts = 1
remove_existing = yes
```

### `extensions.conf` (server)

```ini
; ---- calls coming from the gateway (incoming GSM calls): Request-URI user = rut360gw.server.extension
[from-gw1]
exten => 101,1,NoOp(GSM call from ${CALLERID(name)})
 ; register mode: From user = gw1, caller number = display name (also in P-Asserted-Identity)
 same => n,Set(CALLERID(num)=${CALLERID(name)})
 same => n,Dial(PJSIP/101,60)
 ; busy or unreachable: reply "busy" so that the gateway rejects the GSM call as busy
 ; (the operator then applies forward-on-busy / voicemail)
 same => n,GotoIf($["${DIALSTATUS}" = "NOANSWER"]?done)
 same => n,Hangup(17)
 same => n(done),Hangup()

; ---- SMS and USSD replies coming from the gateway -> softphone 101
[from-gw1-msg]
exten => 101,1,Set(F=${MESSAGE(from)})
 ; register mode: the sender (number, "ussd" or "gsm-rut360") is the display name
 same => n,Set(SENDER=${FILTER(0-9a-zA-Z+,${CUT(F,<,1)})})
 ; From = <sip:sender@pbx>, so that the softphone's reply goes back to that number
 same => n,MessageSend(pjsip:101,<sip:${SENDER}@pbx.example.com>)
 same => n,Hangup()

; ---- calls from the softphone
[from-phones]
exten => 101,1,Dial(PJSIP/101,30)
; echo test of the gateway (server <-> gateway audio, no GSM cost)
exten => 9600,1,Dial(PJSIP/9600@gw1,30)
; USSD: *code# (the reply comes back as a message)
exten => _[*#].,1,Dial(PJSIP/${EXTEN}@gw1,30)
; mobile numbers: national (0...) and international (+...); adapt to your numbering plan
exten => _0X.,1,Dial(PJSIP/${EXTEN}@gw1,120)
exten => _+X.,1,Dial(PJSIP/${EXTEN}@gw1,120)

; ---- messages from the softphone to a number -> SMS through the gateway
[from-phones-msg]
exten => _[+0-9].,1,NoOp(SMS to ${EXTEN})
 ; the gateway's registered contact, e.g. sip:gw1@203.0.113.7:5060;line=abcdefg
 same => n,Set(CONTACT=${PJSIP_CONTACT(${PJSIP_AOR(gw1,contact)},uri)})
 ; same contact (it carries the "line" parameter), user part replaced by the number
 same => n,MessageSend(pjsip:gw1/${STRREPLACE(CONTACT,gw1@,${EXTEN}@)},<sip:101@pbx.example.com>)
 same => n,NoOp(MessageSend: ${MESSAGE_SEND_STATUS})
 same => n,Hangup()
```

Written as a single line, the `MessageSend` above is:

```
MessageSend(pjsip:<endpoint>/<registered contact with "<account>@" replaced by "<number>@">,<sip:<from>@<server>>)
```

`STRREPLACE()` takes a **variable name** as its first argument, which is why the contact is
stored in `CONTACT` first. Restrict who may send SMS, for example only from the
`from-phones-msg` context of trusted endpoints: every message becomes a paid SMS.

## IP mode (trusted peer over a VPN)

Use this mode only when the gateway and the server share a private network, for example a
WireGuard, OpenVPN or IPsec tunnel that you configure in RutOS. No password is used: anyone
who can send packets from the gateway's VPN address can place calls through it.

Gateway settings (**Setup** tab):

- *Connection*: trusted peer;
- *Server address*: `10.8.0.1`;
- *SIP port*: `5060`;
- *Extension*: `101`;
- *Gateway address in the VPN*: `10.8.0.2`.

On the router, the VPN firewall zone must accept, from `10.8.0.1`:

- UDP 5060;
- the RTP range, UDP 10000-10100 by default (`features.rtp_start` / `rtp_end`).

The gateway does not configure the VPN or its firewall zone.

### `pjsip.conf` (server)

```ini
[gw1]
type = endpoint
context = from-gw1
message_context = from-gw1-msg
disallow = all
allow = ulaw
aors = gw1
direct_media = no
rtp_symmetric = yes
rtp_timeout = 60
dtmf_mode = rfc4733

[gw1]
type = aor
contact = sip:10.8.0.2:5060
qualify_frequency = 60

[gw1-identify]
type = identify
endpoint = gw1
match = 10.8.0.2
```

The softphone `101` is the same as in register mode.

### `extensions.conf` (server)

The differences from register mode are:

- the caller number is the `From` user part, so `CALLERID(num)` is already right;
- messages to the gateway are sent to its fixed VPN address.

```ini
[from-gw1]
exten => 101,1,Dial(PJSIP/101,60)
 same => n,GotoIf($["${DIALSTATUS}" = "NOANSWER"]?done)
 same => n,Hangup(17)
 same => n(done),Hangup()

[from-gw1-msg]
exten => 101,1,Set(F=${MESSAGE(from)})
 ; ip mode: From = <sip:sender@10.8.0.2>; keep the user part
 same => n,Set(U=${CUT(F,@,1)})
 same => n,Set(SENDER=${CUT(U,:,2)})
 same => n,MessageSend(pjsip:101,<sip:${SENDER}@10.8.0.1>)
 same => n,Hangup()

[from-phones-msg]
exten => _[+0-9].,1,MessageSend(pjsip:gw1/sip:${EXTEN}@10.8.0.2:5060,<sip:101@10.8.0.1>)
 same => n,Hangup()
```

The `[from-phones]` context is the same as in register mode (`Dial(PJSIP/<number>@gw1)`).

## NAT

- **Gateway side**: in register mode, the gateway is behind the mobile carrier's NAT and
  opens no port on the 4G WAN.
  - Signalling from the server comes back through the mapping created by the gateway's own
    `REGISTER` (every 300 s) and `OPTIONS` (every 60 s).
  - Media comes back through the mapping created by its own RTP.
  - The server endpoint therefore needs `rtp_symmetric = yes`, `force_rport = yes` and
    `direct_media = no`.
- **`rewrite_contact = yes`** on the server's gateway endpoint makes the server use the source
  address of the `REGISTER` instead of the gateway's private address. Use it only when the
  server sees the gateway's **real** (public, NATed) address. If something in front of the
  server rewrites source addresses, for example Docker's userland proxy or a SIP-unaware load
  balancer, the stored contact points to the wrong place. Run the server with host networking
  in that case.
- **Server behind NAT** (`external_media_address`, `external_signaling_address`, `local_net`
  on the transport):
  - in **register** mode, `local_net` must not include the address the server sees for the
    gateway. Otherwise the server treats the gateway as a local client and sends it its
    internal address in SDP and `Contact`. The result is no audio towards the mobile and lost
    hang-ups;
  - in **ip** mode, add the VPN subnet (`10.8.0.0/24`) to `local_net`, so that the server
    sends its VPN address, not its public one, to the gateway.
- Symptoms of a NAT problem: the call connects but there is no audio in one or both
  directions, or a hang-up is not propagated. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## FreePBX

The same logic applies. These steps have not been tested by the project, and menu names vary
between versions.

- **Register mode**: create a PJSIP trunk for the gateway with *Authentication: Inbound*,
  *Registration: Receive*, the username/secret of the gateway and *Max contacts* 1. Enable
  *Rewrite Contact*, *RTP Symmetric* and *Force rport*. Route outgoing calls (`0X.`, `+X.`
  and the `*`/`#` USSD codes) to that trunk. Add an inbound route whose DID is the
  gateway's `server.extension`.
- **IP mode**: PJSIP trunk with *Authentication: None*, *Registration: None*, *SIP Server*
  `10.8.0.2`, *Match (Permit)* `10.8.0.2`.
- **SIP MESSAGE** is not routed by the FreePBX GUI. Put the message contexts shown above in
  `extensions_custom.conf` and set the `message_context` of the trunk and of the extensions
  accordingly (for example through `pjsip.endpoint_custom_post.conf`).

## Checking

1. Gateway: **Dashboard > Self-test**. In register mode, `SIP server registration` must be
   `OK`. On the server, `pjsip show contacts` lists the gateway's contact with its `line`
   parameter.
2. From the softphone, call **9600**: you should hear your own voice, without any GSM cost.
3. Call a mobile number, then call the gateway's SIM number from a mobile.
4. Send a message from the softphone to a mobile number, then reply with an SMS.
5. Dial a USSD code such as `*100#`, which depends on the operator.
