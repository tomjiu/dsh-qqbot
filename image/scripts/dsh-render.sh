#!/usr/bin/env bash
# 按当前 .env 重新渲染 profile 配置
#
# 用法（容器内）：
#   dsh-render                重新渲染（改了 .env 里的模型表/群设置之后用）
#   docker compose exec dsh dsh-render && docker compose restart dsh
#
# 渲染会覆盖 cordis.patch.yml。每次覆盖前自动留一份 .bak-render-<时间>，
# 但只保留最近 KEEP 份 —— 以前不清理，跑十几次就攒出十几个备份文件，
# 目录里全是噪音。
set -Eeuo pipefail

KEEP=3

PROFILE="${QQ_PROFILE:-qqbot}"
DIR="${DSH_HOME:-/home/node/.dsh}/profiles/${PROFILE}"
CFG="${DIR}/cordis.patch.yml"

if [ -f "$CFG" ]; then
    BAK="${CFG}.bak-render-$(date +%Y%m%d-%H%M%S)"
    cp "$CFG" "$BAK"
    echo "backup: $(basename "$BAK")"

    # 只留最近 $KEEP 份，按文件名（含时间戳）倒序
    mapfile -t olds < <(ls -1t "${CFG}".bak-render-* 2>/dev/null | tail -n +$((KEEP + 1)))
    for old in "${olds[@]:-}"; do
        [ -n "$old" ] && rm -f "$old" && echo "  pruned: $(basename "$old")"
    done
fi

bash /opt/dsh/image/scripts/render-profile.sh --force

echo
echo "渲染完成。让配置生效："
echo "  docker compose restart dsh"
