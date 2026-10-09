#!/bin/bash
# git-notify: 本地轮询 GitHub 仓库，有新提交则推飞书群（交互卡片 + AI 变更分析）
# 配置: ~/.config/git-notify/repos.conf   每行: 名称|仓库本地路径|分支
#       ~/.config/git-notify/webhook.txt  飞书自定义机器人 webhook 地址
#       ~/.config/git-notify/ai_key.txt   AI 中转服务 token
# 状态: ~/.config/git-notify/state/

CONFIG_DIR="$HOME/.config/git-notify"
REPOS_FILE="$CONFIG_DIR/repos.conf"
WEBHOOK_FILE="$CONFIG_DIR/webhook.txt"
AI_KEY_FILE="$CONFIG_DIR/ai_key.txt"
STATE_DIR="$CONFIG_DIR/state"
LOG_FILE="$CONFIG_DIR/notify.log"

WEBHOOK=$(head -n1 "$WEBHOOK_FILE" 2>/dev/null | tr -d '[:space:]')
[ -z "$WEBHOOK" ] && exit 0
AI_TOKEN=$(head -n1 "$AI_KEY_FILE" 2>/dev/null | tr -d '[:space:]')
mkdir -p "$STATE_DIR"

# 并发保护说明：本脚本自身不做锁，由 cron 命令行的 flock（内核级文件锁）保证
# 单实例——进程无论以何种方式结束（正常/被杀/断电），内核都会自动释放锁，
# 不存在残留锁问题。macOS 无 flock 时如需本地运行，自行加 mkdir 锁或忽略重叠。
# cron 示例: * * * * * root /usr/bin/flock -n /root/.config/git-notify/.cron.lock /root/.config/git-notify/notify.sh

log() { echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }
log "心跳: 本轮开始 (pid=$$)"

ai_context() {  # $1=当前仓库名 $2=分组 → 输出同组其他项目近期提交动态
  local cur="$1" grp="$2" seen=""
  local n p b g
  while IFS='|' read -r n p b g; do
    case "$n" in ''|\#*) continue ;; esac
    [ "$n" = "$cur" ] && continue
    [ "${g:-kec}" = "$grp" ] || continue
    case " $seen " in *" $n "*) continue ;; esac
    seen="$seen $n"
    local line
    line=$(git -C "$p" log "origin/$b" -8 --date=format:'%m-%d %H:%M' \
      --format='%ad %s' 2>/dev/null | head -8)
    [ -z "$line" ] && continue
    echo "【$n 最近提交（@$b）】"
    echo "$line"
    echo ""
  done < "$REPOS_FILE"
}

ai_analyze() {  # $1=仓库名 $2=分支 $3=commit列表 $4=diff $5=关联项目近期提交  → stdout 摘要
  [ -z "$AI_TOKEN" ] && return 1
  python3 - "$@" <<'PY'
import json, sys, urllib.request
name, branch, logtxt, diff, ctx = sys.argv[1:6]
diff = diff[:8000]
ctx = ctx[:3000]
prompt = f"""仓库 {name} 的 {branch} 分支有新提交。

提交记录:
{logtxt}

按提交拆分的代码变更 diff（可能截断）:
```diff
{diff}
```

同一产品的关联项目近期提交动态（供参考，用于识别跨端配合/依赖关系）:
{ctx or "（无）"}

请按 instructions 中的格式输出分析，不要输出其他内容。"""
data = {
    "model": "gpt-5.5",
    "instructions": "你是资深工程师兼产品顾问。输入包含按提交拆分的变更说明、diff，以及同一产品其他端项目的近期提交动态。用简体中文做分析，450 字以内，按以下三段输出（段落标题用【】，不要使用 markdown 标题）:\n【技术实现】逐条提交说明：每条提交一行，直接讲技术实现——改动的关键类/组件/接口/字段/配置项，以及逻辑如何变化，不写产品目的\n【对用户的影响】普通用户会感知到什么变化？哪些操作流程会不一样？对业务指标（如注册转化、放款、还款）可能有什么影响\n【风险与建议】技术风险（如边界条件、兼容性、数据一致性）+ 建议重点回归的具体场景。若本批提交与关联项目近期提交是同一需求的跨端配合（如客户端与后端联动改造），请明确指出配合关系及上线顺序依赖（哪端先上/需同时上）",
    "input": prompt,
    "max_output_tokens": 1600,
}
req = urllib.request.Request("https://ai.zonheng.net/v1/responses",
    data=json.dumps(data).encode(),
    headers={"Authorization": "Bearer " + __import__("os").environ["AI_TOKEN"],
             "Content-Type": "application/json",
             "User-Agent": "curl/8.7.1"})
try:
    with urllib.request.urlopen(req, timeout=90) as r:
        body = json.load(r)
    texts = []
    for item in body.get("output", []):
        for c in item.get("content", []):
            if c.get("type") == "output_text" and c.get("text", "").strip():
                texts.append(c["text"].strip())
    out = "\n".join(texts).strip()
    print(out if out else "", end="")
    sys.exit(0 if out else 1)
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}", file=sys.stderr)
    try: print(e.read().decode()[:1000], file=sys.stderr)
    except Exception: pass
    sys.exit(1)
except Exception as e:
    print(repr(e), file=sys.stderr)
    sys.exit(1)
PY
}

