#!/usr/bin/env python3
"""Minimal simulator of a Quectel EG06 AT port (as seen by chan_quectel on ttyUSB3).

Reproduces the behaviour observed on the RUT360: URCs (RING, +QIND, +CMTI) go to ANOTHER
port (gsmd); this port only receives responses. Call tracking must therefore work through
AT+CLCC polling alone.

Like the real modem, AT+QHUP=<cause>,<idx> only hangs up voice call <idx>: an unknown index,
or the index of a data connection, answers +CME ERROR. AT+CHUP hangs up every voice call,
never data.

Started by socat on a pty: stdin/stdout = the serial port.
Scenario control: FIFO file given as argument, one command per line:
    ring <number>      incoming call (idx 3, stat 4)
    remote_hangup      the remote party hangs up
    answer_remote      the callee answers an outgoing call (alerting -> active)
    refuse_hangup <n> [qhup|all|gone]
                       the next n hangups are refused (seen on a real EG06):
                       qhup  AT+QHUP answers +CME ERROR and the call goes on; AT+CHUP works
                       all   every hangup (QHUP, CHUP, ATH, CHLD=1x) answers ERROR, the call goes on
                       gone  AT+QHUP answers ERROR although the call is already released
    list_delay <s> [sticky]
                       the next outgoing call only shows up in AT+CLCC <s> seconds after the
                       OK of its ATD (seen on a real EG06 during a 4G -> 3G fallback). With sticky,
                       any hangup during that delay answers ERROR and the call shows up anyway
    add_call <idx> <dir> <stat>
                       voice call unknown to the driver (dir 0 outgoing, 1 incoming)
    dump               writes "CALLS <n>" to the log: number of voice calls in the modem
    network_end        call ended by the network (seen on a real EC25): audio port stalled,
                       NO CARRIER, call removed from polling; the audio port is read again on
                       the next call
    refuse_qpcmv_query <n>
                       the next n AT+QPCMV? answer ERROR, like a restarting modem (AT port ready
                       before the voice stack, seen on a real EC25). The counter is kept in a file
                       next to the log: it survives the simulator restart when the driver closes
                       and reopens the port. When restarted with refusals pending, the simulator
                       also echoes commands until ATE0
    urc on|off         URC mode, like an EC25 in URC mode: RING and +QIND "ccinfo" on every
                       change of call state; the "dialing" URC is sent BEFORE the OK of ATD
Log of every command received: argument 2 (file).
"""
import os
import re
import select
import sys
import time

CTRL, LOG = sys.argv[1], sys.argv[2]
calls = {}  # idx -> dict(dir, stat, num, visible_at, sticky)
refuse = {"n": 0, "mode": "qhup"}  # hangups to refuse (refuse_hangup control command)
delay = {"s": 0.0, "sticky": False}  # listing delay of the next outgoing call (list_delay)
urc = {"on": False}  # URC mode (EC25): +QIND "ccinfo" on every change of call state
log =open(LOG, "a", buffering=1)
QPCMV_REFUSE = os.path.join(os.path.dirname(os.path.abspath(LOG)), "qpcmv_refuse")
AUDIO_STALL = os.path.join(os.path.dirname(os.path.abspath(LOG)), "audio_stall")


def qpcmv_pending():
    try:
        with open(QPCMV_REFUSE) as f:
            return int(f.read().strip() or 0) > 0
    except (OSError, ValueError):
        return False


# after a reset (simulator restarted with AT+QPCMV? refusals pending), the real modem echoes
# commands until ATE0 (seen on a real EC25)
echo = {"on": qpcmv_pending()}


def audio(stall):
    """Audio port stalled (the modem no longer reads it) or read again: see fake_audio in the bench."""
    if stall:
        open(AUDIO_STALL, "w").close()
    elif os.path.exists(AUDIO_STALL):
        os.remove(AUDIO_STALL)


def qpcmv_refused():
    """Consumes one AT+QPCMV? refusal (refuse_qpcmv_query); true if one was left."""
    try:
        with open(QPCMV_REFUSE) as f:
            n = int(f.read().strip() or 0)
    except (OSError, ValueError):
        return False
    if n <= 0:
        return False
    with open(QPCMV_REFUSE, "w") as f:
        f.write(str(n - 1))
    return True

