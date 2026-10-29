#!/usr/bin/env python3
"""并行监听指定串口，抓取板子上电/重启时的启动日志。

用法: python tools/serial_catch_boot.py <秒数> [波特率] [COM...]
默认: 90s 115200 COM7 COM8 COM9 COM10
"""
import sys
import threading
import time
import serial

DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 90
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
PORTS = sys.argv[3:] or ["COM7", "COM8", "COM9", "COM10"]


def listen(port: str, results: dict) -> None:
    try:
        ser = serial.Serial(port=port, baudrate=BAUD, timeout=0.3)
    except Exception as e:
        results[port] = f"__OPEN_FAIL__ 打开失败: {e}"
        return
    try:
        ser.dtr = True
        ser.rts = True
        data = b""
        end = time.time() + DURATION
        while time.time() < end:
            chunk = ser.read(4096)
            if chunk:
                data += chunk
                end = time.time() + 3.0  # 数据流结束后再等3秒收尾
        results[port] = data
    finally:
        ser.close()


def main() -> None:
    results = {}
    threads = [threading.Thread(target=listen, args=(p, results), daemon=True) for p in PORTS]
    for t in threads:
        t.start()
    print(f"监听 {PORTS} @ {BAUD}，最长 {DURATION}s，等待上电...", flush=True)
    for t in threads:
        t.join()
    for p in PORTS:
        r = results.get(p)
        if isinstance(r, str):
            print(f"\n### {p}: {r}")
            continue
        if not r:
            print(f"\n### {p}: (全程静默)")
            continue
        text = r.decode("utf-8", errors="replace")
        printable = "".join(ch if ch.isprintable() or ch in "\r\n\t" else "" for ch in text)
        lines = [l for l in printable.replace("\r", "").split("\n") if l.strip()]
        print(f"\n### {p}: 收到 {len(r)} 字节, {len(lines)} 行")
        for l in lines[:80]:
            print(f"  {l}")
        if len(lines) > 80:
            print(f"  ... (共 {len(lines)} 行，仅显示前80行)")


if __name__ == "__main__":
    main()
