#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  DSH 容器统一入口（单一宿主）
#
#  一个进程同时提供：
#    - Web UI            http://127.0.0.1:8766（socat 转发自容器内 8765）
#    - QQ 机器人         同一个 dsh web 宿主里的 im-qqbot 插件
#
#  为什么只有一个进程：
#    旧版是「dsh web」+「dsh --profile qqbot」两个独立 dsh 宿主共用
#    一份 DSH_HOME。会话活在一个进程的内存里，另一个进程只能从磁盘
#    读到 header —— 于是工作区归不上、Web 模型选择器读不到 QQ 会话、
#    两端同写抢锁、QQ 插件的 webServer 注入永远不满足（端内绑定页
#    因此完全不出现，只能看终端 ASCII 二维码）。
#    合并后这些全部由上游自己解决，不需要任何兼容层。
#
#  QQ 扫码：
#    凭据缺失时插件进入未绑定态，端内绑定页在 Web 侧栏
#    （路由 /qqbot/im-qqbot/bind），扫完立即生效，不重启容器。
#    entrypoint 同时把终端二维码留在日志里作为降级通道。
# ═══════════════════════════════════════════════════════════════════
set -Eeuo pipefail

: "${DSH_HOME:=/home/node/.dsh}"
: "${WORKSPACE:=/workspace}"
: "${WEB_PORT:=8765}"
: "${WEB_FWD_PORT:=8766}"
: "${MAIN_PROFILE:=main}"

export DSH_HOME WORKSPACE MAIN_PROFILE

LOG_DIR=/tmp/dsh-logs
mkdir -p "$LOG_DIR"

