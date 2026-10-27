// 群聊触发策略单元测试
//
// 用真实的 mentionGate 中间件 + 构造的 ctx，验证三档策略。
// 不依赖真人发消息，可重复执行。
//
// 跑法：在 profile 目录下 node test-trigger.mjs
//
// 判定标准：每条断言都能失败。如果被测逻辑被改坏，这里必须红。

import { mentionGate } from '@tencent-connect/qqbot-nodejs';

const APP_ID = 'QQ_APPID_PLACEHOLDER';
const VIP = 'VIP_OPENID_PLACEHOLDER';
const STRANGER = 'FFEE00112233445566778899AABBCCDD';
const GROUP = 'GROUP_OPENID_PLACEHOLDER';

let pass = 0;
let fail = 0;
const failures = [];

function check(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    failures.push(name);
    console.log(`  ✗ ${name}${detail ? `  ← ${detail}` : ''}`);
  }
}

/**
 * 构造一个最小的 ctx。
 * @param {object} o
 * @param {'group'|'c2c'} o.kind
 * @param {string} o.senderId
 * @param {string} o.content
 * @param {string} [o.rawEventType]
 * @param {Array}  [o.mentions]
 */
function makeCtx({ kind = 'group', senderId, content = '', rawEventType, mentions }) {
  const stopped = [];
  const reached = [];
  const ctx = {
    bot: { appId: APP_ID },
    message: {
      kind,
      senderId,
      senderName: 'tester',
      content,
      groupOpenid: GROUP,
      rawEventType: rawEventType ?? (kind === 'group' ? 'GROUP_MESSAGE_CREATE' : 'C2C_MESSAGE_CREATE'),
      mentions,
    },
    state: {},
    log: { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} },
    stop: (reason) => { stopped.push(reason); },
  };
  const next = async () => { reached.push('next'); };
  return { ctx, next, stopped, reached };
}

/** 复刻补丁里的策略配置（必须与 middleware-setup.js 保持一致） */
function buildGate({ vipSenders, requireMention = true, debug = false } = {}) {
  const vips = new Set(vipSenders ?? []);
  // 与补丁同款：复刻 mentionGate 的三条 @ 判定
  const isMentioned = (ctx) => {
    const msg = ctx.message;
    if (msg.rawEventType === 'GROUP_AT_MESSAGE_CREATE') return true;
    if (Array.isArray(msg.mentions) && msg.mentions.some((m) => m?.is_you === true)) return true;
    const appId = ctx.bot?.appId ?? APP_ID;
    if (msg.content && appId) {
      const escaped = String(appId).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const re = new RegExp('<@!?' + escaped + '>');
      if (re.test(msg.content)) return true;
    }
    return false;
  };
  return mentionGate({
    requireMentionInGroup: requireMention,
    isImplicitMention: (ctx) => {
      if (ctx.message.kind !== 'group') return false;
      const sid = ctx.message.senderId;
      if (!sid || !vips.has(sid)) return false;
      if (isMentioned(ctx)) return false;   // 被 @ 就不算 vip 触发
      ctx.state.vipTrigger = true;
      return true;
    },
  });
}

