#!/usr/bin/env python3
"""监视全部USB PnP设备变化（不只COM口），识别新设备/消失设备/问题设备。

用法: python tools/usb_watch.py [秒数，默认300]
"""
import subprocess
import sys
import time

DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 300

PS = (
    "Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\\*' } | "
    "ForEach-Object { '{0}|{1}|{2}' -f $_.Status, $_.FriendlyName, $_.InstanceId }"
)


def snapshot() -> dict:
    out = subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command", PS],
        capture_output=True, text=True, encoding="gbk", errors="replace", timeout=30,
    ).stdout or ""
    devs = {}
    for line in out.splitlines():
        parts = line.split("|", 2)
        if len(parts) == 3 and parts[2].strip():
            devs[parts[2].strip()] = f"{parts[0]}|{parts[1]}"
    return devs


if __name__ == "__main__":
    prev = snapshot()
    print(f"初始 USB 设备 {len(prev)} 个", flush=True)
    for k in sorted(prev):
        print(f"  {prev[k]} | {k}", flush=True)
    deadline = time.time() + DURATION
    while time.time() < deadline:
        time.sleep(2)
        try:
            cur = snapshot()
        except Exception:
            continue
        for k in sorted(set(cur) - set(prev)):
            print(f"[{time.strftime('%H:%M:%S')}] + {cur[k]} | {k}", flush=True)
        for k in sorted(set(prev) - set(cur)):
            print(f"[{time.strftime('%H:%M:%S')}] - {prev[k]} | {k}", flush=True)
        prev = cur
    print("监视结束", flush=True)
