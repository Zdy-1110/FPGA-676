"""py -3 tools/rk_get.py <host> <remote> <local> — 用 SFTP 从 RK 下载文件（默认 root/root，可用 RK_USER / RK_PASS 环境变量覆盖）。"""
import os, sys, paramiko
host, remote, local = sys.argv[1:4]
user = os.environ.get("RK_USER", "root")
passwd = os.environ.get("RK_PASS", "root")
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username=user, password=passwd, timeout=10)
s = c.open_sftp(); s.get(remote, local); s.close(); c.close()
print("get", remote, "->", local)
