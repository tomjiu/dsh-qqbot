/**
 * workspace-bootstrap —— 确保工作区被注册
 *
 * 问题现象：所有从 QQ 来的会话在 Web 里都显示「没有工作区分配」。
 *
 * 原因：qqbot 插件建会话时只传了 `meta.cwd`（默认 /workspace），
 * **从不传 workspaceId**：
 *
 *   meta: { cwd: this.config.cwd || process.cwd(), parentSession, seedLength }
 *
 * 而 Web 会话列表是按 workspaceRegistry 分组渲染的。registry 里没有
 * 对应 /workspace 的记录，会话就落在「未分配」里。
 *
 * 实测 data/storages/workspace.json 是这样的：
 *
 *   { "global": { "initialized": true, "workspaceIds": [] },
 *     "tables": { "workspaces": {} } }
 *
 * 已初始化、但一个工作区都没注册 —— 因为 registry 只在 Web 里手动
 * 打开目录时才会创建记录，qqbot 这条路径从来不走它。
 *
 * 这个插件在启动时补上：把 cwd 注册成默认工作区。registry.initializeDefault()
 * 对同一路径重复调用是幂等的（返回已有记录，不改标题），所以重启安全。
 *
 * 注意 data/storages 是两个 profile 共享挂载的，注册一次 Web 那边也能看到。
 */
export const name = 'workspace-bootstrap'

// 用正式注入而不是「延迟 3 秒再 ctx.get()」：实测后者时机不稳定，
// 有时拿到有时拿不到（重启后偶发 workspaceRegistry 为 undefined）。
// 写进 inject，cordis 会等服务就绪再 apply。
export const inject = ['workspaceRegistry']

export function apply(ctx, config = {}) {
  const directories = Array.isArray(config.directories) && config.directories.length > 0
    ? config.directories.map(String)
    : [config.directory ?? '/workspace']

  const titles = config.titles ?? {}

  const run = async () => {
    const registry = ctx.get('workspaceRegistry')
    if (registry === undefined) {
      // 正常不会走到这里（inject 已保证）。保留兜底。
      console.warn('[workspace-bootstrap] 没有 workspaceRegistry，跳过注册')
      return
    }

    for (const directory of directories) {
      try {
        // 关键：用 initializeDefault 而不是 create。
        //
        // initializeDefault 是 DSH 专门给「首次启动建默认工作区」用的：
        //   - 只在 workspaceRegistry 和 session 历史都为空时才动手
        //   - 创建时会写 global.defaultWorkspaceId，Web 界面靠这个字段
        //     认出"默认工作区"
        //
        // 如果直接 create()，registry 里就有了工作区但没有
        // defaultWorkspaceId，于是 Web 那边调 initializeDefault 时会因为
        // `state.workspaceIds.length > 0` 直接返回 undefined，
        // 界面就报「无法创建默认工作区」。这个坑踩过。
        const workspace = await registry.initializeDefault(() => directory)
        if (workspace === undefined) {
          console.warn(`[workspace-bootstrap] 已有工作区或会话，跳过默认工作区初始化（${directory}）`)
        } else {
          console.warn(`[workspace-bootstrap] 默认工作区已就绪：${directory} -> ${workspace.id}`)
        }
      } catch (error) {
        console.warn(`[workspace-bootstrap] 初始化工作区失败：${String(error instanceof Error ? error.message : error)}`)
      }
    }
  }

  // 等 workspace 插件把自己的 init 跑完再注册。用 effect 拿到清理句柄。
  ctx.effect(() => {
    let cancelled = false
    const timer = setTimeout(() => {
      if (!cancelled) void run()
    }, Number.isFinite(config.delayMs) ? config.delayMs : 1000)
    return () => {
      cancelled = true
      clearTimeout(timer)
    }
  })

  console.warn(`[workspace-bootstrap] 已启用，将在启动后注册：${directories.join(', ')}`)
}
