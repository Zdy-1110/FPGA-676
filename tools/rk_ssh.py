#!/usr/bin/env python3
"""通过 SSH 在 RK 上执行命令（paramiko，root/root）。

用法: py -3 tools/rk_ssh.py <host> "cmd1" "cmd2" ...
调用者负责保证命令只读（或已获用户授权）。
"""
import sys
import paramiko

host = sys.argv[1]
cmds = sys.argv[2:]

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username="root", password="root", timeout=8, banner_timeout=15,
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
