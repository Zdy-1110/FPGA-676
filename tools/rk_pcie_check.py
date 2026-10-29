#!/usr/bin/env python3
"""通过调试串口检查 RK3568 的 PCIe 识别情况。

用法: python tools/rk_pcie_check.py [COM口] [波特率]
默认: COM3 1500000。自动处理 login（root / 空密码→root→forlinx）。
"""
import sys
import time
import serial

CHECK_CMDS = [
    "uname -a",
    "cat /proc/device-tree/model 2>/dev/null; echo",
    "which lspci && lspci -nn || echo NO_LSPCI",
    "ls /sys/bus/pci/devices/ 2>/dev/null || echo NO_SYSFS_PCI",
    "cat /proc/bus/pci/devices 2>/dev/null || echo NO_PROC_PCI",
    "for n in /proc/device-tree/pcie*; do echo \"== $n status: $(cat $n/status 2>/dev/null)\"; done",
    "dmesg | grep -iE 'pcie|pci|phy' | tail -n 80",
]


def read_until(ser, markers, timeout):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            end = time.time() + timeout
            if all(m.encode() in buf for m in markers):
                return buf
    return buf


def to_text(buf):
    text = buf.decode("utf-8", errors="replace")
    return "".join(ch if ch.isprintable() or ch in "\r\n\t" else "" for ch in text).replace("\r", "")


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM3"
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 1500000
    ser = serial.Serial(port=port, baudrate=baud, timeout=0.3)
    ser.dtr = True
    ser.rts = True

    # 唤醒控制台
    ser.write(b"\x03\r\n\r\n")
    ser.flush()
    out = to_text(read_until(ser, ["__NEVER__"], 3.0))
    print("--- 控制台唤醒输出 ---")
    print(out[-2000:] if out.strip() else "(无输出)")

    # 登录（若需要）
    if "login:" in out:
        print("--- 检测到登录提示，尝试 root ---")
        for pwd in ("", "root", "forlinx"):
            ser.write(b"root\r\n")
            time.sleep(1.0)
            ser.write((pwd + "\r\n").encode())
            out2 = to_text(read_until(ser, ["__NEVER__"], 3.0))
            out += out2
            if "#" in out2 or "$" in out2:
                break
        print(out[-1000:])

    # 逐条执行检查命令
    for i, cmd in enumerate(CHECK_CMDS):
        marker = f"__RC{i}="
        ser.write(f"{cmd}; echo {marker}$?\n".encode())
        ser.flush()
        buf = read_until(ser, [marker], 25.0)
        body = to_text(buf)
        # 去掉回显的命令本身
        if cmd in body:
            body = body.split(cmd, 1)[1]
        body = body.split(marker)[0]
        print(f"\n===== [{i}] {cmd} =====")
        print(body.strip() or "(空)")

    ser.close()
    print("\n===== 完成 =====")


if __name__ == "__main__":
    main()
