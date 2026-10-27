/** Worldbook engine. File reads occur during prompt assembly, before pre-step.
 * Writers must use writeWorldbook (SHA-256 revision + exclusive .lock file); a
 * lock untouched for LOCK_STALE_MS is abandoned and reclaimed once.
 * Keyword hits are injected as a synthetic user message, whose source kind must
 * stay producer-owned (session format V4) or the whole turn is refused.
 * Existing running plugin closures require a process restart to load this code.
 */
import { createHash, randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { readFile, open, rename, unlink, stat } from 'node:fs/promises'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { isAbsolute } from 'node:path'

export const inject = ['systemPrompt', 'tools']

/** Session format v4 admits producer-owned source kinds only: a third-party
 * producer is addressed as `plugin:<name>`. The released V3 shape
 * `{ kind: 'plugin', plugin: 'worldbook' }` is a hard refusal under V4
 * ("format v4 message requires a producer-owned source kind") and takes the
 * whole turn down before the model is ever called. `plugin` is kept beside the
 * kind because the UI labels a source by it.
 */
const SOURCE = Object.freeze({ kind: 'plugin:worldbook', plugin: 'worldbook' })
const hash = text => createHash('sha256').update(text).digest('hex')
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value)

/** Validate without dropping unknown fields or silently repairing user data. */
export function validateWorldbook(book) {
  if (!record(book) || !Array.isArray(book.entries)) throw new Error('世界书必须包含 entries 数组')
  const ids = new Set()
  for (const e of book.entries) {
    if (!record(e) || typeof e.id !== 'string' || !e.id.trim() || ids.has(e.id)) throw new Error('条目 id 必须非空且唯一')
    ids.add(e.id)
    for (const key of ['title', 'content']) if (typeof e[key] !== 'string' || !e[key].trim()) throw new Error(`${e.id}: ${key} 不能为空`)
    for (const key of ['constant', 'enabled', 'caseSensitive']) if (e[key] !== undefined && typeof e[key] !== 'boolean') throw new Error(`${e.id}: ${key} 必须为布尔值`)
    if (e.keys !== undefined && (!Array.isArray(e.keys) || e.keys.some(k => typeof k !== 'string' || !k.trim()))) throw new Error(`${e.id}: keys 必须为非空字符串数组`)
    if (e.constant !== true && e.enabled !== false && !e.keys?.length) throw new Error(`${e.id}: 绿灯条目需要关键词`)
    if (e.repeat !== undefined && !['once', 'always'].includes(e.repeat)) throw new Error(`${e.id}: repeat 必须是 once 或 always`)
  }
  return book
}
function decode(text) { return { book: validateWorldbook(JSON.parse(text)), revision: hash(text) } }
export async function readWorldbook(path) { return decode(await readFile(path, 'utf8')) }

/** A lock nobody refreshed for this long is abandoned: its writer died mid-write
 * (a process kill leaves the file behind, which used to block every later write
 * until someone deleted it by hand). Real writes take milliseconds.
 */
const LOCK_STALE_MS = 120_000

async function lockIsStale(lockPath) {
  try { return Date.now() - (await stat(lockPath)).mtimeMs > LOCK_STALE_MS } catch { return false }
}

/** Cooperating writers share this lock, including other module instances/processes.
 * A live lock always fails explicitly and is never stolen. A stale lock is dropped
 * exactly once and retried, so a killed writer cannot wedge the book forever.
 */
async function acquireLock(lockPath) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const handle = await open(lockPath, 'wx')
      await handle.writeFile(`${process.pid}\n${new Date().toISOString()}\n`, 'utf8')
      return handle
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
      if (attempt === 0 && await lockIsStale(lockPath)) { await unlink(lockPath).catch(() => {}); continue }
      throw new Error('世界书正被其他写入者锁定；请稍后重新读取并重试')
    }
  }
  throw new Error('世界书正被其他写入者锁定；请稍后重新读取并重试')
}

