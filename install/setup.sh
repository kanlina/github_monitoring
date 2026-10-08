#!/bin/bash
# git-notify 一键安装脚本（macOS launchd / Linux systemd 自动二选一）
set -e

CONFIG_DIR="$HOME/.config/git-notify"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 创建配置目录 $CONFIG_DIR"
mkdir -p "$CONFIG_DIR/state"

[ -f "$CONFIG_DIR/notify.sh" ] || cp "$SCRIPT_DIR/notify.sh" "$CONFIG_DIR/notify.sh"
chmod +x "$CONFIG_DIR/notify.sh"

for f in repos.conf webhook.txt ai_key.txt; do
  [ -f "$CONFIG_DIR/$f" ] || cp "$SCRIPT_DIR/$f.example" "$CONFIG_DIR/$f"
done

echo "==> 请编辑以下配置文件后重新运行本脚本完成注册:"
echo "    $CONFIG_DIR/repos.conf    (监听清单)"
echo "    $CONFIG_DIR/webhook.txt   (飞书群自定义机器人 webhook)"
echo "    $CONFIG_DIR/ai_key.txt    (AI 接口 token，可留空=通知不带 AI 分析)"

read -p "配置是否已填好？(y/N): " ok
[ "$ok" != "y" ] && { echo "填好后再运行一次即可。"; exit 0; }

OS="$(uname)"
if [ "$OS" = "Darwin" ]; then
  echo "==> macOS: 安装 launchd 定时任务"
  sed "s#__HOME__#$HOME#g" "$SCRIPT_DIR/install/com.git-notify.plist.template" > /tmp/com.git-notify.plist
  launchctl unload ~/Library/LaunchAgents/com.git-notify.plist 2>/dev/null || true
  cp /tmp/com.git-notify.plist ~/Library/LaunchAgents/com.git-notify.plist
  launchctl load ~/Library/LaunchAgents/com.git-notify.plist
  echo "    已加载。卸载命令: launchctl unload ~/Library/LaunchAgents/com.git-notify.plist"
else
  echo "==> Linux: 安装 systemd user timer"
  mkdir -p ~/.config/systemd/user
  cp "$SCRIPT_DIR/install/git-notify.service" ~/.config/systemd/user/
  cp "$SCRIPT_DIR/install/git-notify.timer" ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now git-notify.timer
  echo "    已启用。查看状态: systemctl --user status git-notify.timer"
  echo "    (SSH 退出后仍需运行: loginctl enable-linger \$USER)"
fi

echo "==> 手动跑一轮建立基线（首次只记录 SHA，不发通知）"
"$CONFIG_DIR/notify.sh" && echo "OK"
echo "完成！日志: $CONFIG_DIR/notify.log"
