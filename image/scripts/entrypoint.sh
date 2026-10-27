#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  DSH 容器统一入口
#
#  行为
#  ─────────────────────────────────────────────────────────────────
#  1. 渲染 profile 配置（仅首次启动，或 DSH_RENDER_FORCE=1）
#  2. 启动 dsh web（回环 8765）+ socat 转发（8766）
#  3. 启动 dsh --profile qqbot
#  4. 所有子进程输出实时打到容器日志，每行带 [web]/[qqbot]/[fwd] 前缀
#  5. 启动横幅打印 Web 地址（含 token）
#
#  QQ 扫码
#  ─────────────────────────────────────────────────────────────────
#  凭据缺失时腾讯插件会自动进入扫码引导：打印 ASCII 二维码 + 可点击链接，
#  过期自动刷新。全部走 console.log → 容器日志可见。
#      docker compose logs -f dsh
#  想重新扫码：docker compose exec dsh dsh-relogin
# ═══════════════════════════════════════════════════════════════════
set -Eeuo pipefail

# ── 参数 ──────────────────────────────────────────────────────────
: "${DSH_HOME:=/home/node/.dsh}"
: "${WORKSPACE:=/workspace}"
: "${WEB_PORT:=8765}"
: "${WEB_FWD_PORT:=8766}"
: "${QQ_PROFILE:=qqbot}"
: "${WEB_ENABLED:=1}"
: "${QQBOT_ENABLED:=1}"

export DSH_HOME WORKSPACE QQ_PROFILE

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

# 后台起进程：输出写日志文件，同时 tail -F 前缀化到容器 stdout
PIDS=()
CHECK_NAMES=()
declare -A PID_OF=()

spawn() {
    local name="$1"; shift
    local f="${LOG_DIR}/${name}.log"
    : > "$f"
    setsid "$@" >> "$f" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    CHECK_NAMES+=("$name")
    PID_OF["$name"]="$pid"
    # 实时把日志带前缀输出到容器日志；stdbuf 保证不缓冲（二维码不能被拆行）
    stdbuf -oL -eL tail -n +1 -F "$f" 2>/dev/null | stdbuf -oL sed -u "s/^/[${name}] /" &
    PIDS+=($!)
    log "started ${name} (pid=${pid})"
}

# ── 存活确认 ──────────────────────────────────────────────────────
#
# 为什么需要：子进程可能起来 4 秒就死（配置写坏、端口冲突、插件报错）。
# 如果这时已经打印「all services up」，用户会以为启动成功，实际在重启循环里。
# 所以「宣布成功」之前必须先确认各进程真的还活着。
HEALTH_WAIT="${DSH_HEALTH_WAIT:-8}"

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

# 把某个子服务的日志尾部提到容器 stdout —— 否则真正的错误只留在
# /tmp/dsh-logs/<name>.log 里，容器重启后 exec 进不去就拿不到。
dump_tail() {
    local name="$1" n="${2:-25}"
    local f="${LOG_DIR}/${name}.log"
    [ -f "$f" ] || return 0
    hr
    log "──── ${name} 日志尾部（最后 ${n} 行）────"
    tail -n "$n" "$f" | sed "s/^/  [${name}] /"
    hr
}

# ── 启动横幅 ──────────────────────────────────────────────────────
banner() {
    hr
    log "DSH container"
    log "  dsh      : $(dsh --version 2>/dev/null || echo 'NOT FOUND')"
    log "  node     : $(node --version 2>/dev/null || echo '-')"
    log "  python   : $(python3 --version 2>&1 | awk '{print $2}' || echo '-')"
    log "  DSH_HOME : ${DSH_HOME}"
    log "  profile  : ${QQ_PROFILE}"
    log "  web      : ${WEB_ENABLED}  (container :${WEB_PORT} -> host :${WEB_FWD_PORT})"
    log "  qqbot    : ${QQBOT_ENABLED}"
    hr
}

