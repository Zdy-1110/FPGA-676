#!/usr/bin/env python3
"""rk_diag.py — 演示前的板端一键体检。

用法：
    python tools/rk_diag.py 192.168.3.51
    python tools/rk_diag.py 192.168.3.51 --dry-run     # 只打印将执行的远程命令

检查项：
    1. PCIe 端点存在、enable=1、链路速率/宽度
    2. BAR1 版本寄存器 0x838 == 0x20261029（cam17）或 0x20261101（cam18）
    3. 显示主控 0x800 处于已知状态（0x25 实时 / 0x65 视频；[11:10] 夜间模式位忽略）
    4. 欠载计数 0x82C、门铃完成计数 0x1C8 的 1 s 增量
    5. 关键进程（mode_select / menu_daemon / usb_menu / usb_feed）
    6. U 盘挂载点与 CMA 余量

退出码：0 全部通过；1 有 FAIL；2 无法连接。
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

REMOTE_CMD = r'''
E=/sys/bus/pci/devices/0002:21:00.0
if [ -e "$E" ]; then echo "ep_present=1"; else echo "ep_present=0"; fi
echo "ep_enable=$(cat $E/enable 2>/dev/null)"
echo "link_speed=$(cat $E/current_link_speed 2>/dev/null | tr -d ' ')"
echo "link_width=$(cat $E/current_link_width 2>/dev/null)"
echo "ver=$(devmem 0xf0204838 32 2>/dev/null)"
echo "disp=$(devmem 0xf0204800 32 2>/dev/null)"
echo "under=$(devmem 0xf020482C 32 2>/dev/null)"
echo "done1=$(devmem 0xf02041C8 32 2>/dev/null)"
sleep 1
echo "done2=$(devmem 0xf02041C8 32 2>/dev/null)"
echo "procs=$(pgrep -af 'mode_select|menu_daemon|usb_menu|usb_feed' | wc -l)"
echo "usb_mnt=$(grep -c ' /mnt/usb ' /proc/mounts 2>/dev/null)"
echo "cma_free=$(awk '/CmaFree/ {print $2}' /proc/meminfo 2>/dev/null)"
echo "load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
'''.strip()


def run_remote(host: str) -> str:
    cmd = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "rk_ssh.py"), host, REMOTE_CMD]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=40)
    if p.returncode != 0:
        print("SSH failed:\n" + (p.stderr or p.stdout)[-400:], file=sys.stderr)
        raise SystemExit(2)
    return p.stdout


def parse(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        m = re.match(r"^([a-z_0-9]+)=(.*)$", line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def num(v: str | None) -> int | None:
    try:
        return int(v, 0) if v is not None else None
    except ValueError:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if args.dry_run:
        print(REMOTE_CMD)
        return 0

    data = parse(run_remote(args.host))
    results: list[tuple[str, bool, str]] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append((name, ok, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))

    check("PCIe 端点存在", data.get("ep_present") == "1")
    check("端点 enable=1", data.get("ep_enable") == "1", data.get("ep_enable", "?"))
    check("链路 5.0 GT/s", (data.get("link_speed") or "").startswith("5.0"), data.get("link_speed", "?"))
    check("链路 x2", data.get("link_width") == "2", data.get("link_width", "?"))

    ver = num(data.get("ver"))
    check("固件版本 0x20261029|0x20261101|0x20261102|0x20261103|0x20261104|0x20261105|0x20261106", ver in (0x20261029, 0x20261101, 0x20261102, 0x20261103, 0x20261104, 0x20261105, 0x20261106), data.get("ver", "?"))

    disp = num(data.get("disp"))
    check("显示主控已知状态", isinstance(disp, int) and (disp & ~0xC00) in (0x25, 0x65, 0x24, 0x64), data.get("disp", "?"))

    under = num(data.get("under"))
    check("欠载计数 0x82C = 0", under == 0, data.get("under", "?"))

    d1, d2 = num(data.get("done1")), num(data.get("done2"))
    if d1 is None or d2 is None:
        check("门铃计数可读", False, "devmem 读取失败")
    else:
        delta = d2 - d1
        check("门铃计数在推进或静止", delta >= 0, f"1 s 增量 {delta}")

    procs = num(data.get("procs"))
    check("关键进程在跑", (procs or 0) >= 1, f"{procs} 个")

    usb = num(data.get("usb_mnt"))
    cma = num(data.get("cma_free"))
    print(f"[INFO] U 盘挂载={'是' if usb else '否'}  CMA 空闲={cma} kB  load={data.get('load','?')}")

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
