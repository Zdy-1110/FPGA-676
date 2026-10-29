"""py -3 tools/rk_get.py <host> <remote> <local> — 用 SFTP 从 RK 下载文件（root/root）。"""
import sys, paramiko
host, remote, local = sys.argv[1:4]
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username="root", password="root", timeout=10)
s = c.open_sftp(); s.get(remote, local); s.close(); c.close()
print("get", remote, "->", local)
