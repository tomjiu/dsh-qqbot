#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  check.sh —— 改完东西后跑这一个，别靠人记得
#
#  为什么需要：
#    这个仓库里出过好几次「改了 A，忘了同步 B」：
#      - 删了 log-console，以为是单进程不需要 → 日志全静默，排查瘫痪
#      - 删了 vision.provider/model，以为能继承 → 读图功能静默消失
#      - 新增插件，忘了加进 dsh-verify 的白名单 → 自检假失败
#    这些都不会让构建报错，只会在运行时悄悄退化。
#
#  用法：
#    ./check.sh             完整检查（构建 + 起临时容器 + 自检）
#    ./check.sh --no-build  跳过镜像构建（改文档时用）
#    ./check.sh --fast      只做静态检查，不碰 Docker
# ═══════════════════════════════════════════════════════════════════
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MODE="full"
case "${1:-}" in
  --no-build) MODE="nobuild" ;;
  --fast)     MODE="fast" ;;
esac

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s%s\n' "$1" "${2:+  ← $2}"; }
head() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── 静态检查 ─────────────────────────────────────────────────────
head "【静态】脚本语法"
for f in image/scripts/*.sh; do
    if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f")" "语法错误"; fi
done

head "【静态】JS 语法"
while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    if node --check "$f" 2>/dev/null; then ok "$rel"; else bad "$rel" "语法错误"; fi
done < <(find image/plugins -name "*.js" -not -path "*/node_modules/*")

head "【静态】模板 YAML 合法性"
if node image/scripts/validate-template.mjs image/profiles/qqbot.cordis.patch.yml.template >/dev/null 2>&1; then
    ok "qqbot.cordis.patch.yml.template"
else
    bad "模板 YAML 解析失败"
    node image/scripts/validate-template.mjs image/profiles/qqbot.cordis.patch.yml.template 2>&1 | head -3 || true
fi

head "【静态】关键内容不许丢失"
# log-console：没有它所有插件日志会被静默丢弃
if grep -q "id: log-console" image/profiles/qqbot.cordis.patch.yml.template && [ -f image/plugins/log-console/index.js ]; then
    ok "log-console 在位"
else
    bad "log-console 丢了" "日志会全部静默，排查瘫痪"
fi

# vision 必须有 provider + model（缺一个就不注册工具）
if grep -qE "^\\s+provider: deepseek-official" image/profiles/qqbot.cordis.patch.yml.template \
   && grep -qE "^\\s+model: deepseek-flash" image/profiles/qqbot.cordis.patch.yml.template; then
    ok "vision.provider/model 已配置"
else
    bad "vision.provider/model 缺失" "读图工具不会注册"
fi

# persist.js 补丁必须在：它把「写 profile 配置」改成「写独立文件 + 返回 false」，
# 插件随即直接启动网关 —— 这是扫码后零重启的关键。
if grep -q "dist/setup/persist.js" image/patch/*.patch 2>/dev/null; then
    ok "persist.js 补丁在位（扫码零重启）"
else
    bad "persist.js 补丁缺失" "扫码后会卡在 saving，必须重启才可用"
fi

# HMR 必须开 usePolling：Docker Desktop 的 bind mount 不传 inotify 事件，
# 默认后端一个事件都收不到 —— 配置热重载会静默失效。
if grep -q "usePolling: true" image/profiles/qqbot.cordis.patch.yml.template; then
    ok "HMR 开了 usePolling（bind mount 必需）"
else
    bad "HMR 没开 usePolling" "Docker Desktop 上配置永远不会热重载"
fi

# 子智能体模型选择必须是动态 enabled
if grep -q "enabled: \${DSH_SUBAGENT_ENABLED}" image/profiles/qqbot.cordis.patch.yml.template; then
    ok "subagent modelSelection 用动态 enabled"
else
    bad "subagent modelSelection 硬编码" "空白名单会导致建会话失败"
fi

# dsh-launch 必须在（HMR 依赖 --expose-internals）
if [ -f image/scripts/dsh-launch.sh ] && grep -q "expose-internals" image/scripts/dsh-launch.sh; then
    ok "dsh-launch 带 --expose-internals"
else
    bad "dsh-launch 缺失或没带 --expose-internals" "HMR 不会工作"
fi

head "【静态】危险写法"
if grep -rn "yaml.dump" image/plugins/ 2>/dev/null | grep -q .; then
    bad "有插件在整体重写 cordis.patch.yml" "会抹掉注释与 insert 条目"
else
    ok "没有插件整体重写 cordis.patch.yml"
fi

if [ "$MODE" = "fast" ]; then
    printf '\n%s\n' "$(printf '%.0s─' {1..50})"
    printf "通过 %d / 失败 %d  （fast 模式）\n" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# ── 构建 ─────────────────────────────────────────────────────────
if [ "$MODE" = "full" ]; then
    head "【构建】镜像"
    if docker compose build 2>&1 | tail -3 | grep -q "Built"; then
        ok "镜像构建成功（含 patch verified + composition verified）"
    else
        bad "镜像构建失败"
        exit 1
    fi
fi

# ── 运行时：全新环境自检 ─────────────────────────────────────────
head "【运行时】全新环境自检"
TMP="$(mktemp -d)"
NAME="dsh-check-$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP"/{workspace,data/{profiles,storages,sessions,proactive,trusted-workspaces,qqbot-prefs}}
: > "$TMP/data/credentials.yaml"
echo "{}" > "$TMP/data/qqbot-credentials.json"

if docker run -d --name "$NAME" -p 127.0.0.1:0:8766 \
    -v "$TMP/workspace:/workspace" \
    -v "$TMP/data/profiles:/home/node/.dsh/profiles" \
    -v "$TMP/data/storages:/home/node/.dsh/storages" \
    -v "$TMP/data/sessions:/home/node/.dsh/sessions" \
    -v "$TMP/data/proactive:/home/node/.dsh/proactive" \
    -v "$TMP/data/trusted-workspaces:/home/node/.dsh/trusted-workspaces" \
    -v "$TMP/data/qqbot-prefs:/home/node/.dsh-qqbot" \
    -v "$TMP/data/credentials.yaml:/opt/dsh/state/credentials.yaml" \
    -v "$TMP/data/qqbot-credentials.json:/opt/dsh/state/qqbot-credentials.json" \
    dsh-qqbot:latest >/dev/null 2>&1; then
    ok "容器启动"
else
    bad "容器启动失败"
    docker logs "$NAME" 2>&1 | tail -20
    exit 1
fi

ready=0
for _ in $(seq 1 45); do
    if docker exec "$NAME" bash -lc "test -s /home/node/.dsh/web-url.txt" 2>/dev/null; then ready=1; break; fi
    sleep 2
done
if [ "$ready" = "1" ]; then
    ok "Web UI 就绪"
else
    bad "Web UI 90 秒内没就绪"
    docker logs "$NAME" 2>&1 | tail -30
    exit 1
fi

if docker exec "$NAME" dsh-verify > /tmp/dsh-check-verify.log 2>&1; then
    ok "dsh-verify 全部通过"
else
    bad "dsh-verify 有失败项"
    grep "✗" /tmp/dsh-check-verify.log || true
fi

warns=$(docker exec "$NAME" bash -lc "grep -aiE \"warn:|error:\" /tmp/dsh-logs/main.log | grep -v ExperimentalWarning | wc -l" 2>/dev/null || echo 99)
if [ "$warns" = "0" ]; then
    ok "启动日志零 warn/error"
else
    bad "启动日志有 $warns 条 warn/error" "每条通常意味着一个功能没注册"
fi

printf '\n%s\n' "$(printf '%.0s─' {1..50})"
printf "通过 %d / 失败 %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf "\n有 %d 项失败 —— 别提交。\n" "$FAIL"
    exit 1
fi
printf "全部通过，可以提交。\n"