#!/usr/bin/env bash
# 给 QQ 群/私聊会话创建「主动开口」闹钟
#
# 用法（在容器内）：
#   dsh-add-alarm              # 给所有已有会话各建一个
#   dsh-add-alarm group        # 只给群会话
#   dsh-add-alarm c2c          # 只给私聊
#
# 为什么需要单独跑：
#   dsh-proactive 的闹钟必须绑定「已存在的会话 ID」。会话是第一次收发消息时
#   才创建的，所以要先在 QQ 里说一句话，再跑这个脚本。
#
# 闹钟参数：
#   cron  0 9-23/2 * * *   每天 9 点到 23 点之间每 2 小时一次
#   jitter 1800            每次前后随机 ±30 分钟（看起来不规律）
#   respectQuietHours      23:30-08:30 期间不触发
#   prompt                 留空 => 用 config.json 的 defaultPrompt（自然版）
set -Eeuo pipefail

DSH_HOME="${DSH_HOME:-/home/node/.dsh}"
ALARMS="${DSH_HOME}/proactive/alarms.json"
SCOPE="${1:-all}"

# ── 找会话 ────────────────────────────────────────────────────────
# qqbot 的会话里记得住 scope/peer 的只有它自己的映射；这里从会话文件的
# source 字段反推。c2c 会话说白了就是「有 user 来源消息」的会话。
list_sessions() {
    local base="${DSH_HOME}/sessions"
    [ -d "$base" ] || return 0
    find "$base" -name '*.zstd' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -20 | awk '{print $2}'
}

# 从会话文件里读出 sessionId（文件名就是，目录名带 session- 前缀的要留意）
session_id_of() {
    local f="$1"
    local dir; dir=$(dirname "$f")
    basename "$dir"
}

python_add() {
    local sid="$1"
    python3 - "$sid" <<'PY'
import json, sys, os, time, uuid
from datetime import datetime, timedelta, timezone

sid = sys.argv[1]
path = os.environ.get("ALARMS", "/home/node/.dsh/proactive/alarms.json")
os.makedirs(os.path.dirname(path), exist_ok=True)

data = {"version": 2, "alarms": []}
if os.path.isfile(path):
    try:
        data = json.load(open(path))
    except Exception:
        pass
alarms = data.setdefault("alarms", [])

# 已经给这个会话建过重复的就不再建
for a in alarms:
    if a.get("ownerSessionId") == sid and a.get("status") == "scheduled":
        print(f"  跳过（已有闹钟 {a['id']}）: {sid}")
        sys.exit(0)

now = datetime.now(timezone.utc)
next_due = (now + timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")

alarm = {
    "id": "alarm_" + uuid.uuid4().hex[:12],
    "ownerSessionId": sid,
    "target": {"mode": "resume", "sourceType": "session", "sessionId": sid},
    "type": "cron",
    "trigger": {
        "expr": "0 9-23/2 * * *",     # 每天 9-23 点，每 2 小时
        "jitterSeconds": 1800,        # 前后随机 ±30 分钟
    },
    "prompt": "",                     # 空 => 用 config.json 的 defaultPrompt
    "respectQuietHours": True,
    "compaction": "minimal",
    "timeZone": "Asia/Shanghai",
    "status": "scheduled",
    "nextDueAt": next_due,
    "createdAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "updatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runCount": 0,
}
alarms.append(alarm)
tmp = path + ".tmp"
json.dump(data, open(tmp, "w"), indent=2, ensure_ascii=False)
os.replace(tmp, path)
print(f"  已创建 {alarm['id']} -> {sid}")
PY
}

# ── main ─────────────────────────────────────────────────────────
echo "==> 现有会话："
mapfile -t FILES < <(list_sessions)
if [ ${#FILES[@]} -eq 0 ]; then
    echo "  (无)"
    echo
    echo "请先在 QQ 里给她发一条消息（群里 @ 一次 / 私聊说句话），"
    echo "让会话创建出来，然后再跑一次这个命令。"
    exit 1
fi

for f in "${FILES[@]}"; do
    sid=$(session_id_of "$f")
    echo "  - $sid  ($(stat -c %y "$f" | cut -d. -f1))"
done

echo
echo "==> 创建闹钟"
for f in "${FILES[@]}"; do
    sid=$(session_id_of "$f")
    ALARMS="$ALARMS" python_add "$sid" 2>&1 | sed 's/^/  /'
done

echo
echo "==> 结果"
python3 -c "
import json
d = json.load(open('$ALARMS'))
for a in d['alarms']:
    print(f\"  {a['id']}  {a['type']:<6} {a['status']:<10} target={a['target'].get('sessionId','')[:16]}\")
"