# "data/IMS" lines always present on the real EG06 (mode=1): the driver must ignore them.
IMS_LINES = ['+CLCC: 1,1,0,1,0,"",128', '+CLCC: 2,1,0,1,0,"",128']
VOICE_BASE = 3  # first free voice indexes on the real modem


def out(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def reply(lines=(), final="OK"):
    for line in lines:
        out("\r\n" + line + "\r\n")
    out("\r\n" + final + "\r\n")


STATIC = {
    "AT+CGMI": ["Quectel"],
    "AT+CGMM": ["EG06"],
    "AT+CGMR": ["EG06ELAR04A04M4G"],
    "AT+CGSN": ["860000000000001"],
    "AT+CIMI": ["208150000000001"],
    "AT+CPIN?": ["+CPIN: READY"],
    "AT+CREG?": ['+CREG: 2,1,"C1E","6722C34",7'],
    "AT+CEREG?": ['+CEREG: 2,1,"0C1E","6722C34",7'],
    "AT+COPS?": ['+COPS: 0,0,"Free",7'],
    "AT+CSQ": ["+CSQ: 20,99"],
    "AT+QCCID": ["+QCCID: 89330000000000000001"],
    "AT+QPCMV?": ["+QPCMV: 0,0"],
    "AT+CNUM": [],
    # GSM charset (owned by gsmd): plain names, not UCS2
    "AT+QSPN;+QNWINFO": ['+QSPN: "Free","Free","",0,"20815"', '+QNWINFO: "FDD LTE","20815","LTE BAND 1",375'],
}


def visible(c):
    return c.get("visible_at", 0.0) <= time.time()


def ccinfo(idx, c, stat=None):
    """URC mode: +QIND "ccinfo",<idx>,<dir>,<state>,<mode>,<mpty>,<number>,<type> (state -1: call ended)."""
    if urc["on"]:
        s = c["stat"] if stat is None else stat
        out('\r\n+QIND: "ccinfo",%d,%d,%d,0,0,"%s",145\r\n' % (idx, c["dir"], s, c["num"]))
        log.write("%.3f URC ccinfo %d %d\n" % (time.time(), idx, s))


def end_calls(keep=None):
    """Releases the calls (except index keep), with the end URC in URC mode."""
    for idx in [i for i in calls if i != keep]:
        ccinfo(idx, calls[idx], -1)
        del calls[idx]


def clcc_lines():
    lines = list(IMS_LINES)
    for idx, c in sorted(calls.items()):
        if visible(c):
            lines.append('+CLCC: %d,%d,%d,0,0,"%s",145' % (idx, c["dir"], c["stat"], c["num"]))
    return lines


def hangup(u):
    """AT+CHUP / ATH / AT+QHUP / AT+CHLD=1x."""
    qhup = u.startswith("AT+QHUP")
    if refuse["n"] > 0 and (refuse["mode"] == "all" or qhup):
        refuse["n"] -= 1
        if refuse["mode"] == "qhup":
            return reply(final="+CME ERROR: operation not allowed")
        if refuse["mode"] == "gone":
            end_calls()
        return reply(final="ERROR")
    # call being set up (list_delay sticky): the modem refuses to hang it up
    if any(c.get("sticky") and not visible(c) for c in calls.values()):
        return reply(final="ERROR")
    if qhup:
        m = re.match(r"AT\+QHUP=\d+,(\d+)$", u)
        idx = int(m.group(1)) if m else -1
        if idx not in calls:
            return reply(final="+CME ERROR: operation not allowed")  # unknown index or data
        reply()
        ccinfo(idx, calls[idx], -1)
        del calls[idx]
        return None
    reply()
    end_calls()
    return None


def handle(cmd):
    log.write("%.3f %s\n" % (time.time(), cmd))
    u = cmd.upper()
    if echo["on"]:
        out(cmd + "\r")
        if u == "ATE0":
            echo["on"] = False
    if u == "AT+QPCMV?" and qpcmv_refused():
        return reply(final="ERROR")
    if u in STATIC:
        return reply(STATIC[u])
    if u == "AT+CLCC":
        return reply(clcc_lines())
    if u == "ATA":
        reply()
        for idx, c in calls.items():
            if c["dir"] == 1 and c["stat"] == 4:
                c["stat"] = 0
                ccinfo(idx, c)
        return None
    if u.startswith("ATD"):
        num = cmd[3:].rstrip(";")
        if num.startswith("000"):
            # global CMEE=2 (gsmd): verbose error
            return reply(final="+CME ERROR: operation not allowed")
        if calls:
            return reply(final="+CME ERROR: operation not allowed")  # a call is already in progress
        audio(False)
        calls[VOICE_BASE] = {"dir": 0, "stat": 2, "num": num,
                             "visible_at": time.time() + delay["s"], "sticky": delay["sticky"]}
        delay["s"], delay["sticky"] = 0.0, False
        # URC mode: like the EC25, the "dialing" URC is sent BEFORE the OK of ATD
        ccinfo(VOICE_BASE, calls[VOICE_BASE])
        reply()
        calls[VOICE_BASE]["stat"] = 3  # alerting as soon as it is listed
        ccinfo(VOICE_BASE, calls[VOICE_BASE])
        return None
    if u in ("AT+CHUP", "ATH") or u.startswith("AT+QHUP") or u.startswith("AT+CHLD=1"):
        return hangup(u)
    if u.startswith("AT+QPCMV=1"):
        # like the real EG06: serial voice refused during a voice call
        if any(visible(c) for c in calls.values()):
            return reply(final="ERROR")
        return reply()
    if u.startswith("AT+CSCS") or u.startswith("AT+CMGF") or u.startswith("AT+CNMI") or u.startswith("AT+CPMS"):
        return reply()  # accepted, but a test checks they are NOT sent in RutOS mode
    return reply()


def control(line):
    log.write("%.3f CTRL %s\n" % (time.time(), line))
    parts = line.split()
    if not parts:
        return
    if parts[0] == "network_end":
        # call ended by the network, as recorded on a real EC25: the modem stops reading the audio
        # port (the driver gets EAGAIN when writing voice), sends NO CARRIER on this port, then the
        # call disappears from the next AT+CLCC poll
        audio(True)
        time.sleep(0.3)
        out("\r\nNO CARRIER\r\n")
        end_calls()
    elif parts[0] == "ring":
        audio(False)
        calls[VOICE_BASE] = {"dir": 1, "stat": 4, "num": parts[1] if len(parts) > 1 else "+33600000000"}
        if urc["on"]:
            out("\r\nRING\r\n")
        ccinfo(VOICE_BASE, calls[VOICE_BASE])
    elif parts[0] == "remote_hangup":
        end_calls()
    elif parts[0] == "urc":
        urc["on"] = len(parts) > 1 and parts[1] == "on"
    elif parts[0] == "refuse_hangup":
        refuse["n"] = int(parts[1]) if len(parts) > 1 else 1
        refuse["mode"] = parts[2] if len(parts) > 2 else "qhup"
    elif parts[0] == "list_delay":
        delay["s"] = float(parts[1]) if len(parts) > 1 else 0.0
        delay["sticky"] = len(parts) > 2 and parts[2] == "sticky"
    elif parts[0] == "add_call" and len(parts) == 4:
        calls[int(parts[1])] = {"dir": int(parts[2]), "stat": int(parts[3]), "num": "+33600000099"}
    elif parts[0] == "refuse_qpcmv_query":
        with open(QPCMV_REFUSE, "w") as f:
            f.write(parts[1] if len(parts) > 1 else "1")
    elif parts[0] == "dump":
        log.write("%.3f CALLS %d\n" % (time.time(), len(calls)))
    elif parts[0] == "answer_remote":
        for idx, c in calls.items():
            if c["dir"] == 0:
                c["stat"] = 0
                ccinfo(idx, c)


def main():
    fd_ctrl = os.open(CTRL, os.O_RDWR | os.O_NONBLOCK)
    buf = b""
    cbuf = b""
    stdin = sys.stdin.buffer.raw
    while True:
        r, _, _ = select.select([stdin, fd_ctrl], [], [], 1.0)
        if stdin in r:
            data = os.read(stdin.fileno(), 1024)
            if not data:
                return
            buf += data
            while b"\r" in buf:
                line, buf = buf.split(b"\r", 1)
                line = line.strip(b"\n").decode(errors="replace").strip()
                if line:
                    handle(line)
        if fd_ctrl in r:
            cbuf += os.read(fd_ctrl, 1024)
            while b"\n" in cbuf:
                line, cbuf = cbuf.split(b"\n", 1)
                control(line.decode().strip())


if __name__ == "__main__":
    main()