async function run(gate, spec) {
  const { ctx, next, stopped, reached } = makeCtx(spec);
  await gate(ctx, next);
  return { ctx, stopped, reached, answered: reached.includes('next') };
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T1】非重点人员闲聊 —— 必须拦截，不调模型');
{
  const gate = buildGate({ vipSenders: [VIP] });
  const r = await run(gate, { senderId: STRANGER, content: '今天天气不错' });
  check('不进入下一层（不调模型）', r.answered === false);
  check('ctx.stop 被调用', r.stopped.length === 1, `stopped=${JSON.stringify(r.stopped)}`);
  check('拦截原因为 no_mention', r.ctx.state.mention?.reason === 'no_mention', `reason=${r.ctx.state.mention?.reason}`);
  check('未打 vipTrigger 标记', r.ctx.state.vipTrigger !== true);
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T2】重点人员不 @ —— 必须放行，且打 vipTrigger');
{
  const gate = buildGate({ vipSenders: [VIP] });
  const r = await run(gate, { senderId: VIP, content: '我回来了' });
  check('放行到下一层（调模型）', r.answered === true);
  check('ctx.stop 未被调用', r.stopped.length === 0);
  check('置位 vipTrigger', r.ctx.state.vipTrigger === true);
  check('wasMentioned 为 false', r.ctx.state.mention?.wasMentioned === false);
  check('implicit 为 true', r.ctx.state.mention?.implicit === true);
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T3】被 @ —— 必须放行，且【不】打 vipTrigger');
{
  const gate = buildGate({ vipSenders: [VIP] });
  // 通过 rawEventType 表达 @（QQ 平台的权威信号）
  const r = await run(gate, {
    senderId: VIP,
    content: '在吗',
    rawEventType: 'GROUP_AT_MESSAGE_CREATE',
  });
  check('放行到下一层', r.answered === true);
  check('wasMentioned 为 true', r.ctx.state.mention?.wasMentioned === true);
  check('未打 vipTrigger（@ 与 vip 不串味）', r.ctx.state.vipTrigger !== true);
}
{
  // 另一条判定路径：内容里含 <@appid>
  const gate = buildGate({ vipSenders: [VIP] });
  const r = await run(gate, {
    senderId: STRANGER,
    content: `<@${APP_ID}> 你好`,
    rawEventType: 'GROUP_MESSAGE_CREATE',
  });
  check('内容含 <@appid> 时也判定为 @', r.ctx.state.mention?.wasMentioned === true);
  check('且放行', r.answered === true);
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T5】重点人员被 @ —— 不应走 vip 分支');
{
  const gate = buildGate({ vipSenders: [VIP] });
  const r = await run(gate, {
    senderId: VIP,
    content: '帮我看看',
    rawEventType: 'GROUP_AT_MESSAGE_CREATE',
  });
  check('未打 vipTrigger（先判 @）', r.ctx.state.vipTrigger !== true);
  check('wasMentioned 为 true', r.ctx.state.mention?.wasMentioned === true);
}

// ═══════════════════════════════════════════════════════════
console.log('\n【C1】vipSenders 名单变更立即生效');
{
  // 名单为空 → 重点人员也拦
  const gateEmpty = buildGate({ vipSenders: [] });
  const r1 = await run(gateEmpty, { senderId: VIP, content: '在吗' });
  check('名单为空时 vip 也被拦截', r1.answered === false);

  // 名单包含 → 放行
  const gateHas = buildGate({ vipSenders: [VIP] });
  const r2 = await run(gateHas, { senderId: VIP, content: '在吗' });
  check('名单包含后放行', r2.answered === true);
}

// ═══════════════════════════════════════════════════════════
console.log('\n【C2】requireMention=false 时全放行（对照，确认配置确实可选）');
{
  const gate = buildGate({ vipSenders: [], requireMention: false });
  const r = await run(gate, { senderId: STRANGER, content: '随便说点什么' });
  check('全员放行', r.answered === true);
}

// ═══════════════════════════════════════════════════════════
console.log('\n【C3】私聊不受群策略影响');
{
  const gate = buildGate({ vipSenders: [VIP] });
  const r = await run(gate, { kind: 'c2c', senderId: STRANGER, content: '私聊消息' });
  check('c2c 放行', r.answered === true);
  check('c2c 不打 vipTrigger', r.ctx.state.vipTrigger !== true);
  check('c2c wasMentioned 视为 true', r.ctx.state.mention?.wasMentioned === true);
}

// ═══════════════════════════════════════════════════════════
console.log(`\n${'═'.repeat(50)}`);
console.log(`通过 ${pass} / 失败 ${fail}`);
if (fail > 0) {
  console.log('失败项：');
  for (const f of failures) console.log('  - ' + f);
  process.exit(1);
}
console.log('全部通过');

