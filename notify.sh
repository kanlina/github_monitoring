#!/bin/bash
# git-notify: 本地轮询 GitHub 仓库，有新提交则推飞书群（交互卡片 + AI 变更分析）
# 配置: ~/.config/git-notify/repos.conf
#       每行: 名称|仓库本地路径|分支|分组(可选,默认kec)
#       分支列写 * 表示动态监听该仓库的所有远端分支（新建分支自动纳入、删除分支自动清理，
#       自动忽略 dependabot/* 机器人分支）
#       ~/.config/git-notify/webhook.txt  飞书自定义机器人 webhook 地址
#       ~/.config/git-notify/ai_key.txt   AI 中转服务 token
# 状态: ~/.config/git-notify/state/   （分支名中的 / 会替换为 __ 存储）
# AI 补发: AI 分析失败的提交进入 pending.list 队列，后续轮询自动重试并补发 AI 分析卡片
# 并发保护: 由 cron 层 flock 完成（见 README），本脚本自身不加锁

CONFIG_DIR="$HOME/.config/git-notify"
REPOS_FILE="$CONFIG_DIR/repos.conf"
WEBHOOK_FILE="$CONFIG_DIR/webhook.txt"
AI_KEY_FILE="$CONFIG_DIR/ai_key.txt"
STATE_DIR="$CONFIG_DIR/state"
PENDING_FILE="$CONFIG_DIR/pending.list"
LOG_FILE="$CONFIG_DIR/notify.log"
AI_MAX_ATTEMPTS=3
AI_RETRY_SLEEP=5
PENDING_MAX_AGE=86400   # 补发队列最长保留 24h

# 动态模式下忽略的分支（正则）
IGNORE_BRANCH_RE='^dependabot/'

WEBHOOK=$(head -n1 "$WEBHOOK_FILE" 2>/dev/null | tr -d '[:space:]')
[ -z "$WEBHOOK" ] && exit 0
AI_TOKEN=$(head -n1 "$AI_KEY_FILE" 2>/dev/null | tr -d '[:space:]')
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }
log "心跳: 本轮开始 (pid=$$)"

# 生成提交素材（通知与 AI 补发共用）→ 设置全局 G_LOGTXT / G_DIFF / G_COUNT / G_REPO_URL
gen_materials() {  # $1=路径 $2=旧SHA $3=新SHA
  local path="$1" old="$2" new="$3" csha CSUBJ
  G_COUNT=$(git -C "$path" rev-list --count "$old..$new" 2>/dev/null || echo "?")
  G_REPO_URL=$(git -C "$path" remote get-url origin 2>/dev/null \
    | sed -e 's#git@github.com:#https://github.com/#' -e 's#\.git$##')
  G_LOGTXT=$(git -C "$path" log --date=format:'%Y-%m-%d %H:%M' \
    --format="- [%h](${G_REPO_URL}/commit/%H) %an · %ad: %s" \
    "$old..$new" 2>/dev/null | head -20)
  G_DIFF=""
  while read -r csha; do
    [ -z "$csha" ] && continue
    CSUBJ=$(git -C "$path" log -1 --format='%s' "$csha" 2>/dev/null)
    G_DIFF="${G_DIFF}--- 提交 ${csha:0:7}: ${CSUBJ}"$'\n'
    G_DIFF="${G_DIFF}$(git -C "$path" show "$csha" --format="" 2>/dev/null \
      | grep -vE '^(\+\+\+|---|index |diff --git )' | head -c 3000)"$'\n'
  done < <(git -C "$path" rev-list --reverse "$old..$new" 2>/dev/null | head -10)
  G_DIFF=$(printf '%s' "$G_DIFF" | head -c 8000)
}

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

notify() {  # $1=repo名 $2=分支 $3=提交数 $4=commit markdown $5=仓库URL $6=AI分析文本 $7=webhook $8=颜色 $9=标题前缀
  python3 - "$@" <<'PY'
import json, sys, urllib.request
from datetime import datetime
name, branch, count, logtxt, repo_url, ai_text, webhook, color, title = sys.argv[1:10]

header = {"template": color, "title": {"tag": "plain_text",
          "content": f"{title} | {name} @ {branch}"}}
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

color_for() {  # $1=分组 $2=分支 → 飞书卡片标题颜色
  local grp="$1" b="$2"
  case "$b" in
    main|master)
      case "$grp" in cpi) echo turquoise ;; h5) echo indigo ;; td) echo carmine ;; *) echo green ;; esac ;;
    test)
      case "$grp" in cpi) echo purple ;; h5) echo orange ;; *) echo blue ;; esac ;;
    develop|dev|v2)
      echo violet ;;
    *)
      echo yellow ;;
  esac
}

run_ai() {  # $1=名称 $2=分支 $3=LOGTXT $4=DIFF $5=CONTEXT → stdout AI 文本，失败返回非0
  local attempt AI_ERR="$CONFIG_DIR/.ai_err.tmp" AI_OUT=""
  for attempt in $(seq 1 "$AI_MAX_ATTEMPTS"); do
    if AI_OUT=$(AI_TOKEN="$AI_TOKEN" ai_analyze "$1" "$2" "$3" "$4" "$5" 2>"$AI_ERR"); then
      rm -f "$AI_ERR"; echo "$AI_OUT"; return 0
    fi
    log "AI分析失败(第${attempt}次): $1/$2: $(tail -c 200 "$AI_ERR" 2>/dev/null)"
    [ "$attempt" -lt "$AI_MAX_ATTEMPTS" ] && sleep "$AI_RETRY_SLEEP"
  done
  rm -f "$AI_ERR"
  return 1
}

