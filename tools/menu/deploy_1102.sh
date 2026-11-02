#!/bin/bash
# 11-02 部署：cache 刷新修复（绿色短横线）+ 前摄检测接入 + 孤儿进程修复
# 用法（Git Bash，仓库根目录）：bash tools/menu/deploy_1102.sh [板子IP]
# 先在板上长按 KEY4 退回开机选择界面再执行。
set -e
H=${1:-192.168.3.51}
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
Q=/userdata/quad
FILES="tools/menu/usb_menu tools/menu/mode_select tools/menu/menu_daemon tools/usb_feed/usb_feed"

# 需要 Git Bash（Windows 的 py 启动器 + paramiko）；在 cmd 里直接敲 bash 会进 WSL，那里没有 py
if ! command -v py >/dev/null 2>&1; then
    echo "错误：找不到 py。请用 Git Bash 运行：" >&2
    echo "  \"C:\\Program Files\\Git\\bin\\bash.exe\" tools/menu/deploy_1102.sh" >&2
    exit 1
fi

echo "== 本地 md5 =="; md5sum $FILES
py -3 tools/rk_ssh.py $H "pkill -x usb_feed; cd $Q && for f in usb_menu mode_select menu_daemon usb_feed; do cp -p \$f \$f.bak_1102c; done; ls -l $Q/*.bak_1102c"
for f in $FILES; do
    py -3 tools/rk_push.py $H "$f" "$Q/$(basename $f).new"
done
# 先传 .new 再 rename：运行中的可执行文件不能直接覆盖（text file busy）
py -3 tools/rk_ssh.py $H "cd $Q && for f in usb_menu mode_select menu_daemon usb_feed; do chmod +x \$f.new && mv -f \$f.new \$f; done; md5sum usb_menu mode_select menu_daemon usb_feed"
# 重启开机选择界面（run_boot.sh 会自动重新拉起 mode_select；不要 pkill -f run_boot.sh）
py -3 tools/rk_ssh.py $H "pkill -x usb_menu; pkill -x menu_daemon; pkill -x mode_select; sleep 3; ps -ef | grep -E 'mode_select|menu_daemon|usb_menu|usb_feed' | grep -v grep"
echo "== 回滚：cd $Q && for f in usb_menu mode_select menu_daemon usb_feed; do cp -p \$f.bak_1102c \$f; done =="
