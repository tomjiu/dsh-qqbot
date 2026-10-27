#!/usr/bin/env bash
# 容器内常用维护命令封装
#
# 用法（在容器内）：
#   dsh-url      打印当前 Web 地址（含 token）
#   dsh-relogin  清除 QQ 凭据，下次启动重新进入绑定流程
#   dsh-logs     实时看日志
#   dsh-restart  重启 dsh（不重建容器）
#   dsh-status   查看服务状态
set -Eeuo pipefail

DSH_HOME="${DSH_HOME:-/home/node/.dsh}"
PROFILE="${MAIN_PROFILE:-main}"
LOG_DIR=/tmp/dsh-logs

case "${1:-}" in
  url)
    if [ -f "${DSH_HOME}/web-url.txt" ]; then
      cat "${DSH_HOME}/web-url.txt"
    else
      grep -aoE "http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+" "${LOG_DIR}/main.log" 2>/dev/null | head -1 \
        || echo "web URL 尚未就绪；先看 docker compose logs -f"
    fi
    ;;

  relogin)
    echo "==> 清除 QQ 凭据，重新进入扫码绑定"
    F="${DSH_HOME}/profiles/${PROFILE}/cordis.patch.yml"
    if [ -f "$F" ]; then
      cp "$F" "${F}.bak-relogin-$(date +%H%M%S)"
      sed -i -E "s/^(\s*)appId:.*/\1appId: ''/; s/^(\s*)appSecret:.*/\1appSecret: ''/" "$F"
      echo "    已清空 appId/appSecret，备份在同目录 *.bak-relogin-*"
    fi
    # 清掉 env 里的凭据，否则会被当成本次启动的凭据
    echo "    如果 .env 里填了 QQBOT_APPID/QQBOT_SECRET，需要一并清空"
    echo "    插件会热重载，随后在 Web 侧栏「QQ Bot 绑定」扫码"
    ;;

  logs)
    cmd="${2:-main}"
    if [ "$cmd" = "all" ]; then
      stdbuf -oL tail -n+1 -F "${LOG_DIR}"/*.log
    else
      stdbuf -oL tail -n+1 -F "${LOG_DIR}/${cmd}.log"
    fi
    ;;

  restart)
    echo "==> 重启 dsh（Web + QQ 同进程）"
    pkill -f "dsh --profile ${PROFILE}" 2>/dev/null || true
    echo "    done（容器会按 restart 策略拉起，或手动 docker compose restart）"
    ;;

  status)
    echo "==> 进程"
    pgrep -af "dsh --profile" || echo "  (none)"
    echo
    echo "==> 端口"
    ss -tlnp 2>/dev/null | grep -E ":(8765|8766)" || echo "  (none)"
    echo
    echo "==> Web 地址"
    [ -f "${DSH_HOME}/web-url.txt" ] && cat "${DSH_HOME}/web-url.txt" || echo "  (未就绪)"
    ;;

  *)
    cat <<EOF
用法: dsh-ctl <command>

  url       打印当前 Web 地址（含 token）
  relogin   清除 QQ 凭据，重新走扫码绑定
  logs      [main|fwd|all] 跟踪日志
  restart   重启 dsh 进程（不重建容器）
  status    查看进程 / 端口 / Web 地址
EOF
    ;;
esac