notify() {  # $1=repo名 $2=分支 $3=提交数 $4=commit markdown $5=仓库URL $6=AI分析文本 $7=webhook $8=标题颜色
  python3 - "$@" <<'PY'
import json, sys, urllib.request
from datetime import datetime
name, branch, count, logtxt, repo_url, ai_text, webhook, color = sys.argv[1:9]

header = {"template": color, "title": {"tag": "plain_text",
          "content": f"🚀 commit 通知 | {name} @ {branch}"}}
elements = [
    {"tag": "div", "text": {"tag": "lark_md",
        "content": f"**检测到 {count} 个新提交**\n" + logtxt}},
]
if ai_text:
    elements.append({"tag": "div", "text": {"tag": "lark_md",
        "content": f"**🤖 AI 分析**\n{ai_text}"}})
elements += [
    {"tag": "action", "actions": [{"tag": "button", "text": {
        "tag": "plain_text", "content": "查看代码"},
        "type": "primary", "url": repo_url}]},
    {"tag": "hr"},
    {"tag": "note", "elements": [{"tag": "plain_text",
        "content": f"git-notify 自动推送 · {datetime.now().strftime('%Y-%m-%d %H:%M')}"}]},
]
card = {"config": {"wide_screen_mode": True}, "header": header, "elements": elements}
data = json.dumps({"msg_type": "interactive", "card": card}).encode()
req = urllib.request.Request(webhook, data=data,
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=10) as r:
    body = json.load(r)
sys.exit(0 if body.get("code") == 0 or body.get("StatusCode") == 0 else 1)
PY
}

while IFS='|' read -r name path branch group; do
  case "$name" in ''|\#*) continue ;; esac
  group="${group:-kec}"
  # 必须每轮无条件 fetch：本地缓存的 origin 引用是过期的，不能作为对比依据
  git -C "$path" fetch origin "$branch" --quiet 2>>"$LOG_FILE" || { log "fetch失败: $name/$branch"; continue; }
  NEW_SHA=$(git -C "$path" rev-parse "origin/$branch" 2>/dev/null) || { log "rev-parse失败: $name/$branch"; continue; }
  STATE_FILE="$STATE_DIR/$name.$branch.sha"
  OLD_SHA=$(cat "$STATE_FILE" 2>/dev/null)
  if [ -n "$OLD_SHA" ] && [ "$OLD_SHA" != "$NEW_SHA" ]; then
    COUNT=$(git -C "$path" rev-list --count "$OLD_SHA..$NEW_SHA" 2>/dev/null || echo "?")
    REPO_URL=$(git -C "$path" remote get-url origin 2>/dev/null \
      | sed -e 's#git@github.com:#https://github.com/#' -e 's#\.git$##')
    LOGTXT=$(git -C "$path" log --date=format:'%Y-%m-%d %H:%M' \
      --format="- [%h](${REPO_URL}/commit/%H) %an · %ad: %s" \
      "$OLD_SHA..$NEW_SHA" 2>/dev/null | head -20)
    # 按提交拆分 diff，便于 AI 逐条归因
    DIFF=""
    while read -r csha; do
      [ -z "$csha" ] && continue
      CSUBJ=$(git -C "$path" log -1 --format='%s' "$csha" 2>/dev/null)
      DIFF="${DIFF}--- 提交 ${csha:0:7}: ${CSUBJ}"$'\n'
      DIFF="${DIFF}$(git -C "$path" show "$csha" --format="" 2>/dev/null \
        | grep -vE '^(\+\+\+|---|index |diff --git )' | head -c 3000)"$'\n'
    done < <(git -C "$path" rev-list --reverse "$OLD_SHA..$NEW_SHA" 2>/dev/null | head -10)
    DIFF=$(printf '%s' "$DIFF" | head -c 8000)
    if [ -n "$AI_TOKEN" ]; then
      AI_ERR="$CONFIG_DIR/.ai_err.tmp"
      AI_TEXT=""
      CONTEXT=$(ai_context "$name" "$group")
      for attempt in 1 2 3; do
        if AI_TEXT=$(AI_TOKEN="$AI_TOKEN" ai_analyze "$name" "$branch" "$LOGTXT" "$DIFF" "$CONTEXT" 2>"$AI_ERR"); then
          break
        fi
        log "AI分析失败(第${attempt}次): $name/$branch: $(tail -c 200 "$AI_ERR" 2>/dev/null)"
        AI_TEXT=""
        [ $attempt -lt 3 ] && sleep 5
      done
      rm -f "$AI_ERR"
    else
      AI_TEXT=""
    fi
    # 按分组+分支区分卡片颜色
    case "$group:$branch" in
      kec:main)   COLOR=green;;
      kec:test)   COLOR=blue;;
      cpi:main)   COLOR=turquoise;;
      cpi:test)   COLOR=purple;;
      h5:main)    COLOR=indigo;;
      h5:test)    COLOR=orange;;
      *:main)     COLOR=green;;
      *)          COLOR=blue;;
    esac
    if notify "$name" "$branch" "$COUNT" "$LOGTXT" "$REPO_URL" "$AI_TEXT" "$WEBHOOK" "$COLOR"; then
      log "已通知: $name/$branch $OLD_SHA..$NEW_SHA ($COUNT commits) ai=$([ -n "$AI_TEXT" ] && echo yes || echo no)"
      echo "$NEW_SHA" > "$STATE_FILE"
    else
      log "通知发送失败: $name/$branch（下次重试）"
    fi
  else
    [ -z "$OLD_SHA" ] && { echo "$NEW_SHA" > "$STATE_FILE"; log "基线: $name/$branch = ${NEW_SHA:0:8}"; }
  fi
done < "$REPOS_FILE"
exit 0
