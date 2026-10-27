#!/usr/bin/env bash
# 切换 / 查询当前模型
#
# 用法（容器内）：
#   dsh-model            查看当前模型与可用列表
#   dsh-model list       同上
#   dsh-model <id>       切换默认模型（改 web profile，config-sync 自动同步给 qqbot）
#
# 为什么需要这个：
#   上游会对单个模型做「模型级限流」（code 6004），同凭证的其他模型不受影响。
#   只配一个模型时，一被限流 agent 就直接失败，QQ 上表现为「卡死不回」。
#   配多个模型 + 这个切换命令，限流时一条命令换模型即可恢复。
set -Eeuo pipefail

DSH_HOME="${DSH_HOME:-/home/node/.dsh}"
# 改的是 **web profile**，不是 qqbot。
#
# 因为模型配置以 Web 为准：config-sync 每 5 秒把 web 的值同步到 qqbot。
# 如果这里直接改 qqbot，5 秒后就会被拉回去，等于白改。
PROFILE="${MODEL_SOURCE_PROFILE:-web}"
CFG="${DSH_HOME}/profiles/${PROFILE}/cordis.patch.yml"

list_models() {
    # 从配置里读出 llm-pi-ai 段下所有模型 id。
    #
    # 不用正则块匹配：models 列表里夹了注释行，且 \s 会吞掉换行，
    # 导致 "- id: llm-pi-ai\n(?:...)*?" 这种写法匹配不到。
    # 改成按行扫描 —— 找到 "models:" 后，收集缩进更深的所有 "- id: xxx"。
    python3 - "$CFG" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

# 当前默认模型
cur = ""
for i, ln in enumerate(lines):
    if ln.strip() == "- id: agent-default-model":
        for j in range(i, min(i + 6, len(lines))):
            s = lines[j].strip()
            if s.startswith("model:"):
                cur = s.split(":", 1)[1].strip()
                break
        break

# 找 models: 之后的模型条目
ids = []
in_models = False
models_indent = None
for ln in lines:
    s = ln.strip()
    if not s or s.startswith("#"):
        continue
    indent = len(ln) - len(ln.lstrip())

    if s == "models:":
        in_models = True
        models_indent = indent
        continue

    if in_models:
        # 缩进回退到 <= models: 的层级 → 列表结束
        if indent <= models_indent:
            in_models = False
            continue
        # 模型条目形如 "- id: xxx"
        if s.startswith("- id:"):
            mid = s.split(":", 1)[1].strip()
            # 跳过 provider 段的 id（它们和 models 同级，靠缩进已排除）
            ids.append(mid)

# 只保留 models: 下收集的 id，并确认它后面有 "name:"（是模型条目而非服务条目）
verified = []
for i, ln in enumerate(lines):
    s = ln.strip()
    if not s.startswith("- id:"):
        continue
    mid = s.split(":", 1)[1].strip()
    if mid not in ids:
        continue
    for j in range(i + 1, min(i + 4, len(lines))):
        if lines[j].strip().startswith("name:"):
            verified.append(mid)
            break

for mid in verified:
    mark = "  <== 当前" if mid == cur else ""
    print(f"  {mid}{mark}")
PY
}

current_model() {
    python3 - "$CFG" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
m = re.search(r"- id: agent-default-model\n\s+name: [^\n]+\n\s+config:\n\s+provider: (\S+)\n\s+model: (\S+)", text)
print(f"{m.group(1)}/{m.group(2)}" if m else "(未配置)")
PY
}

