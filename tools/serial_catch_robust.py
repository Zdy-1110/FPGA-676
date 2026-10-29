#!/usr/bin/env python3
"""健壮版启动日志监听：USB 重枚举后自动重开端口，直到时限。

用法: python tools/serial_catch_robust.py <秒> [波特率] [COM...]
"""
import sys
import threading
import time
import serial

DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 300
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
PORTS = sys.argv[3:] or ["COM7", "COM8", "COM9", "COM10"]


def listen(port: str, results: dict, errors: dict) -> None:
    data = b""
    deadline = time.time() + DURATION
    while time.time() < deadline:
        try:
            ser = serial.Serial(port=port, baudrate=BAUD, timeout=0.3)
        except Exception:
            time.sleep(1.0)  # 设备暂时不在，等重枚举
            continue
        try:
            ser.dtr = True
            ser.rts = True
            while time.time() < deadline:
                chunk = ser.read(4096)
                if chunk:
                    data += chunk
        except Exception as e:
            errors[port] = str(e)
        finally:
            try:
                ser.close()
            except Exception:
                pass
            time.sleep(1.0)  # 重枚举间隔
    results[port] = data


def main() -> None:
    results, errors = {}, {}
    threads = [
        threading.Thread(target=listen, args=(p, results, errors), daemon=True) for p in PORTS
    ]
    for t in threads:
        t.start()
    print(f"健壮监听 {PORTS} @ {BAUD}，最长 {DURATION}s（断线自动重连）...", flush=True)
    for t in threads:
        t.join()
    for p in PORTS:
        r = results.get(p, b"")
        if errors.get(p):
            print(f"\n### {p}: [发生过断线: {errors[p][:80]}]")
        else:
            print(f"\n### {p}:")
        if not r:
            print("   (全程无数据)")
            continue
        text = r.decode("utf-8", errors="replace")
        printable = "".join(ch if ch.isprintable() or ch in "\r\n\t" else "" for ch in text)
        lines = [l for l in printable.replace("\r", "").split("\n") if l.strip()]
        print(f"   收到 {len(r)} 字节, {len(lines)} 行:")
        for l in lines[:60]:
            print(f"   {l}")
        if len(lines) > 60:
            print(f"   ... (共 {len(lines)} 行)")


if __name__ == "__main__":
    main()
