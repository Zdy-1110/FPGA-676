#!/usr/bin/env python3
"""RK3568 串口只读查询：网络 / sshd / PCIe 链路基线。不改任何配置，不重启。

用法: py -3 tools/rk_net_info.py [COM] [波特率]
环境变量: RK_USER (默认 root), RK_PASS (默认 root)
状态判断: U-Boot 提示符 (=>) 时只报告、不动板子；登录提示用默认 root/root（可通过 RK_USER / RK_PASS 覆盖）。
"""
import os
import sys
import threading
import time
import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM9"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
LOG = "tools/rk_net_info.log"

logf = open(LOG, "w", encoding="utf-8")


def log(msg=""):
    line = str(msg)
    print(line, flush=True)
    logf.write(line + "\n")
    logf.flush()


def open_port():
    """带 6 秒守护的串口打开，防驱动楔死。"""
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
        return None, "打开挂起 >6s"
    return result.get("ser"), result.get("err")


def clean(buf):
    text = buf.decode("utf-8", "replace")
    return "".join(ch if ch.isprintable() or ch in "\r\n\t" else "" for ch in text).replace("\r", "")


def read_for(ser, seconds):
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        c = ser.read(8192)
        if c:
            buf += c
    return buf


def read_until(ser, marker, timeout):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        c = ser.read(8192)
        if c:
            buf += c
            if marker.encode() in buf:
                break
    return buf


def run(ser, i, cmd, timeout=8.0):
    ser.reset_input_buffer()
    ser.write((f"echo __S{i}__; {cmd}; echo __E{i}__:$?\n").encode())
    ser.flush()
    buf = read_until(ser, f"__E{i}__:", timeout)
    text = clean(buf)
    # 回显行里也含 __S{i}__，取最后一次出现的起点
    body = text.rsplit(f"__S{i}__", 1)[-1] if f"__S{i}__" in text else text
    body = body.split(f"__E{i}__:")[0]
    return body.strip()


CMDS = [
    "uname -a; cat /proc/device-tree/model 2>/dev/null; echo",
    "ip -4 addr 2>/dev/null || ifconfig -a",
    "ip -6 addr 2>/dev/null | grep -E 'inet6|^[0-9]+:' | head -20",
    "ip route 2>/dev/null || route -n",
    "for n in /sys/class/net/*; do echo \"$(basename $n) state=$(cat $n/operstate) mac=$(cat $n/address) speed=$(cat $n/speed 2>/dev/null)\"; done",
    "ps | grep -E 'sshd|dropbear|udhcpc|dhclient|NetworkManager|connmanctl|systemd-network' | grep -v grep",
    "(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null) | head -20",
    "cat /etc/network/interfaces 2>/dev/null | grep -v '^#' | grep -v '^$'; ls /etc/network /etc/systemd/network 2>/dev/null",
    "grep -vE '^#|^$' /etc/ssh/sshd_config 2>/dev/null | head -30; ls /etc/ssh 2>/dev/null",
    "ls /etc/init.d 2>/dev/null | head -40",
    "ls /sys/bus/pci/devices/ 2>/dev/null",
    "dmesg | grep -iE 'pcie|eth|stmmac|rk_gmac|gmac|link is|dhcp' | tail -n 40",
]


def main():
    log(f"打开 {PORT} @{BAUD} ...")
    ser, err = open_port()
    if ser is None:
        log(f"!! 打不开串口: {err}（MobaXterm 占用？或拔插一次 USB）")
        return 1
    log("打开成功")

    ser.write(b"\r\n")
    ser.flush()
    out = clean(read_for(ser, 2.5))
    tail = "\n".join([l for l in out.split("\n") if l.strip()][-8:])
    log("===== 回车响应（尾部）=====")
    log(tail or "(无任何输出)")
    log()

    low = out.lower()
    if "=>" in out.split("\n")[-1] or out.rstrip().endswith("=>"):
        log("!! 板子停在 U-Boot 提示符，未做任何操作。请你决定是否 boot。")
        ser.close()
        return 2
    if not out.strip():
        # 可能静默，再多等一次
        ser.write(b"\r\n")
        ser.flush()
        out = clean(read_for(ser, 3.0))
        low = out.lower()
        log("二次回车响应: " + (out.strip()[-200:] or "(仍无输出，板子可能没上电 / 串口线接了错误通道)"))
    if "login:" in low:
        user = os.environ.get("RK_USER", "root")
        passwd = os.environ.get("RK_PASS", "root")
        ser.write(f"{user}\r\n".encode())
        ser.flush()
        time.sleep(1.2)
        ser.write(f"{passwd}\r\n".encode())
        ser.flush()
        r = clean(read_for(ser, 3.0))
        log(f"===== 登录 {user}/{passwd} =====")
        log("\n".join([l for l in r.split("\n") if l.strip()][-6:]))
        log()
        if "incorrect" in r.lower() or "login:" in r.lower().split("password:")[-1]:
            log("!! 登录失败，停止（不再猜其他密码）")
            ser.close()
            return 3

    for i, cmd in enumerate(CMDS):
        body = run(ser, i, cmd)
        log(f"##### [{i}] {cmd}")
        log(body or "(空)")
        log()
    ser.close()
    log("== 完成 ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
