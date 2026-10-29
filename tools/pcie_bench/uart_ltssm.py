#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read Pango PCIe LTSSM logger UART output and decode every record line.

Usage:
    py -3 tools/pcie_bench/uart_ltssm.py <COM port> <seconds> <output file>

Record format emitted by the FPGA (16 bytes):
    <8 hex ts> <sp> <2 hex flags> <sep> <2 hex state> CR LF
where <sep> is a space, or '!' when one or more events were dropped.
"""

import datetime
import sys
import time

try:
    import serial
except ImportError:
    print("pyserial is required: py -3 -m pip install pyserial", file=sys.stderr)
    sys.exit(2)

BAUD = 921600

STATE_NAMES = {
    0x00: "DETECT_QUIET",
    0x01: "DETECT_ACT",
    0x02: "POLL_ACTIVE",
    0x03: "POLL_COMPLIANCE",
    0x04: "POLL_CONFIG",
    0x05: "PRE_DETECT_QUIET",
    0x06: "DETECT_WAIT",
    0x07: "CFG_LINKWD_START",
    0x08: "CFG_LINKWD_ACEPT",
    0x09: "CFG_LANENUM_WAIT",
    0x0A: "CFG_LANENUM_ACEPT",
    0x0B: "CFG_COMPLETE",
    0x0C: "CFG_IDLE",
    0x0D: "RCVRY_LOCK",
    0x0E: "RCVRY_SPEED",
    0x0F: "RCVRY_RCVRCFG",
    0x10: "RCVRY_IDLE",
    0x11: "L0",
    0x12: "L0S",
    0x13: "L123_SEND_EIDLE",
    0x14: "L1_IDLE",
    0x15: "L2_IDLE",
    0x16: "L2_WAKE",
    0x17: "DISABLED_ENTRY",
    0x18: "DISABLED_IDLE",
    0x19: "DISABLED",
    0x1A: "LPBK_ENTRY",
    0x1B: "LPBK_ACTIVE",
    0x1C: "LPBK_EXIT",
    0x1D: "LPBK_EXIT_TIMEOUT",
    0x1E: "HOT_RESET_ENTRY",
    0x1F: "HOT_RESET",
}

FLAG_BITS = [
    (7, "PERST"),
    (6, "PLL"),
    (5, "TXD"),
    (4, "CDR1"),
    (3, "CDR0"),
    (2, "LSM1"),
    (1, "LSM0"),
    (0, "LINK"),
]


def timestamp():
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]


def decode_line(raw):
    """Decode one raw record line, or return None if it is not parseable."""
    line = raw.rstrip("\r\n")
    if len(line) < 14:
        return None
    ts_hex = line[0:8]
    if line[8:9] != " ":
        return None
    flags_hex = line[9:11]
    sep = line[11:12]
    state_hex = line[12:14]
    if sep not in (" ", "!"):
        return None
    try:
        int(ts_hex, 16)
        flags = int(flags_hex, 16)
        state = int(state_hex, 16)
    except ValueError:
        return None
    if state > 0x1F or flags > 0xFF:
        return None
    dropped = (sep == "!")
    state_name = STATE_NAMES.get(state, "UNKNOWN_%02X" % state)
    flags_txt = ",".join(
        "%s=%d" % (name, (flags >> bit) & 1) for bit, name in FLAG_BITS
    )
    text = "ts=0x%s flags=%s [%s] state=0x%02X %s" % (
        ts_hex.upper(), flags_hex.upper(), flags_txt, state, state_name
    )
    if dropped:
        text += " DROPPED"
    return text


def emit(fout, raw):
    decoded = decode_line(raw)
    if decoded is None:
        out_line = "%s <%s>" % (timestamp(), raw)
    else:
        out_line = "%s <%s> %s" % (timestamp(), raw, decoded)
    print(out_line)
    fout.write(out_line + "\n")
    fout.flush()


def main():
    if len(sys.argv) != 4:
        print("usage: py -3 uart_ltssm.py <COM port> <seconds> <output file>",
              file=sys.stderr)
        return 2
    port = sys.argv[1]
    seconds = float(sys.argv[2])
    out_path = sys.argv[3]

    end_time = time.time() + seconds
    buf = b""

    with open(out_path, "w", encoding="utf-8", errors="replace") as fout, \
            serial.Serial(port, BAUD, timeout=0.1) as ser:
        while time.time() < end_time:
            chunk = ser.read(256)
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                raw_bytes, buf = buf.split(b"\n", 1)
                emit(fout, raw_bytes.decode("ascii", errors="replace"))
        if buf:
            emit(fout, buf.decode("ascii", errors="replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
