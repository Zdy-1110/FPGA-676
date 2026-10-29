# -*- coding: utf-8 -*-
"""Send '|'-separated commands to the U-Boot console on COM14 and print replies.

Usage: py uboot_cmd.py "cmd1|cmd2|cmd3"
The reply for each command is gathered until the U-Boot prompt reappears
(quiet period with a trailing '=>'), or until a hard timeout.
"""
import serial
import sys
import time

PORT = "COM9"


def read_until_prompt(s, timeout=30.0, quiet=1.5, hard_quiet=8.0):
    end = time.time() + timeout
    buf = bytearray()
    quiet_start = None
    while time.time() < end:
        chunk = s.read(4096)
        if chunk:
            buf.extend(chunk)
            quiet_start = None
        else:
            now = time.time()
            if quiet_start is None:
                quiet_start = now
            elif buf:
                idle = now - quiet_start
                tail = bytes(buf[-80:]).rstrip()
                if idle > quiet and tail.endswith(b"=>"):
                    break
                if idle > hard_quiet:
                    break
    return bytes(buf)


def main():
    if len(sys.argv) < 2:
        print("usage: py uboot_cmd.py \"cmd1|cmd2\"")
        return
    cmds = [c.strip() for c in sys.argv[1].split("|")]
    s = serial.Serial(PORT, 115200, timeout=0.1)
    try:
        for c in cmds:
            print("### SEND: %s" % c, flush=True)
            s.write(c.encode() + b"\r\n")
            out = read_until_prompt(s)
            print(out.decode("utf-8", "replace"), flush=True)
            print("### END", flush=True)
    finally:
        s.close()


if __name__ == "__main__":
    main()
