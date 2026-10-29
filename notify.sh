#!/bin/bash
# git-notify: 本地轮询 GitHub 仓库，有新提交则推飞书群（交互卡片 + AI 变更分析）
# 配置: ~/.config/git-notify/repos.conf
#       每行: 名称|仓库本地路径|分支|分组(可选,默认kec)
#       分支列写 * 表示动态监听该仓库的所有远端分支（新建分支自动纳入、删除分支自动清理，
#       自动忽略 dependabot/* 机器人分支）
#       ~/.config/git-notify/webhook.txt  飞书自定义机器人 webhook 地址
#       ~/.config/git-notify/webhook_en.txt 英文推送 webhook 地址（可选，配置后主通知同时发英文版）
#       ~/.config/git-notify/ai_key.txt   AI 中转服务 token
# 状态: ~/.config/git-notify/state/   （分支名中的 / 会替换为 __ 存储）
# AI 合并发送: AI 分析失败时整条通知进入 pending.list 队列等待，AI 成功后与 commit 信息
#          合并为一张卡片发送（超 24h 仍未成功则降级发送无 AI 的纯脚本卡）
# 并发保护: 由 cron 层 flock 完成（见 README），本脚本自身不加锁

CONFIG_DIR="$HOME/.config/git-notify"
REPOS_FILE="$CONFIG_DIR/repos.conf"
WEBHOOK_FILE="$CONFIG_DIR/webhook.txt"
WEBHOOK_EN_FILE="$CONFIG_DIR/webhook_en.txt"
AI_KEY_FILE="$CONFIG_DIR/ai_key.txt"
STATE_DIR="$CONFIG_DIR/state"
PENDING_FILE="$CONFIG_DIR/pending.list"
VIOL_FILE="$CONFIG_DIR/violations.list"   # 未恢复违规记录: 名称|分支|文件|内容|时间戳
LOG_FILE="$CONFIG_DIR/notify.log"
AI_MAX_ATTEMPTS=3
AI_RETRY_SLEEP=5
PENDING_MAX_AGE=86400   # 补发队列最长保留 24h

# 动态模式下忽略的分支（正则）
IGNORE_BRANCH_RE='^dependabot/'

