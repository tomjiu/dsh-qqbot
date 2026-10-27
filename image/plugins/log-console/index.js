/**
 * log-console —— 把 DSH 的 logger 接到 stderr
 *
 * 为什么需要这个：
 *
 * DSH 的 ctx.logger 是个「分发器」——它只把日志交给注册过的 exporter。
 * 而 qqbot 这个 app 没装任何 exporter，于是所有 ctx.logger.info/warn/debug
 * 全部被静默丢弃。后果是排查时极其痛苦：
 *
 *   - QQ 插件明明有 `Processing: scope=... body="..."` 的日志，看不到
 *   - 群消息被白名单拦了，`[access] blocked group=...` 也看不到
 *   - 结果就是「群里没反应」但日志一片空白，只能瞎猜
 *
 * 这个插件注册一个 exporter，把日志写成 stderr（console.warn），
 * 这样 `docker compose logs dsh` 一定能看到。
 *
 * 级别（cordis 定义，数字越小越严重）：
 *   error=0  info=1  warn=2  debug=3
 * exporter 的 threshold 判定是 `threshold < level → 丢弃`，
 * 所以 threshold=4 就是「全都要」。
 */
export const name = 'log-console'

// 不依赖任何服务：logger 是 cordis 内建的，注册 exporter 不需要注入别的。
export const inject = []

const LEVEL_NAMES = ['error', 'info', 'warn', 'debug']

const flatten = args => {
  if (!Array.isArray(args)) return String(args ?? '')
  return args
    .map(a => {
      if (typeof a === 'string') return a
      if (a instanceof Error) return a.stack || a.message
      try {
        return JSON.stringify(a)
      } catch {
        return String(a)
      }
    })
    .join(' ')
}

export function apply(ctx, config = {}) {
  const threshold = Number.isFinite(config.level) ? config.level : 4

  // only：只输出名字匹配的子系统，逗号分隔的子串即可。
  // 例：only: ['qqbot', 'agent'] —— 只关心这两块。
  const only = Array.isArray(config.only)
    ? config.only.map(s => String(s).trim()).filter(Boolean)
    : []
  const wanted = name => only.length === 0 || only.some(part => String(name).includes(part))

  ctx.logger.exporter({
    levels: { default: threshold },
    export: message => {
      if (!wanted(message.name)) return
      const label = LEVEL_NAMES[message.level] ?? message.type ?? 'log'
      // 走 stderr：容器日志一定会捕获。ctx.logger 自己在这里会递归，不能用。
      console.warn(`[${message.name}] ${label}: ${flatten(message.args)}`)
    },
  })

  // 用 console.warn 而不是 ctx.logger —— 这个插件自己也要能看见。
  console.warn(`[log-console] 已启用，日志级别阈值=${threshold}${only.length ? `，仅 ${only.join(',')}` : ''}`)
}
