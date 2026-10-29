#!/usr/bin/env python3
"""通过串口在 RK 上执行指定命令并回显结果（沿用 rk_net_info.py 的打开/登录逻辑）。

用法: py -3 tools/rk_cmd.py COM9 "cmd1" "cmd2" ...
调用者负责保证命令只读；U-Boot 提示符下不做任何操作。
"""
import sys

sys.argv_backup = sys.argv[:]
port = sys.argv[1]
cmds = sys.argv[2:]
sys.argv = [sys.argv[0], port]

import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location("rk_net_info", pathlib.Path(__file__).with_name("rk_net_info.py"))
m = importlib.util.module_from_spec(spec)
m.CMDS = []
spec.loader.exec_module(m)
m.CMDS = cmds
sys.exit(m.main())