WEBHOOK=$(head -n1 "$WEBHOOK_FILE" 2>/dev/null | tr -d '[:space:]')
WEBHOOK_EN=$(head -n1 "$WEBHOOK_EN_FILE" 2>/dev/null | tr -d '[:space:]')
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
      | grep -vE '^index ' | head -c 3000)"$'\n'
  done < <(git -C "$path" rev-list --reverse "$old..$new" 2>/dev/null | head -10)
  G_DIFF=$(printf '%s' "$G_DIFF" | head -c 8000)
  # 确定性扫描新增行中的中文字符 → 精确到文件与行号的违规清单
  G_CJK=$(git -C "$path" diff "$old..$new" --unified=0 2>/dev/null | python3 -c '
import sys, re
cjk = re.compile(r"[\u4e00-\u9fff]")
file = None; newline = 0; out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("diff --git"):
        m = re.search(r" b/(.+)$", line); file = m.group(1) if m else "?"
    elif line.startswith("@@"):
        m = re.search(r"\+(\d+)", line); newline = int(m.group(1)) if m else 0
    elif line.startswith("+") and not line.startswith("+++"):
        if cjk.search(line[1:]):
            out.append("- " + str(file) + ":" + str(newline) + " " + line[1:].strip()[:100])
        newline += 1
    elif line.startswith("-") or line.startswith("---"):
        pass
    else:
        newline += 1
sys.stdout.write("\n".join(out[:30]))
' 2>/dev/null)
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
lang = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6].strip() else "zh"
diff = diff[:8000]
ctx = ctx[:3000]
INSTR_ZH = "你是资深工程师兼产品顾问。输入包含按提交拆分的变更说明、diff，以及同一产品其他端项目的近期提交动态。用简体中文做分析，550 字以内，按以下四段输出（段落标题用【】，不要使用 markdown 标题）:\n【技术实现】逐条提交说明：每条提交一行，直接讲技术实现——改动的关键类/组件/接口/字段/配置项，以及逻辑如何变化，不写产品目的\n【对用户的影响】普通用户会感知到什么变化？哪些操作流程会不一样？对业务指标（如注册转化、放款、还款）可能有什么影响\n【风险与建议】技术风险（如边界条件、兼容性、数据一致性）+ 建议重点回归的具体场景。若本批提交与关联项目近期提交是同一需求的跨端配合（如客户端与后端联动改造），请明确指出配合关系及上线顺序依赖（哪端先上/需同时上）\n【规范拦截】只负责检查 diff 与提交信息中是否出现开发人员姓名/拼音标识写死在代码中的情况（如 godwish、zhangpu、kanlina 等被写进代码、注释或变量名）。仅在确实发现时才输出本段，格式为「【规范拦截】姓名/拼音违规：<文件与内容>」；未发现时省略本段，禁止输出「未发现违规项」等任何无违规表述（中文字符违规由脚本另行标注，与你无关）"
INSTR_EN = "You are a senior engineer and product consultant. The input contains per-commit change descriptions, the diff, and recent commit activity of related projects of the same product. Analyze in English within 350 words and output four sections (section titles in brackets, no markdown headings):\n【Technical Implementation】One line per commit: the key classes/components/interfaces/fields/config items changed and how the logic changes; do not describe product goals\n【User Impact】What would ordinary users notice? Which operation flows change? Possible impact on business metrics such as registration conversion, disbursement and repayment\n【Risks & Suggestions】Technical risks (edge cases, compatibility, data consistency) plus specific scenarios that need focused regression testing. If these commits form cross-platform coordination with recent commits of related projects (e.g., client and backend of the same feature), point out the coordination and the rollout order dependency (which side goes first / must go live together)\n【Compliance】Only check whether developer names or pinyin identifiers are hardcoded in the diff or commit messages (e.g., godwish, zhangpu, kanlina written into code, comments or variable names). Output this section ONLY when something is actually found, in the format 「【Compliance】Name/pinyin violation: <file and content>」; omit this section when nothing is found and never output any no-violation statement (Chinese-character violations are flagged separately by the script)"
prompt = f"""仓库 {name} 的 {branch} 分支有新提交。

提交记录:
{logtxt}

按提交拆分的代码变更 diff（可能截断，含文件名与行号信息）:
```diff
{diff}
```

同一产品的关联项目近期提交动态（供参考，用于识别跨端配合/依赖关系）:
{ctx or "（无）"}

请按 instructions 中的格式输出分析，不要输出其他内容。"""
data = {
    "model": "gpt-6.1-sol",
    "instructions": INSTR_ZH if lang == "zh" else INSTR_EN,
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

notify() {  # $1=repo名 $2=分支 $3=提交数 $4=commit markdown $5=仓库URL $6=AI分析文本 $7=webhook $8=颜色 $9=标题前缀 $10=统计行文案(可选)
  python3 - "$@" <<'PY'
import json, sys, urllib.request
from datetime import datetime
name, branch, count, logtxt, repo_url, ai_text, webhook, color, title = sys.argv[1:10]
lang = sys.argv[11] if len(sys.argv) > 11 else "zh"
if len(sys.argv) > 10 and sys.argv[10]:
    count_label = sys.argv[10]
else:
    count_label = f"Detected {count} new commit(s)" if lang == "en" else f"检测到 {count} 个新提交"
ai_label = "**🤖 AI Analysis**" if lang == "en" else "**🤖 AI 分析**"
button_text = "View Code" if lang == "en" else "查看代码"
wh_tag = webhook.rsplit("/", 1)[-1][:8]
note_text = ("git-notify auto push · " if lang == "en" else "git-notify 自动推送 · ") \
    + wh_tag + " · " + datetime.now().strftime('%Y-%m-%d %H:%M')

header = {"template": color, "title": {"tag": "plain_text",
          "content": f"{title} | {name} @ {branch}"}}
elements = [
    {"tag": "div", "text": {"tag": "lark_md",
        "content": f"**{count_label}**\n" + logtxt}},
]
if ai_text:
    elements.append({"tag": "div", "text": {"tag": "lark_md",
        "content": f"{ai_label}\n{ai_text}"}})
elements += [
    {"tag": "action", "actions": [{"tag": "button", "text": {
        "tag": "plain_text", "content": button_text},
        "type": "primary", "url": repo_url}]},
    {"tag": "hr"},
    {"tag": "note", "elements": [{"tag": "plain_text",
        "content": note_text}]},
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

record_violations() {  # $1=名称 $2=分支 $3=中文违规清单 $4=检测时基线SHA → 记录未恢复违规
  local name="$1" branch="$2" item file line content rest sha_="$4"
  [ -n "$3" ] || return 0
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    item="${item#- }"
    file="${item%%:*}"
    rest="${item#*:}"
    line="${rest%% *}"
    content="${rest#* }"
    content="${content//|/／}"
    [ -z "$content" ] && continue
    if [ -f "$VIOL_FILE" ] && grep -qF "$name|$branch|$file|$content|" "$VIOL_FILE" 2>/dev/null; then
      continue
    fi
    echo "$name|$branch|$file|$content|$sha_|$(date +%s)" >> "$VIOL_FILE"
    log "记录违规: $name/$branch $file:$line (base=$sha_)"
  done <<< "$3"
}

find_fix_commit() {  # $1=路径 $2=分支 $3=检测基线SHA $4=新SHA $5=内容 $6=文件 → 输出 "完整SHA 短SHA"
  python3 - "$@" <<'PY'
import subprocess, sys
path, branch, base, new, content, file = sys.argv[1:7]
def pickaxe(rng):
    out = subprocess.run(
        ["git", "-C", path, "log", rng, "--format=%H %h", "-S", content, "--", file],
        capture_output=True, text=True)
    return [l for l in out.stdout.strip().splitlines() if l]
# 优先在“检测基线 → 最新”区间找移除该内容的提交
lines = pickaxe(f"{base}..{new}") if base and base != new else []
if not lines:  # 兜底：该分支全历史中最近一次增删该内容的提交
    lines = pickaxe("origin/" + branch)
if lines:
    full, short = lines[0].split()
    print(full, short)
PY
}

record_ai_violation() {  # $1=名称 $2=分支 $3=提交SHA → 记录 AI 判定的违规（无精确文件行号，按 名称+分支 去重）
  local name="$1" branch="$2" sha="$3"
  if [ -f "$VIOL_FILE" ] && grep -qF "$name|$branch|（AI 综合判定）|" "$VIOL_FILE" 2>/dev/null; then
    return 0
  fi
  echo "$name|$branch|（AI 综合判定）|（姓名/拼音违规，详见红卡 AI 分析）|$sha|$(date +%s)" >> "$VIOL_FILE"
  log "记录违规(AI判定): $name/$branch"
}

check_resolutions() {  # $1=名称 $2=路径 $3=分支 $4=新SHA $5=本轮是否有违规(0/1) → 检查未恢复违规是否已消失，并定位修复提交
  local name="$1" path="$2" branch="$3" new_sha="$4" has_violation="$5"
  [ -f "$VIOL_FILE" ] || return 0
  RESOLVED_LIST=""; RESOLVED_COUNT=0
  local REPO_URL
  REPO_URL=$(git -C "$path" remote get-url origin 2>/dev/null \
    | sed -e 's#git@github.com:#https://github.com/#' -e 's#\.git$##')
  local keep="" line name_ branch_ file_ content_ base_ ts fix_line full short
  while IFS='|' read -r name_ branch_ file_ content_ base_ ts; do
    case "$name_" in ''|\#*) continue ;; esac
    if [ "$name_" = "$name" ] && [ "$branch_" = "$branch" ]; then
      if [ "$file_" = "（AI 综合判定）" ]; then
        # AI 综合判定条目：本批已无违规 → 判定已修复（修复提交=本批最新提交）
        if [ "$has_violation" = "0" ]; then
          RESOLVED_COUNT=$((RESOLVED_COUNT+1))
          RESOLVED_LIST="${RESOLVED_LIST}- （AI 综合判定）—— 姓名/拼音违规已修复（修复提交: [$new_sha](${REPO_URL}/commit/${new_sha})）"$'\n'
          log "违规已修复(AI判定): $name/$branch 修复提交: $new_sha"
        else
          keep="${keep}${name_}|${branch_}|${file_}|${content_}|${base_}|${ts}"$'\n'
        fi
      elif git -C "$path" grep -qF -- "$content_" "origin/$branch" -- "$file_" 2>/dev/null; then
        keep="${keep}${name_}|${branch_}|${file_}|${content_}|${base_}|${ts}"$'\n'   # 内容仍在 → 未恢复
      else
        full=""; short=""
        fix_line=$(find_fix_commit "$path" "$branch" "$base_" "$new_sha" "$content_" "$file_") || true
        if [ -n "$fix_line" ]; then
          full=$(echo "$fix_line" | awk '{print $1}'); short=$(echo "$fix_line" | awk '{print $2}')
        fi
        RESOLVED_COUNT=$((RESOLVED_COUNT+1))
        if [ -n "$short" ]; then
          RESOLVED_LIST="${RESOLVED_LIST}- ${file_} —— 已移除：${content_}（违规来源: [${base_:0:8}](${REPO_URL}/commit/${base_}) ｜ 修复提交: [$short](${REPO_URL}/commit/${full})）"$'\n'
        else
          RESOLVED_LIST="${RESOLVED_LIST}- ${file_} —— 已移除：${content_}（修复提交未定位到）"$'\n'
        fi
        log "违规已修复: $name/$branch $file_（原: $content_）修复提交: ${short:-未知}"
      fi
    else
      keep="${keep}${name_}|${branch_}|${file_}|${content_}|${base_}|${ts}"$'\n'
    fi
  done < "$VIOL_FILE"
  printf '%s' "$keep" > "$VIOL_FILE"
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

run_ai() {  # $1=名称 $2=分支 $3=LOGTXT $4=DIFF $5=CONTEXT $6=中文违规清单 → stdout AI 文本，失败返回非0
  local attempt AI_ERR="$CONFIG_DIR/.ai_err.tmp" AI_OUT=""
  for attempt in $(seq 1 "$AI_MAX_ATTEMPTS"); do
    if AI_OUT=$(AI_TOKEN="$AI_TOKEN" ai_analyze "$1" "$2" "$3" "$4" "$5" zh 2>"$AI_ERR"); then
      rm -f "$AI_ERR"; echo "$AI_OUT"; return 0
    fi
    log "AI分析失败(第${attempt}次): $1/$2: $(tail -c 200 "$AI_ERR" 2>/dev/null)"
    [ "$attempt" -lt "$AI_MAX_ATTEMPTS" ] && sleep "$AI_RETRY_SLEEP"
  done
  rm -f "$AI_ERR"
  return 1
}

emit_card() {  # $1=名称 $2=路径 $3=分支 $4=分组 $5=OLD_SHA $6=NEW_SHA $7=AI文本(可空) $8=关联项目上下文 → 合并发送一张完整卡片
  local name="$1" path="$2" branch="$3" group="$4" old="$5" new="$6"
  local AI_TEXT="$7" CONTEXT="$8"
  gen_materials "$path" "$old" "$new"
  # ---- 规范拦截判定（脚本中文扫描 + AI 姓名判定，任一命中即违规）----
  local HAS_VIOLATION=0
  if [ -n "$G_CJK" ]; then HAS_VIOLATION=1; fi
  if [ -n "$AI_TEXT" ] && printf '%s' "$AI_TEXT" | grep -q "【规范拦截】" \
     && ! printf '%s' "$AI_TEXT" | grep -q "未发现违规项"; then
    HAS_VIOLATION=1
  fi
  # 中文违规由脚本确定性拼入卡片（保证 文件:行号:内容 必现）
  if [ -n "$G_CJK" ]; then
    AI_TEXT="${AI_TEXT}${AI_TEXT:+$'\n\n'}【规范拦截】中文字符违规（脚本精确定位）："$'\n'"$G_CJK"
  fi
  # 违规闭环：记录新违规（CJK 精确条目；AI 判定且无 CJK 条目时记综合判定条目）
  record_violations "$name" "$branch" "$G_CJK" "$new"
  if [ "$HAS_VIOLATION" -eq 1 ] && [ -z "$G_CJK" ]; then
    record_ai_violation "$name" "$branch" "$new"
  fi
  local COLOR
  COLOR=$(color_for "$group" "$branch")
  [ "$HAS_VIOLATION" -eq 1 ] && { COLOR=red; log "规范拦截触发: $name/$branch"; }
  if ! notify "$name" "$branch" "$G_COUNT" "$G_LOGTXT" "$G_REPO_URL" "$AI_TEXT" "$WEBHOOK" \
      "$COLOR" "🚀 commit 通知"; then
    log "通知发送失败: $name/$branch（下次重试）"
    return 1
  fi
  log "已通知: $name/$branch $old..$new ($G_COUNT commits) ai=$([ -n "$AI_TEXT" ] && echo yes || echo no)"
  echo "$new" > "$STATE_DIR/$name.${branch//\//__}.sha"
  # ---- 英文镜像推送（配置 webhook_en.txt 时启用）----
  if [ -n "$WEBHOOK_EN" ]; then
    local EN_TEXT=""
    if [ -n "$AI_TOKEN" ]; then
      EN_TEXT=$(run_ai "$name" "$branch" "$G_LOGTXT" "$G_DIFF" "$CONTEXT" en)
    fi
    if [ -n "$G_CJK" ]; then
      EN_TEXT="${EN_TEXT}${EN_TEXT:+$'\n\n'}【Compliance】Chinese characters in new code (located by script):"$'\n'"$G_CJK"
    fi
    if notify "$name" "$branch" "$G_COUNT" "$G_LOGTXT" "$G_REPO_URL" "$EN_TEXT" "$WEBHOOK_EN" \
        "$COLOR" "🚀 Commit Notification" "Detected $G_COUNT new commit(s)" en; then
      log "已通知(EN): $name/$branch ai=$([ -n "$EN_TEXT" ] && echo yes || echo no)"
    else
      log "英文通知发送失败: $name/$branch"
    fi
  fi
  # 违规恢复检测：本批已无违规但存在未恢复记录 → 判定为已修复（修复提交=本批 SHA）
  RESOLVED_LIST=""; RESOLVED_COUNT=0
  check_resolutions "$name" "$path" "$branch" "$new" "$HAS_VIOLATION"
  if [ "$RESOLVED_COUNT" -gt 0 ]; then
    if notify "$name" "$branch" "$RESOLVED_COUNT" "$RESOLVED_LIST" "$G_REPO_URL" "" "$WEBHOOK" \
        green "✅ commit 规范违规已修复" "已修复 ${RESOLVED_COUNT} 项规范违规"; then
      log "违规恢复通知: $name/$branch ($RESOLVED_COUNT 项)"
    fi
  fi
  return 0
}

queue_notify() {  # $1=名称 $2=路径 $3=分支 $4=分组 $5=OLD_SHA $6=NEW_SHA → 通知挂队列（同分支旧批次被新批次覆盖，去重）
  local name="$1" path="$2" branch="$3" group="$4" old="$5" new="$6" tmp="" pline
  if [ -f "$PENDING_FILE" ]; then
    while IFS= read -r pline; do
      case "$pline" in "$name|$path|$branch|"*) continue ;; esac
      tmp="${tmp}${pline}"$'\n'
    done < "$PENDING_FILE"
    printf '%s' "$tmp" > "$PENDING_FILE"
  fi
  echo "$name|$path|$branch|$group|$old|$new|$(date +%s)" >> "$PENDING_FILE"
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
        # AI 失败：不先发卡，整条通知挂队列，等 AI 成功后合并为一张卡发送（超 24h 降级纯脚本卡）
        queue_notify "$name" "$path" "$branch" "$group" "$OLD_SHA" "$NEW_SHA"
        log "AI暂不可用，通知挂队列待合并发送: $name/$branch ($OLD_SHA..$NEW_SHA)"
        return 0
      fi
    fi
    emit_card "$name" "$path" "$branch" "$group" "$OLD_SHA" "$NEW_SHA" "$AI_TEXT" "$CONTEXT" \
      || log "下轮将重新检测: $name/$branch"
  else
    [ -z "$OLD_SHA" ] && { echo "$NEW_SHA" > "$STATE_FILE"; log "基线: $name/$branch = ${NEW_SHA:0:8}"; }
  fi
}

process_pending() {  # 补发队列：重试 AI，成功则与 commit 信息合并为一张卡发送；超 24h 降级发纯脚本卡
  [ -f "$PENDING_FILE" ] || return 0
  local keep="" line now=$(date +%s)
  while IFS='|' read -r name path branch group oldsha newsha ts; do
    case "$name" in ''|\#*) continue ;; esac
    local age=$(( now - ts )) CONTEXT AI_TEXT=""
    if [ "$age" -le "$PENDING_MAX_AGE" ] && [ -n "$AI_TOKEN" ]; then
      gen_materials "$path" "$oldsha" "$newsha"
      CONTEXT=$(ai_context "$name" "$group")
      AI_TEXT=$(AI_TOKEN="$AI_TOKEN" ai_analyze "$name" "$branch" "$G_LOGTXT" "$G_DIFF" "$CONTEXT" 2>/dev/null)
      if [ -z "$AI_TEXT" ]; then
        log "AI仍不可用，继续等待合并发送: $name/$branch（已等 $((age/60)) 分钟）"
        keep="${keep}${name}|${path}|${branch}|${group}|${oldsha}|${newsha}|${ts}"$'\n'
        continue
      fi
    else
      gen_materials "$path" "$oldsha" "$newsha"
      [ "$age" -gt "$PENDING_MAX_AGE" ] && log "AI超24h不可用，降级发送纯脚本卡: $name/$branch"
    fi
    if emit_card "$name" "$path" "$branch" "$group" "$oldsha" "$newsha" "$AI_TEXT" "$CONTEXT"; then
      log "合并通知发送成功: $name/$branch ($oldsha..$newsha)"
    else
      log "通知发送失败，继续排队: $name/$branch"
      keep="${keep}${name}|${path}|${branch}|${group}|${oldsha}|${newsha}|${ts}"$'\n'
    fi
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
      if [ -f "$VIOL_FILE" ] && grep -qF "$name|$fb|" "$VIOL_FILE" 2>/dev/null; then
        grep -vF "$name|$fb|" "$VIOL_FILE" > "$VIOL_FILE.tmp" && mv "$VIOL_FILE.tmp" "$VIOL_FILE"
        log "分支已删除，清理违规记录: $name/$fb"
      fi
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