# ── 同步本地插件 ──────────────────────────────────────────────────
#
# 为什么需要：profile 目录是宿主机挂载卷（./data/profiles），镜像构建期
# COPY 进去的文件在运行期会被卷遮住 —— 插件代码永远拿不到。
# 所以每次启动时把镜像里的插件代码同步进 profile。
#
# 只同步代码文件（index.js / package.json），不碰别的一律不动：
# worldbook 目录里还有 worldbook.json 是用户数据，绝不能被镜像覆盖。
# 修二维码链接在容器日志里显示成乱码
#
# QQ 插件的 clickableLink() 无条件返回 OSC 8 超链接转义序列：
#   \e]8;;<url>\e\<url>\e]8;;\e\
# 在真终端里是可点击链接，但容器日志不是终端，转义码原样留下：
#   ]8;;https://...https://...]8;;
#
# 改成只有 stdout 是 TTY 时才输出超链接，否则给纯 URL。
# 文件属主是 1000:1000，运行期可以直接改，每次启动检查一次（幂等）。
patch_qr_link() {
    local f="${DSH_HOME}/profiles/${QQ_PROFILE}/node_modules/@tencent-connect/dsh-qqbot/dist/setup/presenters.js"
    [ -f "$f" ] || return 0
    grep -q 'isTTY ? ' "$f" && return 0

    python3 - "$f" <<'PY' || true
import sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    text = fh.read()
old = r"return `\u001b]8;;${url}\u001b\\${url}\u001b]8;;\u001b\\`;"
new = r"return process.stdout.isTTY ? `\u001b]8;;${url}\u001b\\${url}\u001b]8;;\u001b\\` : String(url);"
if old not in text:
    sys.exit(0)
with open(p, "w", encoding="utf-8") as fh:
    fh.write(text.replace(old, new, 1))
print("patched: clickableLink -> plain URL when not a TTY")
PY
}
# 已经废弃的内置插件：镜像里删掉了，但要清掉挂载目录里的旧副本。
#
# 为什么需要：data/profiles 是挂载目录，sync_local_plugins 只负责"拷新的"，
# 不会删旧的。插件改名或下线后，旧目录会一直留着，配置里没有它的条目，
# 但插件加载器仍会扫描到，日志里就一直出现残留的 plugin synced / 初始化输出。
RETIRED_PLUGINS="model-sync model-fallback workspace-bootstrap"

sync_local_plugins() {
    local src="/opt/dsh/image/plugins"
    local dst="${DSH_HOME}/profiles/${QQ_PROFILE}/plugins"
    [ -d "$src" ] || return 0
    mkdir -p "$dst"

    # 先清掉废弃插件（只按名单删，避免误删用户自己放进去的）
    local retired
    for retired in $RETIRED_PLUGINS; do
        if [ -d "$dst/$retired" ]; then
            rm -rf "$dst/$retired"
            log "plugin removed (retired): ${retired}"
        fi
    done

    local dir name
    for dir in "$src"/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        mkdir -p "$dst/$name"
        local f
        for f in index.js package.json; do
            if [ -f "$dir$f" ]; then
                cp -f "$dir$f" "$dst/$name/$f"
            fi
        done
        log "plugin synced: ${name}"
    done
}

