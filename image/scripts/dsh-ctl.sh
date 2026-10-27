#!/usr/bin/env bash
# 容器内常用维护命令包装
#
# 用法（在容器内）：
#   dsh-url         打印当前 Web 地址（含 token）
#   dsh-relogin     清除 QQ 凭据并重启 qqbot，触发重新扫码
#   dsh-logs        实时看各服务日志
#   dsh-restart     重启 qqbot（不重建容器）
#   dsh-status      查看服务状态
set -Eeuo pipefail

DSH_HOME="${DSH_HOME:-/home/node/.dsh}"
PROFILE="${QQ_PROFILE:-qqbot}"
LOG_DIR=/tmp/dsh-logs

case "${1:-}" in
  url)
    if [ -f "${DSH_HOME}/web-url.txt" ]; then
      cat "${DSH_HOME}/web-url.txt"
    else
      grep -aoE "http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+" "${LOG_DIR}/web.log" 2>/dev/null | head -1 \
        || echo "web URL 尚未就绪；先看 docker compose logs -f"
    fi
    ;;

  relogin)
    echo "==> 清除 QQ 凭据，下次启动会重新进入扫码引导"
    F="${DSH_HOME}/profiles/${PROFILE}/cordis.patch.yml"
    if [ -f "$F" ]; then
      cp "$F" "${F}.bak-relogin-$(date +%H%M%S)"
      # 把 appId / appSecret 清空（保留其它配置）
      sed -i -E "s/^(\s*)appId:.*/\1appId: ''/; s/^(\s*)appSecret:.*/\1appSecret: ''/" "$F"
      echo "    已清空 appId/appSecret，备份在同目录 *.bak-relogin-*"
    fi
    echo "==> 请执行：docker compose restart dsh"
    echo "    然后用 docker compose logs -f 看二维码"
    ;;

  logs)
    cmd="${2:-all}"
    if [ "$cmd" = "all" ]; then
      stdbuf -oL tail -n+1 -F "${LOG_DIR}"/*.log
    else
      stdbuf -oL tail -n+1 -F "${LOG_DIR}/${cmd}.log"
    fi
    ;;

  restart)
    echo "==> 重启 qqbot 进程"
    pkill -f "dsh --profile ${PROFILE}" 2>/dev/null || true
    sleep 2
    cd /workspace
    setsid nohup dsh --profile "${PROFILE}" >> "${LOG_DIR}/qqbot.log" 2>&1 < /dev/null &
    echo "    done"
    ;;

  status)
    echo "==> 进程"
    pgrep -af "dsh (web|--profile)" || echo "  (none)"
    echo
    echo "==> 端口"
    ss -tlnp 2>/dev/null | grep -E ":(8765|8766|8770)" || echo "  (none)"
    echo
    echo "==> Web 地址"
    [ -f "${DSH_HOME}/web-url.txt" ] && cat "${DSH_HOME}/web-url.txt" || echo "  (未就绪)"
    ;;

  *)
    cat <<EOF
用法: dsh-ctl <command>

  url       打印当前 Web 地址（含 token）
  relogin   清除 QQ 凭据，配合 docker compose restart 触发重新扫码
  logs      [all|web|qqbot|fwd] 跟踪日志
  restart   重启 qqbot 进程（不重建容器）
  status    查看进程 / 端口 / Web 地址
EOF
    ;;
esac
