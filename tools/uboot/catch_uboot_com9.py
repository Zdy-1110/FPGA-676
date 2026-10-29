# -*- coding: utf-8 -*-
"""Wait for the RK3568 board to be reset, interrupt autoboot, and land on the
U-Boot console (maintenance menu option 0). Logs all console traffic.

Run:  py catch_uboot_shell.py
Exit: prints FINAL_STATE=uboot (shell ready), linux (board booted), or timeout.
"""
import serial
import time
import datetime

PORT = "COM9"
RAW = r"D:\pango_work\catch_shell_raw.bin"
LOG = r"D:\pango_work\catch_shell_log.txt"
WINDOW_S = 4 * 60


def _stamp():
    return datetime.datetime.now().strftime("%H:%M:%S")


def main():
    logf = open(LOG, "a", encoding="utf-8")

    def note(msg):
        line = "[%s] %s" % (_stamp(), msg)
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    raw = open(RAW, "ab")
    note("monitor start; port=%s window=%ds" % (PORT, WINDOW_S))
    try:
        s = serial.Serial(PORT, 115200, timeout=0.05)
    except Exception as e:
        note("OPEN FAILED: %r" % e)
        return

    buf = bytearray()
    last_ctrlc = 0.0
    last_zero = 0.0
    saw_menu = False
    stop_ctrlc = False
    noted_countdown = False
    result = "timeout"
    deadline = time.time() + WINDOW_S

    while time.time() < deadline:
        now = time.time()
        # Phase 1: spam Ctrl+C to kill the autoboot countdown.
        if not stop_ctrlc and now - last_ctrlc > 0.35:
            try:
                s.write(b"\x03")
            except Exception as e:
                note("write Ctrl+C failed: %r" % e)
                break
            last_ctrlc = now

        try:
            chunk = s.read(8192)
        except Exception as e:
            note("read failed: %r" % e)
            break
        if chunk:
            buf.extend(chunk)
            raw.write(chunk)
            raw.flush()

        tail = bytes(buf[-6000:])

        if not saw_menu and b"Exit to console" in tail:
            saw_menu = True
            stop_ctrlc = True
            last_zero = 0.0
            note("maintenance menu detected -> selecting 0 (exit to console)")

        # Phase 2: keep re-selecting option 0 until the shell prompt shows up.
        if saw_menu and now - last_zero > 2.5:
            try:
                s.write(b"0\r")
                last_zero = now
            except Exception as e:
                note("write 0 failed: %r" % e)

        if not noted_countdown and b"Hit key to stop autoboot" in tail:
            noted_countdown = True
            note("autoboot countdown seen")

        if b"login:" in tail and b"U-Boot" in bytes(buf):
            note("LINUX LOGIN PROMPT detected")
            result = "linux"
            break

        if b"=>" in tail:
            time.sleep(0.4)
            try:
                s.write(b"\r\n")
                time.sleep(0.7)
                more = s.read(8192)
            except Exception:
                more = b""
            if more:
                buf.extend(more)
                raw.write(more)
                raw.flush()
            if b"=>" in bytes(buf[-400:]):
                note("U-BOOT SHELL PROMPT detected")
                result = "uboot"
                break

    try:
        s.close()
    except Exception:
        pass
    raw.close()
    note("monitor exit: %s" % result)
    print("FINAL_STATE=%s" % result, flush=True)


if __name__ == "__main__":
    main()
