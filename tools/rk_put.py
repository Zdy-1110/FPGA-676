"""py -3 tools/rk_put.py <host> <local> <remote> [mode] — 用 SFTP 上传文件到 RK（root/root）。"""
import sys, paramiko
host, local, remote = sys.argv[1:4]
mode = int(sys.argv[4], 8) if len(sys.argv) > 4 else 0o755
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username="root", password="root", timeout=10)
s = c.open_sftp(); s.put(local, remote); s.chmod(remote, mode); s.close(); c.close()
print("put", local, "->", remote)