# ── 启动前准备 ────────────────────────────────────────────────────
# 给 Web profile 预置一个内置服务商（DeepSeek）
#
# Web 的模型设置页列出的是「已配置的服务商」。web profile 是 DSH 首次启动
# 时自动生成的，只有一行 ui-settings-general —— 没有任何 provider 配置，
# 于是打开模型页什么服务商都看不到。
#
# 这里补一条 deepseek：用户打开 Web 就能看到 DeepSeek 卡片，直接填 API key
# 就能用（baseUrl 和模型列表都在 pi-ai 内置目录里，不用写）。
#
# 只加一次：已经有 llm-pi-ai 配置就跳过，用户自己改过的不会被覆盖。
# 写完后 dsh-hmr 会热重载，不需要重启容器。
configure_web_profile() {
    local f="${DSH_HOME}/profiles/web/cordis.patch.yml"
    local i=0
    # web profile 由 dsh web 首次启动时创建，等它出现
    while [ $i -lt 30 ]; do
        [ -f "$f" ] && break
        sleep 1
        i=$((i+1))
    done
    [ -f "$f" ] || return 0
    if grep -q "llm-pi-ai" "$f" 2>/dev/null; then
        return 0
    fi

    # 空 profile 的文件内容就是一行 `[]`（空的 YAML 数组）。
    # 直接往后追加 `- id:` 会变成 [] 后面跟块序列 —— YAML 非法，启动报
    #   YAMLException: end of the stream or a document separator is expected
    # 所以先把这行删掉，再追加条目。
    if grep -qx '\[\]' "$f" 2>/dev/null; then
        sed -i '/^\[\]$/d' "$f"
    fi

    cat >> "$f" <<'EOF'

# ── 内置服务商：DeepSeek 官方 ──
# baseUrl / 模型列表 / 上下文窗口都在 pi-ai 内置目录里，这里只声明用哪个
# 服务商、key 存哪个名字。用户在 Web 模型页填 key 即可使用。
- id: llm-pi-ai
  name: '@deepseek-ai/dsh-llm-pi-ai'
  config:
    providers:
      deepseek:
        displayName: DeepSeek
        apiKeyEnv: DEEPSEEK_API_KEY
EOF
    log "已为 Web profile 预置 DeepSeek 服务商"
}
# 安装用户级全局指令（给 AI 的环境说明）
#
# DSH 的 agent-instructions 插件会读 $DSH_HOME/AGENTS.md 作为「用户级全局
# 指令」，注入到每一个会话里。用它告诉 AI：当前是容器环境、哪些文件不要动。
#
# $DSH_HOME 不挂载，所以每次启动都要重新铺（幂等：内容一致就不动）。
#
# 用户想加自己的全局约束，改这个文件会被覆盖 —— 应该放到
# /workspace/AGENTS.md（工作区级，会叠加而不是替换）。
install_agents_md() {
    local src="/opt/dsh/image/instructions/AGENTS.md"
    local dst="${DSH_HOME}/AGENTS.md"
    [ -f "$src" ] || return 0

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi

    cp "$src" "$dst"
    log "已安装环境说明：${dst}"
}
# 首次启动时把镜像里的 profile 骨架铺到挂载目录
#
# 为什么需要：data/profiles 是宿主机 bind mount，会遮住镜像里的
# $DSH_HOME/profiles/qqbot。别人拿到镜像后 data 是空的，profile 就不存在，
# qqbot 直接起不来：
#   Error: dsh: profile "qqbot" does not exist
#
# 骨架里带着 package.json / cordis.yml / node_modules / patches / pnpm 配置，
# 是构建期装好插件之后的完整状态，所以运行期不需要联网装包。
bootstrap_profile() {
    local p="${DSH_HOME}/profiles/${QQ_PROFILE}"
    local skeleton="/opt/dsh/image/skeleton/qqbot"

    if [ -f "${p}/package.json" ]; then
        return 0
    fi

    if [ ! -d "$skeleton" ]; then
        log "ERROR: profile '${QQ_PROFILE}' 不存在，且镜像里没有骨架 ${skeleton}"
        return 1
    fi

    log "首次启动：从镜像骨架初始化 profile '${QQ_PROFILE}'"
    mkdir -p "$p"
    # -a 保留符号链接与权限；node_modules 里的 .bin 依赖它
    cp -a "${skeleton}/." "$p/"
    chown -R "$(id -u):$(id -g)" "$p" 2>/dev/null || true
    log "profile 初始化完成：$(du -sh "$p" 2>/dev/null | cut -f1)"
}

