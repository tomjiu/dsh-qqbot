#!/usr/bin/env bash
# 单进程架构的启动自检
#
# 用法（容器内）：dsh-verify
#
# 为什么需要：这次架构改动的收益全部来自「Web 和 QQ 在同一个 dsh 宿主里」。
# 如果哪天有人把两条 bundle 拆回两个 profile，功能会以极隐蔽的方式退化
# （会话照常收发，但工作区归不上、模型选择器读不到、绑定页消失），
# 排查成本极高。这个脚本把那些隐性契约变成能红的断言。
set -Eeuo pipefail

DSH_HOME="${DSH_HOME:-/home/node/.dsh}"
PROFILE="${MAIN_PROFILE:-main}"
P="${DSH_HOME}/profiles/${PROFILE}"

pass=0
fail=0
check() {
    local name="$1" ok="$2" detail="${3:-}"
    if [ "$ok" = "1" ]; then
        pass=$((pass+1)); printf '  ✓ %s\n' "$name"
    else
        fail=$((fail+1)); printf '  ✗ %s%s\n' "$name" "${detail:+  ← $detail}"
    fi
}

echo "profile: $P"

# ── 1. profile 组合 ────────────────────────────────────────────
echo
echo "【组合】两条 bundle 必须在同一棵树里"
composed=$(cd "$P" && dsh --profile "$PROFILE" --dump-config 2>/dev/null || true)
has() { printf '%s' "$composed" | grep -q "id: $1"; }
check "webserver 行存在（dsh-web-app 已挂）" "$(has webserver && echo 1 || echo 0)"
check "im-qqbot 行存在（qqbot 已挂）"        "$(has im-qqbot && echo 1 || echo 0)"
check "session-controller 行存在"            "$(has session-controller && echo 1 || echo 0)"
check "workspace 行存在"                     "$(has workspace && echo 1 || echo 0)"
check "agent-default-model 行存在"           "$(has agent-default-model && echo 1 || echo 0)"

# ── 2. 只有一个 profile ─────────────────────────────────────────
echo
echo "【单一宿主】只应有一个 profile 目录"
n=$(find "${DSH_HOME}/profiles" -maxdepth 1 -mindepth 1 -type d -not -name '.*' | wc -l)
check "profiles 下只有 1 个目录（实际 $n 个）" "$([ "$n" -le 1 ] && echo 1 || echo 0)"

# ── 3. 关键配置项必须留空/正确 ─────────────────────────────────
echo
echo "【配置】踩过的坑不能再踩"
CFG="${P}/cordis.patch.yml"
if [ -f "$CFG" ]; then
    # provider 必须是 deepseek-official；deepseek 是悬空路由
    if grep -qE "^\s+provider: deepseek-official" "$CFG"; then
        check "agent-default-model.provider = deepseek-official" 1
    else
        prov=$(grep -E "^\s+provider:" "$CFG" | head -1 | sed 's/.*provider: *//')
        check "agent-default-model.provider = deepseek-official" 0 "实际: ${prov:-未配置}"
    fi

    # vision 不能写死 provider（旧版写 cpa，那个路由不存在）
    if grep -qE "^\s+provider: cpa" "$CFG"; then
        check "vision 没有写死不存在的 cpa 路由" 0 "cordis.patch.yml 里仍有 provider: cpa"
    else
        check "vision 没有写死不存在的 cpa 路由" 1
    fi

    # 已删除的插件不应再出现在配置里
    for dead in config-sync workspace-bootstrap model-fallback; do
        if grep -qE "id: ${dead}\s*$" "$CFG"; then
            check "已删除的插件 ${dead} 不在配置里" 0
        else
            check "已删除的插件 ${dead} 不在配置里" 1
        fi
    done
else
    check "cordis.patch.yml 存在" 0 "$CFG 不存在"
fi

# ── 4. 已删除的插件目录不应残留 ────────────────────────────────
echo
echo "【残留】挂载卷里删掉的插件必须真的没了"
for dead in config-sync workspace-bootstrap model-fallback; do
    if [ -d "${P}/plugins/${dead}" ]; then
        check "plugins/${dead} 已移除" 0 "目录仍存在"
    else
        check "plugins/${dead} 已移除" 1
    fi
done

# log-console 反过来：必须存在。缺了它，qqbot 的 ctx.logger 调用会被全部静默丢弃，
# 表现为「消息没反应但日志一片空白」，是最难查的一类故障。
if grep -qE "id: log-console\s*$" "$CFG" 2>/dev/null && [ -d "${P}/plugins/log-console" ]; then
    check "log-console 已挂载（插件日志可见）" 1
else
    check "log-console 已挂载（插件日志可见）" 0 "缺了它所有插件日志都会被静默丢弃"
fi

# ── 5. 运行时：进程与端口 ──────────────────────────────────────
echo
echo "【运行时】一个进程、两个能力"
# 启动命令是 dsh-launch（包装了 --expose-internals），所以匹配 bin.js 或 --profile
if pgrep -f "dsh.*--profile ${PROFILE}" >/dev/null 2>&1; then
    check "dsh 主进程在跑" 1
else
    check "dsh 主进程在跑" 0 "没找到 --profile ${PROFILE} 进程"
fi

# 关键：不能再有第二个 dsh 进程（旧架构的 qqbot 独立进程）
# pgrep -fc 在无匹配时可能给空/多行，统一归一化成整数
nproc_dsh=$(pgrep -fc "bin.js --profile" 2>/dev/null | head -1 | tr -dc '0-9' || true)
nproc_dsh="${nproc_dsh:-0}"
check "只有 1 个 dsh 宿主进程（实际 ${nproc_dsh}）" "$([ "$nproc_dsh" -le 1 ] && echo 1 || echo 0)"

if curl -s -o /dev/null -m 5 "http://127.0.0.1:${WEB_PORT:-8765}/" 2>/dev/null; then
    check "webServer 在监听（HTTP 有响应即健康，401 也算）" 1
else
    check "webServer 在监听" 0
fi

# ── 6. 端内绑定页 ──────────────────────────────────────────────
echo
echo "【绑定页】单进程才有这个路由"
bx=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT:-8765}/qqbot/im-qqbot/bind" 2>/dev/null || echo 000)
check "绑定页路由 /qqbot/im-qqbot/bind 可访问（$bx）" "$([ "$bx" = "200" ] && echo 1 || echo 0)"

echo
printf '%.0s═' {1..50}; echo
echo "通过 ${pass} / 失败 ${fail}"
if [ "$fail" -gt 0 ]; then
    echo
    echo "失败项意味着架构可能退化了。先看上面的「←」提示。"
    exit 1
fi
echo "全部通过"