process_branch() {  # $1=名称 $2=路径 $3=分支 $4=分组 （调用前需已 fetch，origin/$3 为最新）
  local name="$1" path="$2" branch="$3" group="$4"
  local NEW_SHA OLD_SHA STATE_FILE
  NEW_SHA=$(git -C "$path" rev-parse "origin/$branch" 2>/dev/null) || return 0
  STATE_FILE="$STATE_DIR/$name.${branch//\//__}.sha"
  OLD_SHA=$(cat "$STATE_FILE" 2>/dev/null)
  if [ -n "$OLD_SHA" ] && [ "$OLD_SHA" != "$NEW_SHA" ]; then
    gen_materials "$path" "$OLD_SHA" "$NEW_SHA"
    local AI_TEXT="" CONTEXT
    CONTEXT=$(ai_context "$name" "$group")
    if [ -n "$AI_TOKEN" ]; then
      AI_TEXT=$(run_ai "$name" "$branch" "$G_LOGTXT" "$G_DIFF" "$CONTEXT")
      if [ -z "$AI_TEXT" ]; then
        # AI 失败：进入补发队列（下次轮询自动重试分析并补发卡片）
        echo "$name|$path|$branch|$group|$OLD_SHA|$NEW_SHA|$(date +%s)" >> "$PENDING_FILE"
        log "已加入AI补发队列: $name/$branch"
      fi
    fi
    if notify "$name" "$branch" "$G_COUNT" "$G_LOGTXT" "$G_REPO_URL" "$AI_TEXT" "$WEBHOOK" \
        "$(color_for "$group" "$branch")" "🚀 commit 通知"; then
      log "已通知: $name/$branch $OLD_SHA..$NEW_SHA ($G_COUNT commits) ai=$([ -n "$AI_TEXT" ] && echo yes || echo no)"
      echo "$NEW_SHA" > "$STATE_FILE"
    else
      log "通知发送失败: $name/$branch（下次重试）"
    fi
  else
    [ -z "$OLD_SHA" ] && { echo "$NEW_SHA" > "$STATE_FILE"; log "基线: $name/$branch = ${NEW_SHA:0:8}"; }
  fi
}

process_pending() {  # 补发队列：重试 AI，成功则补发分析卡片（标题含 commit 关键词以过机器人安全校验）
  [ -f "$PENDING_FILE" ] || return 0
  local keep="" line now=$(date +%s)
  while IFS='|' read -r name path branch group oldsha newsha ts; do
    case "$name" in ''|\#*) continue ;; esac
    local age=$(( now - ts ))
    if [ "$age" -gt "$PENDING_MAX_AGE" ]; then
      log "AI补发放弃(超过24h): $name/$branch"
      continue
    fi
    gen_materials "$path" "$oldsha" "$newsha"
    local CONTEXT AI_TEXT
    CONTEXT=$(ai_context "$name" "$group")
    AI_TEXT=$(AI_TOKEN="$AI_TOKEN" ai_analyze "$name" "$branch" "$G_LOGTXT" "$G_DIFF" "$CONTEXT" 2>/dev/null)
    if [ -n "$AI_TEXT" ]; then
      if notify "$name" "$branch" "$G_COUNT" "$G_LOGTXT" "$G_REPO_URL" "$AI_TEXT" "$WEBHOOK" \
          "$(color_for "$group" "$branch")" "🤖 commit AI 分析补发"; then
        log "AI补发成功: $name/$branch ($oldsha..$newsha)"
        continue   # 成功：不保留该行
      fi
      log "AI补发卡片发送失败: $name/$branch"
    else
      log "AI补发仍失败: $name/$branch（继续排队）"
    fi
    keep="${keep}${name}|${path}|${branch}|${group}|${oldsha}|${newsha}|${ts}"$'\n'
  done < "$PENDING_FILE"
  printf '%s' "$keep" > "$PENDING_FILE"
}

process_repo() {  # $1=名称 $2=路径 $3=分支(*=动态全部) $4=分组
  local name="$1" path="$2" branch="$3" group="$4"
  if [ "$branch" != "*" ]; then
    git -C "$path" fetch origin "$branch" --quiet 2>>"$LOG_FILE" \
      || { log "fetch失败: $name/$branch"; return 0; }
    process_branch "$name" "$path" "$branch" "$group"
    return 0
  fi
  # 动态模式：拉取所有分支并清理失效引用
  git -C "$path" fetch origin --prune --quiet 2>>"$LOG_FILE" \
    || { log "fetch失败: $name/*"; return 0; }
  local branches current b
  branches=$(git -C "$path" for-each-ref refs/remotes/origin --format='%(refname:short)' 2>/dev/null \
    | sed 's|^origin/||' | grep -v '^HEAD$' | grep -vE "$IGNORE_BRANCH_RE")
  for b in $branches; do
    process_branch "$name" "$path" "$b" "$group"
  done
  # 清理已删除分支的基线文件
  local f fb
  for f in "$STATE_DIR"/"$name".*.sha; do
    [ -e "$f" ] || continue
    fb="${f##*/}"; fb="${fb#"$name".}"; fb="${fb%.sha}"; fb="${fb//__/\/}"
    if ! echo "$branches" | grep -qxF "$fb"; then
      rm -f "$f"
      log "分支已删除，清理基线: $name/$fb"
    fi
  done
}

process_pending   # 先处理上一轮 AI 失败的补发队列

while IFS='|' read -r name path branch group; do
  case "$name" in ''|\#*) continue ;; esac
  group="${group:-kec}"
  process_repo "$name" "$path" "$branch" "$group"
done < "$REPOS_FILE"
exit 0
