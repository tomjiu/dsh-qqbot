/**
 * config-sync —— 以 Web profile 为准，把配置同步给 qqbot profile
 *
 * 背景：
 *
 * QQ 机器人和 Web 界面是两套独立 profile、两个独立进程：
 *
 *   data/profiles/web/cordis.patch.yml    ← Web UI 改的是这份
 *   data/profiles/qqbot/cordis.patch.yml  ← QQ 机器人读的是这份
 *
 * Web 那边有完整的设置页（模型、子智能体、Agent 循环、联网搜索），
 * 用户在 UI 里配好之后，qqbot 这边**完全不知道** —— 它还跑着自己那份。
 * 具体表现就是：Web 模型页加了模型/选了模型，QQ 会话里显示空、或用的还是旧的。
 *
 * 这个插件把「Web 有 UI、qqbot 没有」的条目单向同步过来：
 * **Web 是唯一真源（single source of truth），qqbot 跟随。**
 *
 * 为什么不让两边 include 同一份配置：
 *   configEditor.edit() 里 `const path = this.documentPath`，只写 profile
 *   自己的 cordis.patch.yml。include 进来的共享文件它写不到，那条路不通。
 *
 * 为什么要排除几项：
 *   - permission：qqbot 必须是 danger-full-access（容器里要读写文件、装包），
 *     跟 Web 同步会让机器人直接废掉。
 *   - im-qqbot / worldbook / meow-memory / model-fallback：
 *     qqbot 独有，Web 那边根本没有。
 */
import { readFile } from 'node:fs/promises'

export const name = 'config-sync'

// configEditor 用来写回配置；agentDefaultModel 用来让模型立即生效。
// 两者都可能不存在（精简 profile），所以不写死注入，运行时探测。
export const inject = []

const WEB_PROFILE = '/home/node/.dsh/profiles/web/cordis.patch.yml'

/** Web 有设置页、qqbot 应该跟随的条目。 */
const DEFAULT_SYNC_IDS = [
  'llm-pi-ai',
  'agent-default-model',
  'subagent',
  'agent-loop',
  'web-search',
]

/**
 * 从一份 profile patch 里抠出某个 id 的 YAML 块。
 *
 * 为什么不用 js-yaml 解析整个文件：profile patch 里大量使用 YAML 自定义
 * 标签（`!!js`），通用解析器会直接报错。先按 `- id:` 边界切块，
 * 再单独解析目标块，就不会碰到别处的自定义标签。
 */
function extractBlock(text, id) {
  const lines = text.split('\n')
  const start = lines.findIndex(line => new RegExp(`^-\\s+id:\\s*['"]?${id}['"]?\\s*$`).test(line))
  if (start === -1) return undefined

  const indent = lines[start].length - lines[start].trimStart().length
  const block = [lines[start]]
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i]
    const stripped = line.trim()
    const lineIndent = line.length - line.trimStart().length
    // 同级或更浅的下一个条目 = 本块结束
    if (stripped.startsWith('- ') && lineIndent <= indent) break
    if (stripped.startsWith('- insert:') && lineIndent <= indent) break
    block.push(line)
  }
  return block.join('\n')
}

/** 解析出该条目的 config 对象；解析失败返回 undefined。 */
async function readConfig(text, id) {
  const block = extractBlock(text, id)
  if (block === undefined) return undefined
  try {
    // js-yaml 是 CommonJS 包：dynamic import 拿到的是命名空间对象，
    // 具名导出不一定有，必须回落到 .default 上取。
    const yamlModule = await import('js-yaml')
    const yaml = yamlModule.default ?? yamlModule
    const parsed = yaml.load(block)
    // 块以 "- " 开头，YAML 会把整块解析成「列表里的一项」，
    // 所以真正的条目在 parsed[0]，不是 parsed 本身。
    const entry = Array.isArray(parsed) ? parsed[0] : parsed
    if (entry === null || typeof entry !== 'object') return undefined
    const config = entry.config
    if (config === null || typeof config !== 'object') return undefined
    return config
  } catch {
    return undefined
  }
}

const stable = value => {
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

export function apply(ctx, config = {}) {
  const intervalMs = Number.isFinite(config.intervalMs) ? config.intervalMs : 5000
  const webPath = config.webProfilePath ?? WEB_PROFILE
  const syncIds = Array.isArray(config.syncIds) && config.syncIds.length > 0
    ? config.syncIds.map(String)
    : DEFAULT_SYNC_IDS

  // 记录每项上次同步失败的原因，避免每轮刷屏同一句。
  const lastError = new Map()
  let debugged = false

  const tick = async () => {
    let text
    try {
      text = await readFile(webPath, 'utf8')
    } catch (error) {
      if (!debugged) {
        debugged = true
        console.warn(`[config-sync] 读不到 web profile：${String(error?.message ?? error)}`)
      }
      return
    }

    // 只在前几轮打印一次诊断，之后静默。
    if (!debugged) {
      debugged = true
      const found = syncIds.filter(id => extractBlock(text, id) !== undefined)
      console.warn(`[config-sync] Web 侧可同步的条目：${found.length > 0 ? found.join(', ') : '(无)'}`)
    }

    for (const id of syncIds) {
      const wanted = await readConfig(text, id)
      if (wanted === undefined) continue

      const editor = ctx.get('configEditor')
      if (editor === undefined) {
        // 没有编辑器就退化为「只记一笔」，不要反复刷日志。
        if (lastError.get(id) !== 'no-editor') {
          lastError.set(id, 'no-editor')
          console.warn('[config-sync] 没有 configEditor 服务，无法写回配置')
        }
        return
      }

      const all = editor.entries()
      const entry = all.find(candidate => (candidate.options?.id ?? candidate.options?.entryId) === id)
      if (entry === undefined) continue

      // agent-default-model 走专用服务，能让当前进程立刻换模型。
      if (id === 'agent-default-model') {
        const target = ctx.get('agentDefaultModel')
        if (target === undefined) continue
        const current = target.currentSelection()
        if (current.provider === wanted.provider && current.model === wanted.model) continue
        try {
          await target.saveSelection({ provider: wanted.provider, model: wanted.model })
          console.warn(
            `[config-sync] 跟随 Web 默认模型：${current.provider}/${current.model} → ${wanted.provider}/${wanted.model}`,
          )
          lastError.delete(id)
        } catch (error) {
          reportOnce(lastError, id, error)
        }
        continue
      }

      // 其余条目：比对各字段，只在真的不同时才写。
      const current = entry.options?.config ?? {}
      if (stable(current) === stable(wanted)) continue

      try {
        await editor.edit(entry, () => wanted)
        console.warn(`[config-sync] 已跟随 Web 配置：${id}`)
        lastError.delete(id)
      } catch (error) {
        reportOnce(lastError, id, error)
      }
    }
  }

  const reportOnce = (map, id, error) => {
    const message = String(error instanceof Error ? error.message : error)
    if (map.get(id) === message) return
    map.set(id, message)
    console.warn(`[config-sync] 同步 ${id} 失败（继续重试）：${message}`)
  }

  ctx.effect(() => {
    const handle = setInterval(() => {
      void tick()
    }, intervalMs)
    return () => clearInterval(handle)
  })

  console.warn(`[config-sync] 已启用，每 ${intervalMs}ms 跟随 ${webPath}：${syncIds.join(', ')}`)
}
