#!/usr/bin/env python3
"""通过 SSH 在 RK 上执行命令（paramiko，默认 root/root，可通过环境变量 RK_USER / RK_PASS 覆盖）。

用法: py -3 tools/rk_ssh.py <host> "cmd1" "cmd2" ...
环境变量: RK_USER (默认 root), RK_PASS (默认 root)
调用者负责保证命令只读（或已获用户授权）。
"""
import os
import sys
import paramiko

host = sys.argv[1]
cmds = sys.argv[2:]

user = os.environ.get("RK_USER", "root")
passwd = os.environ.get("RK_PASS", "root")

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username=user, password=passwd, timeout=8, banner_timeout=15,
          allow_agent=False, look_for_keys=False)
for cmd in cmds:
    print(f"##### {cmd}")
    _, out, err = c.exec_command(cmd, timeout=60)
    o = out.read().decode("utf-8", "replace").rstrip()
    e = err.read().decode("utf-8", "replace").rstrip()
    rc = out.channel.recv_exit_status()
    if o:
        print(o)
    if e:
        print("[stderr]", e)
    print(f"[rc={rc}]\n")
c.close()
