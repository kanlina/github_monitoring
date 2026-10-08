#!/bin/bash
# 服务器端部署脚本：从 GitHub 拉取最新代码并更新运行时脚本
# 用法: /opt/github_monitoring/install/deploy-server.sh
set -e
REPO_DIR="/opt/github_monitoring"
CONFIG_DIR="$HOME/.config/git-notify"

cd "$REPO_DIR"
echo "==> 拉取最新代码"
git pull --ff-only origin main

echo "==> 部署 notify.sh"
cp notify.sh "$CONFIG_DIR/notify.sh"
chmod +x "$CONFIG_DIR/notify.sh"

echo "==> 校验一致性"
A=$(sha256sum "$REPO_DIR/notify.sh" | cut -c1-12)
B=$(sha256sum "$CONFIG_DIR/notify.sh" | cut -c1-12)
[ "$A" = "$B" ] && echo "OK: 运行脚本与仓库一致 ($A)" || { echo "不一致!"; exit 1; }
echo "==> 部署完成 $(date '+%F %T')"
