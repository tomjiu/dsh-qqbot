// T4：重点人员连发多条 —— 验证 concurrencyGuard 的 merge 策略
//
// 被测风险：
//   concurrencyGuard({ strategy: 'merge' }) 会把同 peer 的连续消息合并。
//   如果合并逻辑丢内容（只保留最后一条、或丢 envelope / 附件），
//   她就看不到前面几句 —— 表现为「我说了三句她只回最后一句」。
//
// 这个测试用真实的 concurrencyGuard + 构造的 ctx，
// 模拟「第 1 条正在处理时，第 2、3 条到达」的时序。

import { concurrencyGuard } from '@tencent-connect/qqbot-nodejs';

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) { pass++; console.log(`  ✓ ${name}`); }
  else { fail++; failures.push(name); console.log(`  ✗ ${name}${detail ? `  ← ${detail}` : ''}`); }
}

const GROUP = 'GROUP_OPENID_PLACEHOLDER';
const TARGET = { scope: 'group', targetId: GROUP };

/** 构造一个带完整中间件链的 ctx（含 historyBuffer + envelopeFormatter） */
function makeCtx({ content, attachments = [], senderId = 'VIP_OPENID_PLACEHOLDER', history = [] }) {
  const state = { mention: { wasMentioned: true, shouldAnswer: true, reason: 'passthrough' } };
  if (history.length) state.history = history;
  return {
    bot: { appId: 'QQ_APPID_PLACEHOLDER' },
    message: {
      kind: 'group',
      senderId,
      senderName: '明明就',
      content,
      groupOpenid: GROUP,
      rawEventType: 'GROUP_AT_MESSAGE_CREATE',
      attachments,
      replyTarget: TARGET,
      timestamp: new Date().toISOString(),
    },
    state,
    log: { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} },
    abort: () => {},
  };
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T4a】连发 3 条：内容必须全部保留');
{
  // 用真实策略：merge（与 middleware-setup.js 一致）
  const guard = concurrencyGuard({ strategy: 'merge', maxQueue: 10, maxProcessingMs: 10000 });

  // 模拟：第 1 条开始处理（busy），第 2、3 条在期间到达
  let release = null;
  const firstDone = new Promise((r) => { release = r; });

  // 第 1 条：占用锁，直到手动释放
  const ctx1 = makeCtx({ content: '我买了个新键盘' });
  const p1 = guard(ctx1, async () => { await firstDone; });

  // 第 2、3 条：应进入 mergeBuffer
  const ctx2 = makeCtx({ content: '青轴的' });
  const ctx3 = makeCtx({ content: '吵得要死' });
  const p2 = guard(ctx2, async () => {});
  const p3 = guard(ctx3, async () => {});

  // 等一帧确保 buffer 就位
  await new Promise((r) => setTimeout(r, 30));
  release();
  await Promise.all([p1, p2, p3]);

  // ⚠️ 合并方向：drainMergeBuffer 把 buffer 合并进【新 survivor】（第 2 条），
  //    而不是合进正在处理的第 1 条。所以：
  //      ctx1 → 单独成一轮（正在处理，内容不变）
  //      ctx2 → 成为 survivor，content = "青轴的\n吵得要死"
  //      ctx3 → 被合并掉，不再单独成轮
  const merged = ctx2.message.content;
  check('第1条独立成轮（内容未被污染）', ctx1.message.content === '我买了个新键盘', ctx1.message.content);
  check('第2条成为 survivor', merged.includes('青轴的'), merged);
  check('第3条内容合并进 survivor', merged.includes('吵得要死'), merged);
  check('第3条不再单独成轮', ctx3.message.content === '吵得要死' && merged.includes('吵得要死'));
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T4b】连发 3 条：envelope 必须全部保留');
{
  const guard = concurrencyGuard({ strategy: 'merge', maxQueue: 10, maxProcessingMs: 10000 });

  let release = null;
  const firstDone = new Promise((r) => { release = r; });

  const mk = (c, env) => { const x = makeCtx({ content: c }); x.state.envelope = env; return x; };

  const c1 = mk('第一句', '[Chat history begins]\n[A] x\n[Chat history ends]\n第一句');
  const p1 = guard(c1, async () => { await firstDone; });
  const c2 = mk('第二句', 'env2');
  const p2 = guard(c2, async () => {});
  const c3 = mk('第三句', 'env3');
  const p3 = guard(c3, async () => {});

  await new Promise((r) => setTimeout(r, 30));
  release();
  await Promise.all([p1, p2, p3]);

  // survivor 是 c2（第 2 条），它的 envelope 合并了 env2 + env3
  const env = c2.state.envelope ?? '';
  check('envelope 含 env2', env.includes('env2'), env);
  check('envelope 含 env3', env.includes('env3'), env);
  check('c1 的 envelope 未被污染', c1.state.envelope.includes('第一句') && !c1.state.envelope.includes('env2'), c1.state.envelope);
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T4c】连发含附件：附件不能丢');
{
  const guard = concurrencyGuard({ strategy: 'merge', maxQueue: 10, maxProcessingMs: 10000 });
  let release = null;
  const firstDone = new Promise((r) => { release = r; });

  const c1 = makeCtx({ content: '看图', attachments: [{ type: 'image', path: '/a.jpg' }] });
  const p1 = guard(c1, async () => { await firstDone; });
  const c2 = makeCtx({ content: '还有这张', attachments: [{ type: 'image', path: '/b.jpg' }] });
  const p2 = guard(c2, async () => {});
  const c3 = makeCtx({ content: '以及这张', attachments: [{ type: 'image', path: '/c.jpg' }] });
  const p3 = guard(c3, async () => {});

  await new Promise((r) => setTimeout(r, 30));
  release();
  await Promise.all([p1, p2, p3]);

  // survivor 是 c2：附件为 b + c；a 属于独立成轮的 c1
  const paths = (c2.message.attachments ?? []).map((a) => a.path);
  check('c1 保留自己的附件 a.jpg', (c1.message.attachments ?? []).some(a => a.path === '/a.jpg'));
  check('survivor 含 b.jpg', paths.includes('/b.jpg'), JSON.stringify(paths));
  check('survivor 含 c.jpg', paths.includes('/c.jpg'), JSON.stringify(paths));
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T4d】不并发时逐条处理（对照组，确认没把顺序搞坏）');
{
  const guard = concurrencyGuard({ strategy: 'merge', maxQueue: 10, maxProcessingMs: 10000 });
  const order = [];
  for (const text of ['甲', '乙', '丙']) {
    const ctx = makeCtx({ content: text });
    await guard(ctx, async () => { order.push(ctx.message.content); });
  }
  check('三条按序各处理一次', order.join(',') === '甲,乙,丙', order.join(','));
}

// ═══════════════════════════════════════════════════════════
console.log('\n【T4e】空内容消息不污染合并结果');
{
  const guard = concurrencyGuard({ strategy: 'merge', maxQueue: 10, maxProcessingMs: 10000 });
  let release = null;
  const firstDone = new Promise((r) => { release = r; });

  const c1 = makeCtx({ content: '有内容' });
  const p1 = guard(c1, async () => { await firstDone; });
  // 纯 @ 无文本：content 为空
  const c2 = makeCtx({ content: '' });
  const p2 = guard(c2, async () => {});
  const c3 = makeCtx({ content: '也有内容' });
  const p3 = guard(c3, async () => {});

  await new Promise((r) => setTimeout(r, 30));
  release();
  await Promise.all([p1, p2, p3]);

  const merged = c1.message.content;
  check('空内容没被拼进去产生空行', !merged.includes('\n\n'), JSON.stringify(merged));
  check('有内容的都保留', merged.includes('有内容'), JSON.stringify(merged));
}

console.log(`\n${'═'.repeat(50)}`);
console.log(`通过 ${pass} / 失败 ${fail}`);
if (fail > 0) {
  console.log('失败项：');
  for (const f of failures) console.log('  - ' + f);
  process.exit(1);
}
console.log('全部通过');

