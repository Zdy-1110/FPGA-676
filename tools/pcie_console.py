#!/usr/bin/env python3
"""RK3568 串口控制台：登录 + PCIe 检查（写入带守护，楔死时优雅退出）。

用法: python tools/pcie_console.py [COM口] [波特率]
退出码: 0=完成  2=TX楔死(需重插USB)
"""
import sys
import time
import threading

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM14"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200


def say(msg):
    print(msg, flush=True)


def guarded_write(ser, data, wait=5.0):
    """带守护的写入：挂起则报告 TX_WEDGE。返回 True/False。"""
    result = {}

    def worker():
        try:
            ser.write(data)
            ser.flush()
            result["ok"] = True
        except Exception as e:
            result["err"] = str(e)

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    t.join(wait)
    if t.is_alive():
        say("!! TX_WEDGE：写入挂起超过 %ds，TX 队列已死，需要重插 USB 线" % wait)
        return False
    if "err" in result:
        say("!! 写入异常: %s" % result["err"])
        return False
    return True


def read_for(sec, ser):
    buf = b""
    end = time.time() + sec
    while time.time() < end:
        c = ser.read(8192)
        if c:
            buf += c
    return buf


def clean(buf):
    text = buf.decode("utf-8", "replace")
    return "".join(ch if ch.isprintable() or ch in "\r\n\t" else "" for ch in text).replace("\r", "")


def show(tag, buf, tail=30):
    lines = [l for l in clean(buf).split("\n") if l.strip()]
    say("===== " + tag + " =====")
    for l in lines[-tail:]:
        say(l)
    say("")


def main():
    try:
        ser = serial.Serial(port=PORT, baudrate=BAUD, timeout=0.3)
    except Exception as e:
        say("!! 打开失败: %s" % e)
        return 2
    ser.dtr = True
    ser.rts = True
    say("端口已打开: %s @ %d" % (PORT, BAUD))

    # 唤醒控制台（重试到有响应为止，最多4次）
    out = b""
    for attempt in range(4):
        if not guarded_write(ser, b"\r\n"):
            return 2
        out += read_for(2.5, ser)
        if clean(out).strip():
            break
        say("(第%d次回车无响应，再试...)" % (attempt + 1))
    show("回车响应", out)

    # 登录
    if "login:" in clean(out):
        for pwd in ("", "root", "forlinx"):
            if not guarded_write(ser, b"root\r\n"):
                return 2
            time.sleep(1.2)
            if not guarded_write(ser, (pwd + "\r\n").encode()):
                return 2
            r = read_for(3.0, ser)
            out += r
            show("登录尝试 pwd=%r" % pwd, r, 12)
            if "#" in clean(r) or "$" in clean(r):
                say(">> 登录成功 (pwd=%r)" % pwd)
                break

    # PCIe 检查命令组
    cmds = [
        "uname -a",
        "cat /proc/device-tree/model; echo",
        "which lspci && lspci -nn || echo NO_LSPCI",
        "ls /sys/bus/pci/devices/ || echo NO_SYSFS_PCI",
        "for n in /proc/device-tree/pcie*; do echo \"== $n status: $(cat $n/status 2>/dev/null)\"; done",
        "dmesg | grep -iE 'pci|pcie' | tail -n 40",
    ]
    for i, cmd in enumerate(cmds):
        ser.reset_input_buffer()
        if not guarded_write(ser, (cmd + "; echo __RC%d=$?\n" % i).encode()):
            return 2
        buf = read_for(8.0, ser)
        body = clean(buf).split("__RC%d=" % i)[0]
        if cmd in body:
            body = body.split(cmd, 1)[1]
        say("##### [%d] %s" % (i, cmd))
        say(body.strip() or "(空)")
        say("")

    ser.close()
    say("== 完成 ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
