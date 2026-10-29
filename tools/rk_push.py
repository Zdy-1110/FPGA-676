#!/usr/bin/env python3
"""通过 SFTP 上传文件到 RK（默认 root/root，可通过环境变量 RK_USER / RK_PASS 覆盖），失败返回非零退出码。

用法: py -3 tools/rk_push.py <host> <local_file> <remote_file>
环境变量: RK_USER (默认 root), RK_PASS (默认 root)
"""
import os
import sys
import paramiko

def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <host> <local_file> <remote_file>", file=sys.stderr)
        sys.exit(1)

    host, local, remote = sys.argv[1:4]
    # 兼容 Git Bash 自动把远端 Linux 路径 /userdata/... 转换为 C:/Program Files/Git/userdata/...
    git_prefix = "C:/Program Files/Git"
    git_prefix_bs = "C:\\Program Files\\Git"
    if remote.startswith(git_prefix):
        remote = remote[len(git_prefix):]
    elif remote.startswith(git_prefix_bs):
        remote = remote[len(git_prefix_bs):].replace("\\", "/")
    if not remote.startswith("/"):
        remote = "/" + remote

    if not os.path.isfile(local):
        print(f"Error: local file not found: {local}", file=sys.stderr)
        sys.exit(2)

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        user = os.environ.get("RK_USER", "root")
        passwd = os.environ.get("RK_PASS", "root")
        client.connect(
            host,
            username=user,
            password=passwd,
            timeout=10,
            banner_timeout=15,
            allow_agent=False,
            look_for_keys=False,
        )
        sftp = client.open_sftp()
        sftp.put(local, remote)
        sftp.chmod(remote, 0o755)
        sftp.close()
        client.close()
        print(f"Successfully pushed {local} -> {remote} on {host}")
        sys.exit(0)
    except Exception as e:
        print(f"Error pushing file: {e}", file=sys.stderr)
        try:
            client.close()
        except Exception:
            pass
        sys.exit(3)

if __name__ == "__main__":
    main()
