#!/usr/bin/env node
/**
 * 校验 profile 模板是合法的 cordis patch YAML。
 *
 * 为什么用 Node 而不是 Python：
 *   dsh 自带 js-yaml，任何环境都能直接跑，不需要额外装依赖。
 *   容器里没有 pyyaml，宿主机 Python 也不一定有。
 *
 * 为什么单独成文件而不是内联：
 *   模板里有 ${VAR} 占位符，跨平台的 sed 行为不一致
 *   （Git Bash / GNU sed / BusyBox 各有差异），内联写法在 Windows 上会误报。
 */
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)

let yaml
try {
  yaml = require('js-yaml')
} catch {
  // 在仓库根目录跑时 js-yaml 可能不在解析路径上，退回去找 dsh 自带的。
  // 同时覆盖 Linux 容器和 Windows 宿主两种安装位置 ——
  // 校验脚本本身不能依赖「跑在哪里」。
  const candidates = [
    '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/js-yaml',
    process.env.APPDATA && `${process.env.APPDATA}/npm/node_modules/@deepseek-ai/dsh/node_modules/js-yaml`,
    process.env.APPDATA && `${process.env.APPDATA}/npm/node_modules/js-yaml`,
  ].filter(Boolean)
  for (const c of candidates) {
    try { yaml = require(c); break } catch {}
  }
}

if (yaml === undefined) {
  console.error('找不到 js-yaml（仓库或 dsh 全局安装）')
  process.exit(1)
}

const path = process.argv[2]
if (!path) {
  console.error('用法: validate-template.mjs <template.yml>')
  process.exit(1)
}

let text = readFileSync(path, 'utf8')

// 占位符替换成合法标量，否则 ${X} 会被当成 flow mapping 报错
text = text.replace(/\$\{[A-Z_]+\}/g, 'PLACEHOLDER')

let docs
try {
  docs = yaml.loadAll(text)
} catch (error) {
  console.error(`YAML 解析失败: ${error.message}`)
  process.exit(1)
}

const root = docs.find((doc) => doc !== undefined && doc !== null)
if (root === undefined) {
  console.error('模板解析后为空')
  process.exit(1)
}

if (!Array.isArray(root)) {
  console.error(`顶层必须是 YAML 数组，实际是 ${Array.isArray(root) ? 'array' : typeof root}`)
  process.exit(1)
}

for (const [i, entry] of root.entries()) {
  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
    console.error(`第 ${i + 1} 个条目不是对象`)
    process.exit(1)
  }
  if (entry.id === undefined && entry.insert === undefined) {
    console.error(`第 ${i + 1} 个条目既没有 id 也没有 insert`)
    process.exit(1)
  }
}

// 模板必须含的关键条目
const ids = new Set(root.filter((e) => typeof e.id === 'string').map((e) => e.id))
for (const required of ['im-qqbot', 'agent-default-model', 'permission', 'meow-memory', 'tools', 'subagent']) {
  if (!ids.has(required)) {
    console.error(`模板缺少必要条目: ${required}`)
    process.exit(1)
  }
}

console.log('OK')