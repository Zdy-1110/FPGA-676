#!/usr/bin/env python3
"""监视 COM 口变化 5 分钟，把增删事件带时间戳写到 stdout。"""
import time
import serial.tools.list_ports


def snapshot():
    return {p.device for p in serial.tools.list_ports.comports()}


if __name__ == "__main__":
    prev = snapshot()
    print(f"初始端口: {sorted(prev)}", flush=True)
    deadline = time.time() + 300
    while time.time() < deadline:
        time.sleep(1.5)
        cur = snapshot()
        added = cur - prev
        removed = prev - cur
        ts = time.strftime("%H:%M:%S")
        for p in sorted(added):
            print(f"[{ts}] +出现 {p}", flush=True)
        for p in sorted(removed):
            print(f"[{ts}] -消失 {p}", flush=True)
        prev = cur
    print("监视结束", flush=True)