# ── 输出 ──────────────────────────────────────────────────────────
ts() { date '+%H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
hr()  { printf '%.0s─' {1..70}; printf '\n'; }

# ── 子进程管理 ────────────────────────────────────────────────────
PIDS=()
cleanup() {
    local code=$?
    log "stopping services..."
    for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
    sleep 2
    for pid in "${PIDS[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
    log "exit (code=${code})"
}
trap cleanup EXIT INT TERM

declare -A PID_OF=()
CHECK_NAMES=()

spawn() {
    local name="$1"; shift
    local f="${LOG_DIR}/${name}.log"
    : > "$f"
    setsid "$@" >> "$f" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    CHECK_NAMES+=("$name")
    PID_OF["$name"]="$pid"
    stdbuf -oL -eL tail -n +1 -F "$f" 2>/dev/null | stdbuf -oL sed -u "s/^/[${name}] /" &
    PIDS+=($!)
    log "started ${name} (pid=${pid})"
}

# ── 存活确认 ──────────────────────────────────────────────────────
HEALTH_WAIT="${DSH_HEALTH_WAIT:-8}"

dump_tail() {
    local name="$1" n="${2:-25}"
    local f="${LOG_DIR}/${name}.log"
    [ -f "$f" ] || return 0
    hr
    log "──── ${name} 日志尾部（最后 ${n} 行）────"
    tail -n "$n" "$f" | sed "s/^/  [${name}] /"
    hr
}

verify_alive() {
    local failed=0 name pid
    sleep "${HEALTH_WAIT}"
    for name in "${CHECK_NAMES[@]:-}"; do
        pid="${PID_OF[$name]:-}"
        [ -z "$pid" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            log "  ✓ ${name} alive (pid=${pid})"
        else
            failed=$((failed+1))
            log "  ✗ ${name} DIED (pid=${pid})"
            dump_tail "$name"
        fi
    done
    return "$failed"
}

# ── 启动横幅 ──────────────────────────────────────────────────────
banner() {
    hr
    log "DSH container (single host: web + qqbot)"
    log "  dsh      : $(dsh --version 2>/dev/null || echo 'NOT FOUND')"
    log "  node     : $(node --version 2>/dev/null || echo '-')"
    log "  python   : $(python3 --version 2>&1 | awk '{print $2}' || echo '-')"
    log "  DSH_HOME : ${DSH_HOME}"
    log "  profile  : ${MAIN_PROFILE}"
    log "  web      : (container :${WEB_PORT} -> host :${WEB_FWD_PORT})"
    hr
}

# ── 准备 ──────────────────────────────────────────────────────────

# QQ 凭据的三级来源（优先级从高到低）：
#
#   1. .env 里的 QQBOT_APPID / QQBOT_SECRET      ← 用户手填，最高优先
#   2. /opt/dsh/state/qqbot-credentials.json     ← 扫码产出，由 persist.js 补丁写入
#   3. cordis.patch.yml 里的 im-qqbot.config      ← 正常应为空字符串
#
# 为什么扫码结果要走独立文件、而不是留在 cordis.patch.yml 里：
#   上游 setup/persist.js 用 yaml.dump() 整体覆盖那个文件，会毁掉模板。
#   凭据搬出去之后，cordis.patch.yml 可以永远保持模板原样。
#
# 这里把独立文件里的凭据**注入成环境变量**，因为插件的解析顺序是
#   resolveEnv(config.appId, 'QQBOT_APPID')
# —— config 优先、env 兜底。模板里是 ''（空串，会被当成"没配"），
# 所以实际生效的是我们在这里注入的 env 值。
QQBOT_CRED_FILE="/opt/dsh/state/qqbot-credentials.json"

load_qqbot_credentials() {
    # .env 已经给了就不用读文件，用户的显式配置优先
    if [ -n "${QQBOT_APPID:-}" ] && [ -n "${QQBOT_SECRET:-}" ]; then
        log "QQ 凭据来源：.env"
        return 0
    fi

    [ -f "$QQBOT_CRED_FILE" ] || return 0

    local id secret
    # 用 python3 解析 JSON：比 grep 稳，且凭据里可能有引号
    id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("appId",""))' "$QQBOT_CRED_FILE" 2>/dev/null || true)"
    secret="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("appSecret",""))' "$QQBOT_CRED_FILE" 2>/dev/null || true)"

    if [ -n "$id" ] && [ -n "$secret" ]; then
        export QQBOT_APPID="$id"
        export QQBOT_SECRET="$secret"
        log "QQ 凭据来源：扫码保存的 ${QQBOT_CRED_FILE}"
    fi
}

sync_local_plugins() {
    local src="/opt/dsh/image/plugins"
    local dst="${DSH_HOME}/profiles/${MAIN_PROFILE}/plugins"
    [ -d "$src" ] || return 0
    mkdir -p "$dst"

    # 已删除的自写插件：镜像里没有了，但挂载目录里会留着旧副本。
    # 配置里已经没有它们的条目，不删会一直被加载器扫到。
    local retired="config-sync workspace-bootstrap model-sync model-fallback"
    local r
    for r in $retired; do
        if [ -d "$dst/$r" ]; then
            rm -rf "$dst/$r"
            log "plugin removed (retired): ${r}"
        fi
    done

    local dir name f
    for dir in "$src"/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        mkdir -p "$dst/$name"
        for f in index.js package.json; do
            [ -f "$dir$f" ] && cp -f "$dir$f" "$dst/$name/$f"
        done
    done
}

# QQ 插件的 OSC 8 超链接：容器日志不是终端，转义码会原样留下变成乱码。
# 改成只有 stdout 是 TTY 时才输出超链接，否则给纯 URL。幂等。
# QQ 插件的 OSC 8 超链接：容器日志不是终端，转义序列会原样留下变成乱码
#   ^[]8;;https://...^[\https://...^[]8;;^[\
# 改成只有 stdout 是 TTY 时才输出超链接，否则给纯 URL。幂等。
#
# ⚠️ 不要用字符串字面量匹配源码：源文件里写的是 \u001b 转义，
#    而运行时是两个真实字节 ESC / 反斜杠。用正则按结构匹配才可靠。
# QQ 插件的 OSC 8 超链接：容器日志不是终端，转义序列会原样留下变成乱码
#   ^[]8;;https://...^[\https://...^[]8;;^[\
# 交给独立脚本处理（带正则匹配），幂等。
patch_qr_link() {
    local f="${DSH_HOME}/profiles/${MAIN_PROFILE}/node_modules/@tencent-connect/dsh-qqbot/dist/setup/presenters.js"
    [ -f "$f" ] || return 0
    grep -q 'isTTY' "$f" && return 0
    python3 /opt/dsh/image/scripts/patch-qr-link.py "$f" || true
}

install_agents_md() {
    local src="/opt/dsh/image/instructions/AGENTS.md"
    local dst="${DSH_HOME}/AGENTS.md"
    [ -f "$src" ] || return 0
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    cp "$src" "$dst"
    log "已安装环境说明：${dst}"
}

# 首次启动时把镜像里的 profile 骨架铺到挂载目录。
# data/profiles 是宿主机 bind mount，会遮住镜像里的 profile；
# 没有这一步，别人的 data 是空的，启动直接报 profile 不存在。
bootstrap_profile() {
    local p="${DSH_HOME}/profiles/${MAIN_PROFILE}"
    local skeleton="/opt/dsh/image/skeleton/main"

    if [ -f "${p}/package.json" ]; then
        return 0
    fi

    if [ ! -d "$skeleton" ]; then
        log "ERROR: profile '${MAIN_PROFILE}' 不存在，且镜像里没有骨架 ${skeleton}"
        return 1
    fi

    log "首次启动：从镜像骨架初始化 profile '${MAIN_PROFILE}'"
    mkdir -p "$p"
    cp -a "${skeleton}/." "$p/"
    chown -R "$(id -u):$(id -g)" "$p" 2>/dev/null || true
    log "profile 初始化完成：$(du -sh "$p" 2>/dev/null | cut -f1)"
}

# 凭据文件：宿主机 <-> 容器 双向同步
#
# 不能直接挂 ~/.dsh/.credentials.yaml：DSH 要求该文件权限严格 600，
# 而 Windows 的 9p 挂载改不了权限（恒 777），credentials-local 会拒绝启动。
# 所以宿主那份放在别的路径，这里复制进来并 chmod 600，再回写。
CRED_HOST="/opt/dsh/state/credentials.yaml"
CRED_LOCAL="${DSH_HOME}/.credentials.yaml"

sync_credentials_in() {
    [ -f "$CRED_HOST" ] || return 0
    if grep -q "^refs: {}" "$CRED_HOST" 2>/dev/null && [ -f "$CRED_LOCAL" ] && ! grep -q "^refs: {}" "$CRED_LOCAL" 2>/dev/null; then
        return 0
    fi
    cp -f "$CRED_HOST" "$CRED_LOCAL"
    chmod 600 "$CRED_LOCAL" 2>/dev/null || true
}

sync_credentials_out() {
    [ -f "$CRED_LOCAL" ] || return 0
    [ -f "$CRED_HOST" ] || return 0
    if ! cmp -s "$CRED_LOCAL" "$CRED_HOST"; then
        cp -f "$CRED_LOCAL" "$CRED_HOST"
        log "凭据已同步回宿主机"
    fi
}

prepare() {
    mkdir -p "${DSH_HOME}/profiles" "${DSH_HOME}/storages" \
             "${DSH_HOME}/sessions" "${DSH_HOME}/proactive" \
             "${DSH_HOME}/logs" "${DSH_HOME}/attachments/v1"
    # attachment-local 要求 DSH_HOME 及其下目录能 chmod 到 700
    chmod 700 "${DSH_HOME}" "${DSH_HOME}/attachments/v1" 2>/dev/null || true

    bootstrap_profile || return 1
    load_qqbot_credentials
    sync_local_plugins
    patch_qr_link
    install_agents_md
    sync_credentials_in

    if [ "${DSH_RENDER_FORCE:-0}" = "1" ]; then
        bash /opt/dsh/image/scripts/render-profile.sh --force
    else
        bash /opt/dsh/image/scripts/render-profile.sh
    fi
}

# ── Web + QQ（同一个宿主）───────────────────────────────────────
#
# --public-url 让 dsh web 打印对外地址（8766），而不是它自己监听的 8765。
start_main() {
    # 用 dsh-launch 而不是 dsh：它会给 node 带上 --expose-internals，
    # 没有它 HMR 服务起不来，配置改动（含扫码写回凭据）永远不会热生效。
    spawn main dsh-launch --profile "${MAIN_PROFILE}" \
        --port "${WEB_PORT}" \
        --public-url "http://127.0.0.1:${WEB_FWD_PORT}" --no-open

    local url="" i=0
    while [ $i -lt 90 ]; do
        url=$(grep -aoE "http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+" \
                "${LOG_DIR}/main.log" 2>/dev/null | head -1 || true)
        [ -n "$url" ] && break
        sleep 1; i=$((i+1))
    done

    if [ -n "$url" ]; then
        local host_url
        host_url=$(echo "$url" | sed -E "s#127\.0\.0\.1:[0-9]+#127.0.0.1:${WEB_FWD_PORT}#")
        printf '%s\n' "$host_url" > "${DSH_HOME}/web-url.txt"
        hr
        log "WEB UI READY"
        log "  ${host_url}"
        hr
    else
        log "WARN: web URL not detected within 90s (see [main] logs above)"
    fi
}

start_forward() {
    log "socat forwarding :${WEB_FWD_PORT} -> 127.0.0.1:${WEB_PORT}"
    spawn fwd socat "TCP-LISTEN:${WEB_FWD_PORT},fork,reuseaddr" "TCP:127.0.0.1:${WEB_PORT}"
}

# ── main ──────────────────────────────────────────────────────────
banner
prepare
cd "${WORKSPACE}"

if [ -z "${QQBOT_APPID:-}" ]; then
    hr
    log "QQ 凭据未配置 —— 机器人将以未绑定态启动"
    log "  方式一（推荐）：打开 Web UI → 侧栏「QQ Bot 绑定」扫码，扫完即生效"
    log "  方式二：在 .env 填 QQBOT_APPID / QQBOT_SECRET"
    log "  终端二维码也会打印在下面的日志里"
    hr
fi

start_main
# socat 必须在 web 之后：web 没监听时转发会打一条 Connection refused
start_forward

hr
log "verifying services are alive (${HEALTH_WAIT}s)..."
if ! verify_alive; then
    hr
    log "✗ 启动失败：有服务在 ${HEALTH_WAIT}s 内退出"
    log "  常见原因："
    log "    - profile 配置 YAML 语法错误（检查 data/profiles/${MAIN_PROFILE}/cordis.patch.yml）"
    log "    - 端口被占用"
    log "    - 插件缺少依赖服务"
    log "  上面的日志尾部就是真实原因"
    hr
    exit 1
fi

hr
log "all services up (verified)"
log "  logs : docker compose logs -f dsh"
log "  shell: docker compose exec dsh bash"
hr

# ── 监控循环 ──────────────────────────────────────────────────────
#
# web 挂掉 = 容器没有意义，直接退出交给 compose 的 restart 策略。
# 不再单独监控 qqbot：它已经不是一个独立进程，随宿主一起活/死。
COOLDOWN="${DSH_COOLDOWN:-5}"
cooldown="$COOLDOWN"

set +e
while true; do
    for name in main fwd; do
        p="${PID_OF[$name]:-}"
        [ -z "$p" ] && continue
        if ! kill -0 "$p" 2>/dev/null; then
            log "critical service '${name}' exited; container will stop"
            dump_tail "$name" 40
            exit 1
        fi
    done

    sync_credentials_out
    sleep 5
done