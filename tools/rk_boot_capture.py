#!/usr/bin/env python3
"""完整启动日志捕获：4通道流式写盘，自动跟随USB重枚举。

用法: python tools/rk_boot_capture.py [秒数=240]
日志: tools/boot_chA.log ... boot_chD.log
"""
import glob
import sys
import threading
import time

import serial
import serial.tools.list_ports

DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 240
BASE = "tools/boot_ch"


def find_ports():
    """返回 {通道字母: COM口}，XR21V1414 四通道。"""
    out = {}
    for p in serial.tools.list_ports.comports():
        if "VID_04E2&PID_1414" in (p.hwid or "").upper() or "VID_04E2&PID_1414" in (p.device or "").upper():
            pass
    # hwid 匹配不可靠时退回名字匹配
    for p in serial.tools.list_ports.comports():
        d = (p.device or "").upper()
        h = (p.hwid or "").upper()
        if "VID_04E2" in h or "VID_04E2" in d:
            if "MI_00" in h or "MI_00" in d:
                out["A"] = p.device
            elif "MI_02" in h or "MI_02" in d:
                out["B"] = p.device
            elif "MI_04" in h or "MI_04" in d:
                out["C"] = p.device
            elif "MI_06" in h or "MI_06" in d:
                out["D"] = p.device
    return out


def listen(ch, port, stop_at):
    logf = open(f"{BASE}{ch}.log", "w", encoding="utf-8", errors="replace")
    cur = port
    ser = None
    while time.time() < stop_at:
        try:
            if ser is None:
                ser = serial.Serial(port=cur, baudrate=115200, timeout=0.3)
                ser.dtr = True
                ser.rts = True
                logf.write(f"\n== opened {cur} ==\n")
                logf.flush()
            c = ser.read(8192)
            if c:
                logf.write(c.decode("utf-8", "replace"))
                logf.flush()
        except Exception:
            try:
                if ser:
                    ser.close()
            except Exception:
                pass
            ser = None
            time.sleep(1.5)
            ports = find_ports()
            cur = ports.get(ch, cur)
    if ser:
        try:
            ser.close()
        except Exception:
            pass
    logf.close()


def main():
    stop_at = time.time() + DURATION
    ports = find_ports()
    print(f"通道映射: {ports}，捕获 {DURATION}s，流式写盘 {BASE}?.log", flush=True)
    threads = []
    for ch in "ABCD":
        t = threading.Thread(target=listen, args=(ch, ports.get(ch, "COM14"), stop_at), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    print("捕获结束", flush=True)


if __name__ == "__main__":
    main()
