#!/usr/bin/env python3
"""Simulated EG06 audio port (ttyUSB1, serial voice AT+QPCMV=1,0), started by socat on a pty.

Reads and discards the voice written by the driver. While the file given as argument exists
(network_end command of the simulated modem), it stops reading: the pty buffer fills up and the
driver gets EAGAIN when writing voice, as seen on a real EC25 at the end of a call.
"""
import os
import select
import sys
import time

STALL = sys.argv[1]
fd = sys.stdin.buffer.raw.fileno()
while True:
    if os.path.exists(STALL):
        time.sleep(0.05)
        continue
    r, _, _ = select.select([fd], [], [], 0.2)
    if r and not os.read(fd, 4096):
        break
