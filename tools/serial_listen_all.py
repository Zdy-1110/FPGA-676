#!/usr/bin/env python3
"""同时监听所有候选串口，报告哪个口在主动输出数据。"""
import threading
import time
import serial

PORTS = ["COM3", "COM4", "COM7", "COM8", "COM9", "COM10"]
DURATION = 12


def listen(port: str, baud: int, results: dict) -> None:
    try:
        ser = serial.Serial(port=port, baudrate=baud, timeout=0.3)
    except Exception as e:
        results[port] = f"打开失败: {e}"
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
        results[port] = data
    finally:
        ser.close()


def run(baud: int) -> None:
    results = {}
    threads = [
        threading.Thread(target=listen, args=(p, baud, results), daemon=True) for p in PORTS
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    print(f"--- 监听 {DURATION}s @ {baud} ---")
    for p in PORTS:
        r = results.get(p)
        if isinstance(r, str):
            print(f"{p}: {r}")
        elif not r:
            print(f"{p}: (静默)")
        else:
            text = r.decode("utf-8", errors="replace")
            printable = "".join(ch if ch.isprintable() or ch in "\r\n" else "·" for ch in text)
            tail = "\n".join(
                f"      {l}" for l in printable.replace("\r", "").split("\n")[-12:] if l.strip()
            )
            print(f"{p}: 收到 {len(r)} 字节\n{tail}")


if __name__ == "__main__":
    for baud in (1500000, 115200):
        run(baud)