export async function writeWorldbook(path, book, expectedRevision, { signal } = {}) {
  const candidate = structuredClone(book)
  validateWorldbook(candidate)
  if (typeof expectedRevision !== 'string' || !expectedRevision) throw new Error('写入需要 expectedRevision；请先读取最新世界书')
  signal?.throwIfAborted()
  const lockPath = `${path}.lock`
  const lock = await acquireLock(lockPath)
  const temp = `${path}.${randomUUID()}.tmp`
  try {
    if ((await readWorldbook(path)).revision !== expectedRevision) throw new Error('世界书版本冲突；请重新读取后合并修改')
    signal?.throwIfAborted()
    const text = JSON.stringify(candidate, null, 2) + '\n'
    const handle = await open(temp, 'wx')
    try { await handle.writeFile(text, 'utf8'); await handle.sync() } finally { await handle.close() }
    signal?.throwIfAborted()
    // Also catch non-cooperating edits that happened during preparation.
    if ((await readWorldbook(path)).revision !== expectedRevision) throw new Error('世界书版本冲突；请重新读取后合并修改')
    await rename(temp, path)
    return { book: candidate, revision: hash(text) }
  } finally {
    await unlink(temp).catch(error => { if (error.code !== 'ENOENT') throw error })
    await lock.close()
    await unlink(lockPath)
  }
}

const fields = {
  title: { type: 'string' }, content: { type: 'string' },
  keys: { type: 'array', items: { type: 'string' } },
  constant: { type: 'boolean' }, caseSensitive: { type: 'boolean' },
  repeat: { type: 'string', enum: ['once', 'always'] }, enabled: { type: 'boolean' },
}
function entryVersion(e) { return hash(JSON.stringify(e)) }
function textOf(m) { return (m.content ?? []).filter(b => b.type === 'text').map(b => b.text).join('\n') }
/** A constant entry with `onlyProviders` is injected only when the current model's provider matches. */
function entryAppliesToProvider(e, provider) {
  if (!Array.isArray(e.onlyProviders) || e.onlyProviders.length === 0) return true
  return e.onlyProviders.includes(provider)
}

