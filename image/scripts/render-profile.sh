#!/usr/bin/env bash
# 渲染 qqbot profile 配置
#
# 从镜像内模板生成实际配置文件。只在以下情况生成：
#   - 目标文件不存在（首次启动）
#   - 显式传 --force（升级模板后重新渲染）
#
# 这样用户手工改过的配置不会被每次启动覆盖。
#
# 变量约定：
#   模板里 ${NAME}          → 普通字符串替换
#   模板里 ${NAME_YAML}     → 该行整行被「逗号分隔列表」渲染出的 YAML 列表项替换
#                             如 DSH_GROUP_ALLOW="a,b" → "        - 'a'\n        - 'b'"
#
# 为什么不用 envsubst 统一处理：
#   envsubst 无法把一个变量展开成多行缩进的 YAML 列表，只能靠逐行判断替换。
set -Eeuo pipefail

DSH_HOME="${DSH_HOME:-/home/node/.dsh}"
PROFILE="${QQ_PROFILE:-qqbot}"
TPL="/opt/dsh/image/profiles/qqbot.cordis.patch.yml.template"
TARGET="${DSH_HOME}/profiles/${PROFILE}/cordis.patch.yml"
FORCE="${1:-}"

mkdir -p "${DSH_HOME}/profiles/${PROFILE}"

if [ -f "$TARGET" ] && [ "$FORCE" != "--force" ]; then
    echo "config exists, skip render: $TARGET"
    exit 0
fi

if [ ! -f "$TPL" ]; then
    echo "ERROR: template not found: $TPL" >&2
    exit 1
fi

# ── 把逗号分隔的 id 列表渲染成 YAML 列表项 ──────────────────────
# $1 = 原始值；$2 = 缩进空格数；$3 = 空列表时的占位（可为空表示输出空字符串）
# 单行 flow 风格列表：[] 或 ['a', 'b']
#
# 为什么不用多行列表：空值时多行写法会渲染出 `- ''` 这种垃圾条目，
# 或者把下一行粘坏。群白名单这种"要么空要么短"的列表用 flow 风格最稳。
render_yaml_flow() {
    local raw="$1" out="" first=1
    if [ -n "$raw" ]; then
        IFS=',' read -ra items <<< "$raw"
        for it in "${items[@]}"; do
            it="$(echo "$it" | tr -d '[:space:]')"
            [ -z "$it" ] && continue
            if [ $first -eq 1 ]; then first=0; else out+=", "; fi
            out+="'${it}'"
        done
    fi
    if [ -z "$out" ]; then printf '[]'; else printf '[%s]' "$out"; fi
}

render_yaml_list() {
    local raw="$1" indent="$2" empty_placeholder="${3:-}"
    local pad out="" n=0
    pad=$(printf '%*s' "$indent" '')
    if [ -n "$raw" ]; then
        IFS=',' read -ra items <<< "$raw"
        for it in "${items[@]}"; do
            it="$(echo "$it" | tr -d '[:space:]')"
            [ -z "$it" ] && continue
            out+="${pad}- '${it}'"$'\n'
            n=$((n+1))
        done
    fi
    if [ "$n" -eq 0 ]; then
        if [ -n "$empty_placeholder" ]; then
            out="${pad}- '${empty_placeholder}'"$'\n'
        fi
    fi
    printf '%s' "$out"
}

# ── 把 "provider:model,provider:model" 渲染成 allowedModels 的 YAML 列表 ──
# 输出形如（缩进 10）：
#           - provider: cpa
#             model: deepseek-v4.1-flash
#
# 留空 → 输出空字符串（由调用方决定是否渲染 enabled: false）
# 单行 flow 风格的模型路由：[{provider: a, model: b}, ...] 或 []
#
# 为什么需要：多行列表在 env 为空时会留下未被替换的占位符（awk 按整行
# 等值匹配，空值匹配不到），YAML 直接断掉。flow 风格没有这个问题。
render_model_routes_flow() {
    local raw="$1" out="" first=1
    if [ -n "$raw" ]; then
        IFS=',' read -ra items <<< "$raw"
        for it in "${items[@]}"; do
            it="$(echo "$it" | tr -d '[:space:]')"
            [ -z "$it" ] && continue
            local prov="${it%%:*}"
            local mdl="${it#*:}"
            if [ -z "$prov" ] || [ -z "$mdl" ] || [ "$prov" = "$it" ]; then
                echo "WARN: 跳过格式错误的模型路由 '$it'（应为 provider:model）" >&2
                continue
            fi
            if [ $first -eq 1 ]; then first=0; else out+=", "; fi
            out+="{provider: ${prov}, model: ${mdl}}"
        done
    fi
    if [ -z "$out" ]; then printf '[]'; else printf '[%s]' "$out"; fi
}
render_model_routes() {
    local raw="$1" indent="${2:-10}"
    local pad out="" n=0
    pad=$(printf '%*s' "$indent" '')
    local sub=$((indent + 2))
    local subpad
    subpad=$(printf '%*s' "$sub" '')
    if [ -n "$raw" ]; then
        IFS=',' read -ra items <<< "$raw"
        for it in "${items[@]}"; do
            it="$(echo "$it" | tr -d '[:space:]')"
            [ -z "$it" ] && continue
            local prov="${it%%:*}"
            local mdl="${it#*:}"
            if [ -z "$prov" ] || [ -z "$mdl" ] || [ "$prov" = "$it" ]; then
                echo "WARN: 跳过格式错误的模型路由 '$it'（应为 provider:model）" >&2
                continue
            fi
            out+="${pad}- provider: ${prov}"$'\n'
            out+="${subpad}model: ${mdl}"$'\n'
            n=$((n+1))
        done
    fi
    printf '%s' "$out"
}