prepare() {
    mkdir -p "${DSH_HOME}/profiles" "${DSH_HOME}/storages" \
             "${DSH_HOME}/sessions" "${DSH_HOME}/proactive" \
             "${DSH_HOME}/logs" "${DSH_HOME}/attachments/v1"
    # attachment-local 要求 DSH_HOME 及其下目录能 chmod 到 700
    chmod 700 "${DSH_HOME}" "${DSH_HOME}/attachments/v1" 2>/dev/null || true

    bootstrap_profile || return 1

    sync_local_plugins
    patch_qr_link
    install_agents_md

    if [ "${DSH_RENDER_FORCE:-0}" = "1" ]; then
        bash /opt/dsh/image/scripts/render-profile.sh --force
    else
        bash /opt/dsh/image/scripts/render-profile.sh
    fi
}

# ── Web UI ────────────────────────────────────────────────────────
start_web() {
    [ "${WEB_ENABLED}" = "1" ] || { log "web disabled"; return 0; }
    # --public-url 让 dsh web 自己打印对外的地址（8766），而不是它自己监听的
    # 内部端口（8765）。这样日志里根本不会出现 8765，不用再改写/解释。
    # 它同时会影响 DSH_WEB_URL 环境变量，AI 拿到的也是正确地址。
    spawn web dsh web --port "${WEB_PORT}" \
        --public-url "http://127.0.0.1:${WEB_FWD_PORT}" --no-open

    # 从日志里抓带 token 的 URL（最多等 60 秒）
    local url="" i=0
    while [ $i -lt 60 ]; do
        url=$(grep -aoE "http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+" \
                "${LOG_DIR}/web.log" 2>/dev/null | head -1 || true)
        [ -n "$url" ] && break
        sleep 1; i=$((i+1))
    done

    if [ -n "$url" ]; then
        local host_url
        host_url=$(echo "$url" | sed -E "s#127\.0\.0\.1:[0-9]+#127.0.0.1:${WEB_FWD_PORT}#")
        # 缓存到文件，方便 `docker compose exec dsh dsh-url` 读取
        printf '%s\n' "$host_url" > "${DSH_HOME}/web-url.txt"
        hr
        log "WEB UI READY"
        log "  ${host_url}"
        hr
    else
        log "WARN: web URL not detected within 60s (see [web] logs above)"
    fi
}

start_forward() {
    [ "${WEB_ENABLED}" = "1" ] || return 0
    log "socat forwarding :${WEB_FWD_PORT} -> 127.0.0.1:${WEB_PORT}"
    spawn fwd socat "TCP-LISTEN:${WEB_FWD_PORT},fork,reuseaddr" "TCP:127.0.0.1:${WEB_PORT}"
}

# ── QQ Bot ────────────────────────────────────────────────────────
start_qqbot() {
    [ "${QQBOT_ENABLED}" = "1" ] || { log "qqbot disabled"; return 0; }
    if [ ! -f "${DSH_HOME}/profiles/${QQ_PROFILE}/cordis.patch.yml" ]; then
        log "WARN: profile '${QQ_PROFILE}' not initialised; skipping qqbot"
        return 0
    fi
    log "launching qqbot (profile=${QQ_PROFILE})"
    if [ -z "${QQBOT_APPID:-}" ]; then
        hr
        log "QQ 凭据未配置 —— 即将打印扫码二维码"
        log "  用手机 QQ 扫码即可绑定；二维码过期会自动刷新"
        log "  也可以设置 QQBOT_APPID / QQBOT_SECRET 跳过扫码"
        hr
    fi
    spawn qqbot dsh --profile "${QQ_PROFILE}"
}

# ── main ──────────────────────────────────────────────────────────
banner
prepare
cd "${WORKSPACE}"