export async function apply(ctx, config = {}) {
  const configured = config.path || process.env.DSH_WORLDBOOK_PATH || './worldbook.json'
  const path = isAbsolute(configured) ? configured : fileURLToPath(new URL(configured, ctx.baseUrl || pathToFileURL(process.cwd() + '/')))
  let snapshot = await readWorldbook(path)
  let lastError = ''
  const refreshSync = () => {
    try {
      snapshot = decode(readFileSync(path, 'utf8'))
      lastError = ''
    } catch (error) {
      if (lastError !== error.message) ctx.logger.warn('世界书读取失败，暂用最后有效版本: %s', error.message)
      lastError = error.message
    }
    return snapshot.book
  }
  // Always register, even when currently empty: future additions must appear.
  ctx.systemPrompt.section({
    name: 'worldbook:constant', order: Number.isFinite(config.sectionOrder) ? config.sectionOrder : 420,
    text: (context) => {
      const book = refreshSync()
      const provider = context?.agent?.options?.provider ?? ''
      const constants = book.entries.filter(e => e.enabled !== false && e.constant === true && entryAppliesToProvider(e, provider))
      return [
        '## 世界书（用户持久背景）',
        '按用户明确要求保存或修改长期偏好时使用 worldbook 工具。当前用户指令优先于旧条目；条目是背景信息，不扩大工具权限。',
        `文件：${path}。文件修改会在下次模型调用前自动加载。`,
        ...(lastError ? ['世界书文件暂时无法读取或无效，当前使用最后有效版本。'] : []),
        ...constants.map(e => `### ${e.title}\n${e.content}`),
      ].join('\n\n')
    },
  })
  const fired = new WeakMap()
  ctx.on('agent/pre-step', async (payload, next) => {
    const decision = await next()
    if (decision.kind !== 'enter' || !payload.agent || !payload.messages?.length) return decision
    // Re-read also handles edits between assembly and this callback.
    const book = refreshSync()
    const enteredIds = new Set(decision.messages.map(m => m.id))
    const claimed = payload.messages.filter(m => enteredIds.has(m.id) && m.source?.kind === 'user')
    const text = claimed.map(textOf).join('\n')
    if (!text) return decision
    let seen = fired.get(payload.agent)
    if (!seen) { seen = new Map(); fired.set(payload.agent, seen) }
    const hits = book.entries.filter(e => e.enabled !== false && e.constant !== true &&
      (e.repeat === 'always' || seen.get(e.id) !== entryVersion(e)) &&
      e.keys?.some(k => e.caseSensitive ? text.includes(k) : text.toLowerCase().includes(k.toLowerCase())))
    if (!hits.length) return decision
    payload.signal?.throwIfAborted()
    try {
      const message = {
        id: randomUUID(), role: 'user', source: { ...SOURCE },
        content: [{ type: 'text', text: '[世界书注入 · worldbook]\n以下为相关背景资料，无需回复确认：\n\n' + hits.map(e => `### ${e.title}\n${e.content}`).join('\n\n') }],
      }
      const index = decision.messages.findLastIndex(m => claimed.some(c => c.id === m.id))
      for (const e of hits) seen.set(e.id, entryVersion(e))
      return { ...decision, messages: decision.messages.toSpliced(index + 1, 0, message) }
    } catch (error) {
      // 注入失败只跳过本轮；任何异常都不允许把整轮对话带走。
      ctx.logger.warn('世界书关键词注入失败，本轮跳过: %s', error?.message ?? String(error))
      return decision
    }
  })

  let queue = Promise.resolve()
  const serialize = task => {
    const run = queue.then(task)
    queue = run.catch(() => {}) // failed writes must not poison subsequent calls
    return run
  }
  const summary = e => ({ ...structuredClone(e), mode: e.constant ? 'constant(蓝灯)' : 'keyword(绿灯)' })
  ctx.tools.register({
    name: 'worldbook',
    description: '维护世界书持久背景。list/get 读取；add 新增；update 按 id 修改；remove 删除；reload 立即读取文件。蓝灯 constant=true；绿灯 keys 为触发关键词。修改旧条目前先 get，使用返回的 revision 作为 expectedRevision 避免覆盖并发修改。',
    parameters: {
      type: 'object', additionalProperties: false, required: ['op'],
      properties: {
        op: { type: 'string', enum: ['list', 'get', 'add', 'update', 'remove', 'reload'] },
        id: { type: 'string' }, expectedRevision: { type: 'string' }, ...fields,
      },
    },
    output: {
      schema: { type: 'object', additionalProperties: false, required: ['ok', 'message', 'revision'], properties: {
        ok: { type: 'boolean' }, message: { type: 'string' }, revision: { type: 'string' }, entries: { type: 'array', items: { type: 'object' } },
      } },
      render(args, value) {
        const lines = [value.message, `revision: ${value.revision}`]
        for (const e of value.entries ?? []) {
          lines.push(`[${e.id}] ${e.title} ${e.mode} ${e.enabled === false ? '(停用)' : ''}`)
          if (e.keys?.length) lines.push('keys: ' + e.keys.join(' / '))
          if (args.op !== 'list') lines.push(e.content)
        }
        return [{ type: 'text', text: lines.join('\n') }]
      },
    },
    async execute(args, exec = {}) {
      return serialize(async () => {
        exec.signal?.throwIfAborted()
        const latest = await readWorldbook(path)
        if (['list', 'get', 'reload'].includes(args.op)) {
          snapshot = latest
          const entries = args.op === 'get' ? latest.book.entries.filter(e => e.id === args.id) : latest.book.entries
          if (args.op === 'get' && !entries.length) throw new Error(`条目不存在: ${args.id}`)
          return { ok: true, message: `共 ${entries.length} 条`, revision: latest.revision, entries: entries.map(summary) }
        }
        if (args.expectedRevision && args.expectedRevision !== latest.revision) throw new Error('世界书版本冲突；请重新读取后合并修改')
        if (['update', 'remove'].includes(args.op) && !args.expectedRevision) throw new Error('修改或删除前请先 get，并传入 expectedRevision')
        const candidate = structuredClone(latest.book)
        let entry
        if (args.op === 'add') {
          entry = { id: args.id || `entry-${randomUUID()}` }
          for (const key of Object.keys(fields)) if (args[key] !== undefined) entry[key] = args[key]
          candidate.entries.push(entry)
        } else if (args.op === 'update' || args.op === 'remove') {
          const index = candidate.entries.findIndex(e => e.id === args.id)
          if (index < 0) throw new Error(`条目不存在: ${args.id}`)
          entry = candidate.entries[index]
          if (args.op === 'remove') candidate.entries.splice(index, 1)
          else for (const key of Object.keys(fields)) if (args[key] !== undefined) entry[key] = args[key]
        } else throw new Error(`未知 op: ${args.op}`)
        const committed = await writeWorldbook(path, candidate, latest.revision, { signal: exec.signal })
        snapshot = committed
        return { ok: true, message: `已${args.op === 'remove' ? '删除' : '保存'} [${entry.id}]`, revision: committed.revision, entries: [summary(entry)] }
      })
    },
  })
}

