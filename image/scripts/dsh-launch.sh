#!/usr/bin/env bash
# dsh-launch —— 以正确参数启动 dsh
#
# 为什么需要这个包装：
#
# DSH 的 HMR（配置热重载）在构造时检查 loader.internal：
#
#   if (!this.ctx.loader.internal)
#       throw new Error('--expose-internals is required for HMR service')
#
# 没有这个 Node 启动参数，HMR 服务直接起不来，于是**任何对
# cordis.patch.yml 的改动都不会热生效**。
#
# 而这正是「扫码绑定后一直卡在 saving」的根因：插件把凭据写回配置、
# 指望 HMR 重载新 fiber，结果什么都没发生。
#
# 为什么不用 NODE_OPTIONS：
#   Node 明确禁止该变量携带 --expose-internals：
#     node: --expose-internals is not allowed in NODE_OPTIONS
#   只能走命令行。
#
# 为什么不用 docker compose 的 entrypoint 覆盖：
#   dsh 是 ESM 入口（#!/usr/bin/env node），必须让 node 自己带上参数。
#   最简单的做法是把 node 的所有参数原样透传。
set -Eeuo pipefail

DSH_BIN="${DSH_BIN:-/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js}"

exec node --expose-internals "$DSH_BIN" "$@"
