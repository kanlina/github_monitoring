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
# 部署前校验：bash 语法 + 内嵌 PY heredoc 的 Python 语法
bash -n notify.sh || { echo "❌ bash 语法错误，停止部署"; exit 1; }
python3 - <<'PYCHECK'
import ast, sys
src = open("notify.sh", encoding="utf-8").read()
parts = src.split("<<'PY'")[1:]
for i, p in enumerate(parts):
    code = "\n".join(p.split("\nPY\n")[0].split("\n")[1:])
    try:
        ast.parse(code)
    except SyntaxError as e:
        print(f"❌ 内嵌 PY 块{i+1} 语法错误 line {e.lineno}: {e.msg}"); sys.exit(1)
print("    notify.sh 语法校验通过（bash + 内嵌 Python）")
PYCHECK
cp notify.sh "$CONFIG_DIR/notify.sh"
chmod +x "$CONFIG_DIR/notify.sh"

echo "==> 校验一致性"
A=$(sha256sum "$REPO_DIR/notify.sh" | cut -c1-12)
B=$(sha256sum "$CONFIG_DIR/notify.sh" | cut -c1-12)
[ "$A" = "$B" ] && echo "OK: 运行脚本与仓库一致 ($A)" || { echo "不一致!"; exit 1; }
echo "==> 部署完成 $(date '+%F %T')"