# ── 准备各列表 ──────────────────────────────────────────────────
# 群白名单：留空会被插件 fallback 成 ['*']（放行所有群），这里给占位并告警
GROUP_ALLOW_YAML="$(render_yaml_list "${DSH_GROUP_ALLOW:-}" 8 "''")"
DSH_GROUP_ALLOW_INLINE="$(render_yaml_flow "${DSH_GROUP_ALLOW:-}")"
if [ -n "${DSH_GROUP_ALLOW_INLINE}" ]; then export DSH_GROUP_ALLOW_INLINE; fi
# 只有真的启用 allowlist 才需要白名单。默认 groupMode=open 时空表是正常的，
# 不该报警（以前这里无条件 warn，误导性很强）。
if [ "${DSH_GROUP_MODE}" = "allowlist" ] && [ -z "${DSH_GROUP_ALLOW:-}" ]; then
    echo "WARN: DSH_GROUP_MODE=allowlist 但 DSH_GROUP_ALLOW 为空" >&2
    echo "      插件会把空数组当成 ['*']，等于放行所有群 —— 请填群 openid。" >&2
fi

# 重点人员：没 @ 也会叫醒她看一眼的人（留空则代码里退化为 c2cAllow）
VIP_SENDERS_YAML="$(render_yaml_list "${DSH_VIP_SENDERS:-}" 6 '''')"
# 用单行 flow 风格：多行列表在空值时会留下未替换的占位符，YAML 直接断掉。
DSH_VIP_SENDERS_INLINE="$(render_yaml_flow "${DSH_VIP_SENDERS:-}")"
export DSH_VIP_SENDERS_INLINE
if [ -z "${DSH_VIP_SENDERS:-}" ]; then
    echo "WARN: DSH_VIP_SENDERS 为空 —— 重点人员触发不会生效（仅 @ 能叫到她）" >&2
fi

# 子智能体模型授权表（顺序即回退顺序）
SUBAGENT_MODELS_YAML="$(render_model_routes "${DSH_SUBAGENT_MODELS:-}" 10)"
DSH_SUBAGENT_MODELS_FLOW="$(render_model_routes_flow "${DSH_SUBAGENT_MODELS:-}")"
export DSH_SUBAGENT_MODELS_FLOW
if [ -z "${DSH_SUBAGENT_MODELS:-}" ]; then
    echo "INFO: DSH_SUBAGENT_MODELS 为空 —— 子智能体不启用模型选择（跟随默认模型）" >&2
fi
export DSH_SUBAGENT_MAX_DEPTH="${DSH_SUBAGENT_MAX_DEPTH:-3}"
export DSH_SUBAGENT_MAX_PARALLEL="${DSH_SUBAGENT_MAX_PARALLEL:-4}"

# ── 替换 ────────────────────────────────────────────────────────
export QQBOT_APPID="${QQBOT_APPID:-}"
export QQBOT_SECRET="${QQBOT_SECRET:-}"


# 群聊门控：显式给了 DSH_GROUP_MODE 就照办；否则按有没有白名单推断。
#
# open 才该是默认 —— 拉个新群直接能用，不用先去查群 openid。
# 群里仍受 requireMention 约束（只有 @ 才触发），不会到处插话。
if [ -n "${DSH_GROUP_MODE:-}" ]; then
    export DSH_GROUP_MODE
elif [ -n "${DSH_GROUP_ALLOW:-}" ]; then
    export DSH_GROUP_MODE=allowlist
else
    export DSH_GROUP_MODE=open
fi

# 两遍替换：先环境变量，再整行替换 YAML 列表
#
# ⚠️ ga / vip 用 -v 传入时，末尾换行已被 $(...) 剥掉
#    （bash 命令替换会去掉所有尾部换行）。所以用 print 而不是 printf "%s"，
#    由 awk 自己补回车 —— 否则最后一条列表项会和下一行粘在一起，YAML 就坏了。
envsubst '${QQBOT_APPID} ${QQBOT_SECRET} ${DSH_SUBAGENT_MAX_DEPTH} ${DSH_SUBAGENT_MAX_PARALLEL} ${DSH_GROUP_MODE} ${DSH_GROUP_ALLOW_INLINE} ${DSH_VIP_SENDERS_INLINE} ${DSH_SUBAGENT_MODELS_FLOW}' < "$TPL" | \
awk -v ga="$GROUP_ALLOW_YAML" -v vip="$VIP_SENDERS_YAML" -v sm="$SUBAGENT_MODELS_YAML" '
    $0 == "${DSH_GROUP_ALLOW_YAML}"    { print ga;  next }
    $0 == "${DSH_VIP_SENDERS_YAML}"    { print vip; next }
    $0 == "${DSH_SUBAGENT_MODELS_YAML}" { print sm;  next }
    { print }
' > "$TARGET"

# ── 自检 1：渲染结果不能残留未替换的占位符 ──────────────────────
if grep -q '\${[A-Z_]*}' "$TARGET"; then
    echo "ERROR: 渲染后仍有未替换的占位符：" >&2
    grep -n '\${[A-Z_]*}' "$TARGET" >&2
    exit 1
fi


echo "rendered config: $TARGET ($(wc -l < "$TARGET") lines)"