# 逐个试探模型是否真的能用（换服务商后必做）
#
# 为什么需要：模型表是按当前服务商写的，换一家网关后模型名全变，
# 而且「列表里有」不等于「调得通」（限流、下架、额度都用不了）。
# 探一遍就知道该把哪个填成默认、回退表怎么排。
probe_models() {
    python3 - "$CFG" <<'PY'
import json, os, re, sys, urllib.request, urllib.error

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

# 从配置里粗提 provider 段：baseURL / apiKeyEnv / models
base_url = ""
key_env = ""
models = []
in_models = False
models_indent = None

for ln in lines:
    s = ln.strip()
    if not s or s.startswith("#"):
        continue
    if s.startswith("baseURL:"):
        base_url = s.split(":", 1)[1].strip().strip("'\"")
    elif s.startswith("apiKeyEnv:"):
        key_env = s.split(":", 1)[1].strip()
    elif s == "models:":
        in_models = True
        models_indent = len(ln) - len(ln.lstrip())
        continue
    elif in_models:
        indent = len(ln) - len(ln.lstrip())
        if indent <= models_indent:
            in_models = False
        elif s.startswith("- id:"):
            models.append(s.split(":", 1)[1].strip())

if not base_url or not models:
    print("ERROR: 配置里没找到 baseURL 或 models", file=sys.stderr)
    sys.exit(1)

key = os.environ.get(key_env, "") if key_env else ""
if not key:
    print(f"WARN: 环境变量 {key_env} 为空，可能会全部 401", file=sys.stderr)

url = base_url.rstrip("/") + "/chat/completions"
print(f"provider: {base_url}")
print(f"共 {len(models)} 个模型，逐个试（每个最多 90 秒）")
print()

ok, bad = [], []
for mid in models:
    body = json.dumps({
        "model": mid,
        "messages": [{"role": "user", "content": "say OK"}],
        "max_tokens": 150,
    }).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.loads(resp.read())
        msg = data["choices"][0]["message"]
        txt = (msg.get("content") or "").strip().replace("\n", " ")[:40]
        mark = "✓" if txt else "✓(空)"
        print(f"  {mark} {mid:32} -> {txt!r}")
        ok.append(mid)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace").replace("\n", " ")
        detail = re.sub(r'"(api_?key|authorization)"\s*:\s*"[^"]*"', r'"\1":"[REDACTED]"', detail, flags=re.I)
        print(f"  ✗ {mid:32} -> HTTP {e.code}: {detail[:150]}")
        bad.append(mid)
    except Exception as e:
        print(f"  ✗ {mid:32} -> {type(e).__name__}: {str(e)[:140]}")
        bad.append(mid)

print()
print(f"可用 {len(ok)} 个，不可用 {len(bad)} 个")
if ok:
    print(f"建议默认模型用: {ok[0]}")
else:
    print("没有可用模型 —— 检查 apiKey / baseURL / 模型名")
PY
}

case "${1:-list}" in
  list|"")
    echo "当前模型: $(current_model)"
    echo
    echo "可用模型:"
    list_models
    echo
    echo "切换: dsh-model <id>"
    echo "探活: dsh-model probe"
    ;;

  probe)
    probe_models
    ;;

  *)
    NEW="$1"
    # 校验目标模型确实在配置里
    if ! list_models | grep -q "  ${NEW}"; then
        echo "ERROR: 模型 '${NEW}' 不在配置里" >&2
        echo "可用:" >&2
        list_models >&2
        exit 1
    fi

    echo "==> 切换模型: $(current_model) -> ${NEW}"
    cp "$CFG" "${CFG}.bak-model-$(date +%H%M%S)"

    python3 - "$CFG" "$NEW" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    text = f.read()
new_text, n = re.subn(
    r"(- id: agent-default-model\n\s+name: [^\n]+\n\s+config:\n\s+provider: \S+\n\s+model: )\S+",
    lambda m: m.group(1) + new,
    text,
)
if n == 0:
    sys.exit("ERROR: 没找到 agent-default-model 段")
open(path, "w", encoding="utf-8").write(new_text)
PY

    # 不需要重启任何进程。
    #
    # 改的是 web profile，config-sync 每 5 秒把值同步给 qqbot，
    # qqbot 那边是调 agentDefaultModel.saveSelection()，进程内立即生效。
    #
    # ⚠️ 千万别在这里 pkill "dsh --profile web"：entrypoint 的监控循环
    # 认为 web 挂掉就该退出容器，杀了 web 等于把整个容器干掉。
    echo "==> 已改 web profile，等待 config-sync 同步给 qqbot（最多 15 秒）..."

    i=0
    while [ $i -lt 15 ]; do
        sleep 1
        synced="$(python3 - "${DSH_HOME}/profiles/${QQ_PROFILE:-qqbot}/cordis.patch.yml" "${NEW}" <<'PY'
import re, sys
path, want = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
except OSError:
    sys.exit(1)
m = re.search(r"- id: agent-default-model\n\s+name: [^\n]+\n\s+config:\n\s+provider: (\S+)\n\s+model: (\S+)", text)
if m and m.group(2) == want:
    print("yes")
PY
)"
        if [ "$synced" = "yes" ]; then
            echo "==> 完成，qqbot 已跟随: $(current_model)"
            exit 0
        fi
        i=$((i+1))
    done
    echo "WARN: 15 秒内 qqbot 还没跟随。看日志: docker compose logs dsh | grep config-sync" >&2
    echo "     web profile 已改为: $(current_model)"
    ;;
esac