# 启动顺序很重要：qqbot 先起，让 workspace-bootstrap 把工作区写进
# data/storages/workspace.json，之后 web 启动时读到的才不是空表。
#
# 之前是 web 先起，结果 web 进程内存里的 workspaceRegistry 一直是空的，
# 打开界面显示「无工作区」——要等用户手动刷新才可能好。
# 等 qqbot 把默认工作区写进注册表，再启动 web
#
# web 进程启动时会把 workspace.json 读进内存，之后不再重读。如果那一刻
# 文件里还没有 defaultWorkspaceId，界面就会报「无法创建默认工作区」——
# 因为 initializeDefault 看到 workspaceIds 非空就放弃了。
#
# 实测 qqbot 加载完插件再执行 workspace-bootstrap 要 10~15 秒。
wait_default_workspace() {
    local f="${DSH_HOME}/storages/workspace.json"
    local i=0
    while [ $i -lt 30 ]; do
        if [ -f "$f" ] && grep -q '"defaultWorkspaceId"' "$f" 2>/dev/null; then
            log "默认工作区已就绪，启动 web"
            return 0
        fi
        sleep 1
        i=$((i+1))
    done
    log "WARN: 30 秒内没等到默认工作区（web 仍会启动）"
    return 0
}

start_qqbot
wait_default_workspace
start_web
configure_web_profile
# socat 必须在 web 之后：web 没监听 8765 时转发会打一条
#   socat E connect(5, AF=2 127.0.0.1:8765): Connection refused
# 虽然会自动重连，但日志里留个 ERROR 很误导。
start_forward

# 宣布成功之前先确认进程真活着。
# 坏配置的典型表现：打印完 all services up，4 秒后 qqbot 退出并重启循环。
hr
log "verifying services are alive (${HEALTH_WAIT}s)..."
if ! verify_alive; then
    hr
    log "✗ 启动失败：有服务在 ${HEALTH_WAIT}s 内退出"
    log "  常见原因："
    log "    - profile 配置 YAML 语法错误（检查 data/profiles/${QQ_PROFILE}/cordis.patch.yml）"
    log "    - 端口被占用"
    log "    - 插件缺少依赖服务"
    log "  上面的日志尾部就是真实原因，修好后 docker compose restart dsh"
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
# 为什么不直接用 wait -n：
#   原来用 wait -n，任何子进程退出都会让容器退出。但 qqbot 崩了不该拖垮
#   web 和 socat，而且容器内想重启 qqbot（改配置、切模型）时会连带容器退出。
#
# 现在：只监控 qqbot。它退出就自动拉起（带退避），web/socat 崩了才让容器退出。
#
# 冷却期（DSH_COOLDOWN）：qqbot 短时间内反复退出时，等一会儿再拉，避免
#   疯狂重启刷爆日志。默认 5 秒，指数递增到 60 秒上限。
COOLDOWN="${DSH_COOLDOWN:-5}"
cooldown="$COOLDOWN"

set +e
while true; do
    pid="${PID_OF[qqbot]:-}"
    if [ -z "$pid" ]; then
        # 还没启动过（QQBOT_ENABLED=0）——直接退出监控
        log "qqbot not started; monitor exiting"
        exit 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null
        CODE=$?
        log "qqbot exited (code=${CODE}); restarting in ${cooldown}s"
        dump_tail qqbot 30
        sleep "$cooldown"
        # 退避：5 → 10 → 20 → 40 → 60（封顶）
        cooldown=$(( cooldown * 2 ))
        [ "$cooldown" -gt 60 ] && cooldown=60
        spawn qqbot dsh --profile "${QQ_PROFILE}"
        cooldown_reset="$COOLDOWN"
        continue
    fi

    # qqbot 活着；同时确认 web/fwd 没死
    for name in web fwd; do
        p="${PID_OF[$name]:-}"
        [ -z "$p" ] && continue
        if ! kill -0 "$p" 2>/dev/null; then
            log "critical service '${name}' exited; container will stop"
            dump_tail "$name" 30
            exit 1
        fi
    done

    sleep 5
done
