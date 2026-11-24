#!/usr/bin/env python3
"""Fake SIP server (Asterisk/FreePBX) for the bench: "register" mode of rut360gw.

UDP, a single gateway. Requires digest authentication (MD5) for REGISTER and MESSAGE, like a
PBX, with the account given as argument. Logs every request received to the log file:
    REGISTER-401 / REGISTER-200 contact=<registered contact>
    INVITE ruri=<...> from=<...> pai=<...>  (answers 100 then 486 Busy Here)
    MESSAGE-401 / MESSAGE-200 ruri=<...> from=<...> body=<...>
    OPTIONS                                  (answers 200)
    RESPONSE <code reason> cseq=<...>        (response from the gateway to a request sent below)
Control: FIFO file, one command per line:
    invite <number>          sends an INVITE to the registered contact (call from the softphone to GSM)
    cancel                   cancels that INVITE
    message <number> <text>  sends a MESSAGE to the registered contact (SMS from the softphone)

    python3 fake_registrar.py <port> <user> <password> <log> <fifo>
"""
import hashlib
import os
import random
import re
import select
import socket
import sys
import time

PORT, USER, PASSWORD, LOG, CTRL = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
REALM = "bench"
md5 = lambda s: hashlib.md5(s.encode()).hexdigest()  # noqa: E731
log = open(LOG, "a", buffering=1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", PORT))
nonces = set()
state = {"contact": None, "peer": None, "invite": None}


def w(line):
    log.write("%.3f %s\n" % (time.time(), line))


def parse(data):
    text = data.decode(errors="replace")
    head, _, body = text.partition("\r\n\r\n")
    lines = head.split("\r\n")
    hdr = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        hdr.setdefault(k.strip().lower(), v.strip())
    return lines[0], hdr, lines, body


def respond(lines, hdr, addr, code, reason, extra=""):
    keep = [ln for ln in lines[1:] if ln.split(":")[0].strip().lower() in ("via", "v", "from", "f", "call-id", "i", "cseq")]
    to = hdr.get("to", hdr.get("t", ""))
    if code >= 200 and ";tag=" not in to:
        to += ";tag=bench%d" % random.randint(1000, 9999)
    msg = "SIP/2.0 %d %s\r\n%s\r\nTo: %s\r\n%sContent-Length: 0\r\n\r\n" % (code, reason, "\r\n".join(keep), to, extra)
    sock.sendto(msg.encode(), addr)


def authorized(hdr, method, uri):
    a = hdr.get("authorization", "")
    if not a:
        return False
    f = dict(re.findall(r'(\w+)="?([^",]*)"?', a))
    if f.get("username") != USER or f.get("nonce") not in nonces:
        return False
    ha1 = md5("%s:%s:%s" % (USER, REALM, PASSWORD))
    ha2 = md5("%s:%s" % (method, f.get("uri", uri)))
    if f.get("qop"):
        exp = md5("%s:%s:%s:%s:%s:%s" % (ha1, f["nonce"], f.get("nc", ""), f.get("cnonce", ""), f["qop"], ha2))
    else:
        exp = md5("%s:%s:%s" % (ha1, f["nonce"], ha2))
    return f.get("response") == exp


def challenge(lines, hdr, addr):
    n = "%x" % random.getrandbits(64)
    nonces.add(n)
    respond(lines, hdr, addr, 401, "Unauthorized", 'WWW-Authenticate: Digest realm="%s", nonce="%s", algorithm=MD5\r\n' % (REALM, n))


def send_invite(num):
    if not state["contact"]:
        w("INVITE-OUT impossible: no registered contact")
        return
    # registered contact: <sip:account@host:port;line=xxx> -> sip:<number>@host:port;line=xxx
    m = re.search(r"sip:(?:[^@>;]+@)?([^>;]+)([^>]*)", state["contact"])
    ruri = "sip:%s@%s" % (num, m.group(1))
    line = re.search(r";line=([^;>]+)", m.group(2))
    if line:
        ruri += ";line=" + line.group(1)
    branch = "z9hG4bK%x" % random.getrandbits(48)
    callid = "bench%x" % random.getrandbits(48)
    sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
    base = ("Via: SIP/2.0/UDP 127.0.0.1:%d;branch=%s;rport\r\nFrom: <sip:105@127.0.0.1>;tag=f%x\r\nTo: <%s>\r\n"
            "Call-ID: %s\r\nMax-Forwards: 70\r\n") % (PORT, branch, random.getrandbits(32), ruri, callid)
    state["invite"] = (ruri, base)
    msg = "INVITE %s SIP/2.0\r\n%sCSeq: 1 INVITE\r\nContact: <sip:105@127.0.0.1:%d>\r\nContent-Type: application/sdp\r\nContent-Length: %d\r\n\r\n%s" % (
        ruri, base, PORT, len(sdp), sdp)
    sock.sendto(msg.encode(), state["peer"])
    w("INVITE-OUT ruri=%s" % ruri)


def send_message(num, text):
    if not state["contact"]:
        w("MESSAGE-OUT impossible: no registered contact")
        return
    # same request URI as an INVITE: the line parameter attributes it to the server endpoint
    m = re.search(r"sip:(?:[^@>;]+@)?([^>;]+)([^>]*)", state["contact"])
    ruri = "sip:%s@%s" % (num, m.group(1))
    line = re.search(r";line=([^;>]+)", m.group(2))
    if line:
        ruri += ";line=" + line.group(1)
    msg = ("MESSAGE %s SIP/2.0\r\nVia: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bK%x;rport\r\n"
           "From: <sip:105@127.0.0.1>;tag=f%x\r\nTo: <%s>\r\nCall-ID: bench%x\r\nCSeq: 1 MESSAGE\r\n"
           "Max-Forwards: 70\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s") % (
        ruri, PORT, random.getrandbits(48), random.getrandbits(32), ruri, random.getrandbits(48), len(text), text)
    sock.sendto(msg.encode(), state["peer"])
    w("MESSAGE-OUT ruri=%s" % ruri)


def send_cancel():
    if not state["invite"]:
        return
    ruri, base = state["invite"]
    sock.sendto(("CANCEL %s SIP/2.0\r\n%sCSeq: 1 CANCEL\r\nContent-Length: 0\r\n\r\n" % (ruri, base)).encode(), state["peer"])
    w("CANCEL-OUT")


def handle(data, addr):
    first, hdr, lines, body = parse(data)
    if first.startswith("SIP/2.0"):
        w("RESPONSE %s cseq=%s" % (first[8:], hdr.get("cseq", "")))
        if first[8:11] in ("180", "183", "200", "486", "487") and state["invite"] and "INVITE" in hdr.get("cseq", ""):
            if first[8:11] == "200" or int(first[8:11]) >= 300:
                ruri, base = state["invite"]
                to = hdr.get("to", "")
                sock.sendto(("ACK %s SIP/2.0\r\n%sCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n" % (ruri, base.replace("To: <%s>" % ruri, "To: %s" % to))).encode(), addr)
        return
    method, uri = first.split()[0], first.split()[1]
    if method == "REGISTER":
        if not authorized(hdr, method, uri):
            w("REGISTER-401")
            return challenge(lines, hdr, addr)
        state["contact"], state["peer"] = hdr.get("contact", hdr.get("m", "")), addr
        w("REGISTER-200 contact=%s" % state["contact"])
        return respond(lines, hdr, addr, 200, "OK", "Contact: %s;expires=300\r\nExpires: 300\r\n" % state["contact"])
    if method == "MESSAGE":
        if not authorized(hdr, method, uri):
            w("MESSAGE-401")
            return challenge(lines, hdr, addr)
        w("MESSAGE-200 ruri=%s from=%s body=%s" % (uri, hdr.get("from", hdr.get("f", "")), body.strip()))
        return respond(lines, hdr, addr, 200, "OK")
    if method == "INVITE":
        w("INVITE ruri=%s from=%s pai=%s" % (uri, hdr.get("from", hdr.get("f", "")), hdr.get("p-asserted-identity", "")))
        respond(lines, hdr, addr, 100, "Trying")
        return respond(lines, hdr, addr, 486, "Busy Here")
    if method == "ACK":
        return
    w(method)
    respond(lines, hdr, addr, 200, "OK")


def main():
    fd = os.open(CTRL, os.O_RDWR | os.O_NONBLOCK)
    cbuf = b""
    while True:
        r, _, _ = select.select([sock, fd], [], [], 1.0)
        if sock in r:
            data, addr = sock.recvfrom(65535)
            handle(data, addr)
        if fd in r:
            cbuf += os.read(fd, 1024)
            while b"\n" in cbuf:
                line, cbuf = cbuf.split(b"\n", 1)
                parts = line.decode().split()
                if parts and parts[0] == "invite":
                    send_invite(parts[1] if len(parts) > 1 else "0612345690")
                elif parts and parts[0] == "cancel":
                    send_cancel()
                elif parts and parts[0] == "message":
                    send_message(parts[1] if len(parts) > 1 else "0612345690", " ".join(parts[2:]) or "bonjour")


if __name__ == "__main__":
    main()
