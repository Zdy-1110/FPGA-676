#!/usr/bin/env python3
"""RK3568 串口会话：登录 + PCIe 检查。带打开守护、文件日志、实时flush。

用法: python tools/rk_session_check.py [COM] [波特率]
"""
import sys
import threading
import time
import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM14"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
LOG = "tools/pcie_session.log"

logf = open(LOG, "w", encoding="utf-8")


def log(msg):
    line = str(msg)
    print(line, flush=True)
    logf.write(line + "\n")
    logf.flush()


ser = None


def open_port():
    """带6秒守护的串口打开，防驱动楔死。"""
    result = {}

    def worker():
        try:
            s = serial.Serial(port=PORT, baudrate=BAUD, timeout=0.3)
            s.dtr = True
            s.rts = True
            result["ser"] = s
        except Exception as e:
            result["err"] = str(e)

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    t.join(6.0)
    if t.is_alive():
        return None
    return result.get("ser")


def read_fixed(seconds):
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        c = ser.read(8192)
        if c:
            buf += c
    return buf


def clean(buf):
    text = buf.decode("utf-8", "replace")
    return "".join(ch if ch.isprintable() or ch in "\r\n\t" else "" for ch in text).replace("\r", "")


def show(tag, buf, tail=25):
    lines = [l for l in clean(buf).split("\n") if l.strip()]
    log(f"===== {tag} =====")
    for l in lines[-tail:]:
        log(l)
    log("")


def main():
    global ser
    log(f"打开 {PORT} @{BAUD} ...")
    ser = open_port()
    if ser is None:
        log("!! 打开挂起 >6s —— 端口驱动楔死，请拔插一次 USB 线")
        return 1
    log("打开成功")

    ser.write(b"\r\n")
    ser.flush()
    out = read_fixed(2.5)
    show("回车响应", out)

    if "login:" in clean(out):
        for pwd in ("", "root", "forlinx"):
            ser.write(b"root\r\n")
            ser.flush()
            time.sleep(1.2)
            ser.write((pwd + "\r\n").encode())
            ser.flush()
            r = read_fixed(3.0)
            out += r
            show(f"登录 pwd={pwd!r}", r, 10)
            if "#" in clean(r) or "$" in clean(r):
                break

    CMDS = [
        "uname -a",
        "cat /proc/device-tree/model; echo",
        "which lspci && lspci -nn || echo NO_LSPCI",
        "ls /sys/bus/pci/devices/ || echo NO_SYSFS_PCI",
        'for n in /proc/device-tree/pcie*; do echo "== $n status: $(cat $n/status 2>/dev/null)"; done',
        "dmesg | grep -iE 'pci|pcie' | tail -n 40",
    ]
    for i, cmd in enumerate(CMDS):
        ser.reset_input_buffer()
        ser.write((cmd + f"; echo __RC{i}=$?\n").encode())
        ser.flush()
        buf = read_fixed(7.0)
        body = clean(buf).split(f"__RC{i}=")[0]
        if cmd in body:
            body = body.split(cmd, 1)[1]
        log(f"##### [{i}] {cmd}")
        log(body.strip() or "(空)")
        log("")
    ser.close()
    log("== 完成 ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
