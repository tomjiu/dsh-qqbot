# 健壮性测试清单

> **这份清单的自我约束**
>
> 每一条都必须**能失败**。判据是：如果被测的那部分代码/配置被改坏，这条用例会红。
> 凡是在系统坏掉时仍然会通过的，一律不写进来（例如「grep 一个刚写好的配置项」）。
>
> 每条包含：**被测风险 / 操作 / 判定 / 这条能发现什么**

---

## 一、补丁持久性（真的会丢的那种验证）

### R1. 补丁在 node_modules 被整体删除后能重新应用

**被测风险**：`pnpm patch` 机制失效 —— 升级插件、清理缓存、换机器后自定义逻辑静默消失，
表现为「群聊突然又只认 @ 了」，而且没有任何报错。

**操作**

```bash
# 记录补丁基线（不是“有没有”，而是“补丁后再装回来是否一模一样”）
docker compose exec dsh bash -lc 'sha256sum ~/.dsh/profiles/qqbot/node_modules/@tencent-connect/dsh-qqbot/dist/transport/inbound.js'

# 真正删掉整个依赖树（不是 pnpm install，那是空跑）
docker compose exec dsh bash -lc 'cd ~/.dsh/profiles/qqbot && rm -rf node_modules'

# 从零重装
docker compose exec dsh bash -lc 'cd ~/.dsh/profiles/qqbot && CI=true pnpm install 2>&1 | tail -3'

# 再取一次哈希
docker compose exec dsh bash -lc 'sha256sum ~/.dsh/profiles/qqbot/node_modules/@tencent-connect/dsh-qqbot/dist/transport/inbound.js'
```

**判定**

- 两次 sha256 **完全一致**
- 4 个文件都含 `[PATCH]` 标记
- `config.js` 含 `vipSenders`

**能发现什么**

- `patchedDependencies` 写错 / patch 文件路径错 → 重装后文件是原版（哈希变化）
- patch 文件与插件版本不匹配 → pnpm 报错或打不上
- 只改 `node_modules` 没走 patch 的开发期遗留 → 重装即丢

**当前状态**：⚠️ **未测**。我上次跑的 `pnpm install` 只用了 893ms，什么都没重装。

---

### R2. 补丁在镜像重建后仍然存在（构建期验证）

**被测风险**：镜像构建时按错误顺序打补丁（先打后装会被覆盖），
结果是「本地能用，别人拉镜像不能用」。

**操作**

```bash
docker compose build --no-cache 2>&1 | grep -E "patch verified|ERROR"
```

**判定**：构建日志出现 `patch verified`；若没打上，Dockerfile 里
`grep -q PATCH || exit 1` 会让**构建直接失败**。

**能发现什么**：Dockerfile 里补丁步骤的顺序错误。

**当前状态**：✅ 已通过（构建期有硬校验）。

---

## 二、群聊触发策略（对抗性验证）

> 这一组是改动最核心的部分，也是最容易「看起来对、实际错」的地方。

### T1. 非重点人员闲聊：**必须零模型调用**

**被测风险**：`mentionGate` 没拦住，每条群消息都开一轮模型 ——
账单上体现，但功能上毫无异常，最难发现。

**操作**

```bash
# 1. 记录当前轮次与 token 用量
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/--workspace--/*/*.zstd 2>/dev/null | grep -c "turn/start"'

# 2. 用【非重点人员的号】在群里发 10 条普通消息，全都不 @

# 3. 再记录一次
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/--workspace--/*/*.zstd 2>/dev/null | grep -c "turn/start"'
```

**判定**：`turn/start` 数量 **增量为 0**。

**能发现什么**

- `vipSenders` 配错（把所有人放进去了）
- `requireMention` 被改成 false
- `accessPolicy` 把群判成 open

---

### T2. 重点人员不 @：必须触发**且**带群历史

**被测风险**：`inbound.js` 的 `includeHistory` 只在 `wasMentioned` 时才带历史 ——
原来的代码就是这样，我改了；如果改动没生效，她只看到孤零零一句话，判断不了要不要接。

**操作**

```bash
# 1. 让非重点人员在群里先发 3 条（进缓冲，不触发）
# 2. 重点人员不 @ 发 1 条
# 3. 检查这一轮注入的正文
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/--workspace--/*/*.zstd 2>/dev/null \
  | tail -30 | grep -o "Chat history begins" | tail -1'
```

**判定**：三个条件同时成立

- 出现 `[Note] 这条是重点人员刚发的消息`
- 出现 `[Chat history begins]`（说明带上了前面那 3 条）
- 且 `[Chat history ends]` 之前的行数 ≥ 3

**能发现什么**

- `vipTrigger` 标记没打上（缺 `[Note]`）
- `includeHistory` 改动没生效（缺 `[Chat history begins]`）
- `historyBuffer` 被跳过（中间件顺序被改坏）

---

### T3. 被 @ 时不出现 vip 标记

**被测风险**：`isImplicitMention` 判断过宽，把「真 @」也当成 vip 触发，
导致她收到「这条是重点人员发的（没有 @ 你）」—— 而实际上是 @ 的，语义错了。

**操作**：重点人员在群里 **@ 她** 说一句话。

**判定**

- `user/message` 正文**含 `<@`**（@ 标记）
- 正文**不含** `[Note] 这条是重点人员刚发的消息`

**能发现什么**：`vipTrigger` 在 `wasMentioned` 时也被置真。

---

### T4. 重点人员连发多条：会不会被合并成一轮

**被测风险**：`concurrencyGuard({ strategy: 'merge' })` 会把同 peer 的连续消息合并。
若重点人员快速发 3 条，可能只触发 1 轮，**她只看到最后一句**。

**这是已知风险，我从未验证过。**

**操作**

```bash
# 重点人员快速连发 3 条有独立含义的消息，例如：
#   「我买了个新键盘」/「青轴的」/「吵得要死」
# 三条之间间隔 < 3 秒
```

**判定**

- 检查是否产生 1 轮还是 3 轮
- 若是 1 轮，看注入的正文里**是否包含全部 3 句**

```bash
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/--workspace--/*/*.zstd 2>/dev/null \
  | tail -40 | grep -o "新键盘\|青轴\|吵得要死" | sort | uniq -c'
```

**能发现什么**

- 消息被合并且内容丢失 → **功能性缺陷，需要调 `maxQueue` 或 merge 策略**
- 或反过来：每条都单独开一轮 → 浪费 token

**当前状态**：⚠️ **未测，且我认为这是最可能出问题的一条。**

---

### T5. 群白名单生效：不在白名单的群不响应

**被测风险**：`groupMode: allowlist` + `groupAllow` 为空时，插件 fallback 成 `['*']`
—— **等于放行所有群**。这是个反直觉的坑，我之前踩过。

**操作**

- 用一个**不在 `DSH_GROUP_ALLOW` 里**的群，把机器人拉进去（或本来就有一个）
- 在群里 @ 她

**判定**：日志出现 `Access blocked: ...`，且**无** `turn/start` 增量。

```bash
docker compose logs --since 5m dsh | grep -i "access blocked"
```

**能发现什么**：`groupAllow` 渲染成空数组 → 放行所有群。

---

## 三、「不回」的真实性

### S1. 模型输出空文本时，QQ 侧确实没有消息

**被测风险**：`outbound.js` 判断空文本的逻辑被破坏（比如流式 buffer 里残留空白），
导致「不回」变成「发一条空白消息」或「发半句话」。

**操作**

- 重点人员不 @ 说一句没什么可接的（「嗯」「哦」）
- **同时在 QQ 客户端观察**（群里是否真的没有任何新消息）
- **同时看服务端**

```bash
# 1. 该轮的 assistant 输出
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/--workspace--/*/*.zstd 2>/dev/null \
  | tail -20 | grep -o "\"type\":\"text\",\"text\":\"[^\"]*\"" | tail -2'

# 2. 有没有真的走到发送
docker compose exec dsh bash -lc 'grep -c "sendMarkdown" /tmp/dsh-logs/qqbot.log 2>/dev/null || echo "无日志"`
```

**判定**

- 若 `assistant/message` 的 text 为空 → QQ **必须**无消息
- 客户端与服务端结论一致

**能发现什么**

- 空文本仍触发 `sendMarkdown`（发空消息）
- 流式 buffer 的 `flush()` 把空白也发了

**注意**：这条**必须客户端和服务端双向确认**，只看一边都会误判。

---

### S2. 流式输出与「不回」的交互

**被测风险**：`shouldStream()` 对 c2c 且有 msgId 才开流式；群聊不开。
但如果群聊因为某次重连拿到了 msgId，可能开始流式输出，
此时「模型说空」的路径与 `onMessage` 不同。

**操作**

- 私聊她一句没什么可接的（「哦」）
- 检查是否触发流式 flush

**判定**：私聊下即使流式开，最终 `fullText.trim()` 为空时也不发送。

```bash
docker compose exec dsh bash -lc 'grep -o "shouldStream\|buffer.flush\|cancel()" /tmp/dsh-logs/qqbot.log 2>/dev/null | tail -5'
```

**能发现什么**：流式路径绕过了空文本检查。

---

## 四、服务不中断

### U1. 容器重启后不用重新扫码

**被测风险**：凭据存在容器内临时层，重建即丢 —— 用户每次 `docker compose up` 都要扫码。

**操作**

```bash
docker compose down
docker compose up -d
sleep 45
docker compose logs --since 1m dsh | grep -E "Bot ready|二维码|扫码"
```

**判定**

- 出现 `Bot ready! appId=...`
- **不出现**二维码 / 扫码引导

**能发现什么**：`data/profiles` 挂载缺失或被清空。

---

### U2. 进程崩溃后能自愈

**被测风险**：某个子服务挂了，容器整体不退出（`wait -n` 失效），表现为「机器人在线但不说话」。

**操作**

```bash
# 杀掉 qqbot 进程，观察容器是否按 restart 策略重建
docker compose exec dsh bash -lc 'pkill -f "dsh --profile qqbot"'
sleep 60
docker compose ps
docker compose logs --since 1m dsh | grep -E "a service exited|Bot ready"
```

**判定**

- 容器状态恢复 `Up`（`restart: unless-stopped` 生效）
- 日志重新出现 `Bot ready`

**能发现什么**：`entrypoint.sh` 的 `wait -n` 没生效，容器挂着但不工作。

---

### U3. 配置错误时快速失败，而不是带病运行

**被测风险**：YAML 写坏了，服务静默降级（比如掉回默认配置），
表现为「功能莫名不对，但没有报错」。

**操作**

```bash
# 故意写坏配置
docker compose exec dsh bash -lc 'echo "  bad: [unclosed" >> ~/.dsh/profiles/qqbot/cordis.patch.yml'
docker compose restart dsh
sleep 30
docker compose logs --since 1m dsh | grep -iE "error|failed|invalid"
```

**判定**：启动失败并给出明确错误，**不是**静默用默认值跑起来。

**恢复**

```bash
docker compose exec dsh bash -lc 'sed -i "/bad: \[unclosed/d" ~/.dsh/profiles/qqbot/cordis.patch.yml'
```

**能发现什么**：Loader 的容错策略是否吞掉了配置错误。

---

### U4. 端口冲突时不会拖垮整个服务

**被测风险**：这是之前的真实事故 —— `webServer` 是 DSH 必需插件，
端口 8770 被占用导致**整个 DSH 启动失败**。

**操作**

```bash
# 占住 8770
docker compose exec -Td dsh bash -lc 'python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"127.0.0.1\",8770)); s.listen(); time.sleep(120)" &'
sleep 2
docker compose restart dsh
sleep 30
docker compose logs --since 1m dsh | grep -iE "EADDRINUSE|startup failed|Bot ready"
```

**判定**

- **不应**出现 `startup failed`（因为已经不再挂 `qqbot-webserver`）
- 若出现，说明还有别的插件在抢这个端口

**能发现什么**：`speak-up` 之类的插件被重新引入。

---

## 五、各项配置的触发性

> 这组测的是「配置改了之后，行为确实变了」——不是「配置里有这个值」。

### C1. `vipSenders` 增删立即影响触发

**被测风险**：名单是从 `c2cAllow` 兜底来的，或代码里缓存了，导致改名单不生效。

**操作**

```bash
# 1. 把 vipSenders 清空
docker compose exec dsh bash -lc 'cd ~/.dsh/profiles/qqbot && cp cordis.patch.yml /tmp/bak-yml && python3 -c "
import re
p=\"cordis.patch.yml\"
s=open(p).read()
s=re.sub(r\"(vipSenders:\s*\n)(\s+- .*\n)+\",r\"\1      - \\'\\'\\n\",s)
open(p,\"w\").write(s)
"'
docker compose restart dsh && sleep 30

# 2. 重点人员不 @ 发一句，看是否还触发
# 3. 恢复
docker compose exec dsh bash -lc 'cp /tmp/bak-yml ~/.dsh/profiles/qqbot/cordis.patch.yml'
docker compose restart dsh
```

**判定**

- 清空后：**不触发**（无 `turn/start` 增量、无 `[Note]`）
- 恢复后：**重新触发**

**能发现什么**：名单被硬编码、或兜底逻辑覆盖了配置。

---

### C2. `quietHours` 在时间窗内不触发

**被测风险**：安静时段只写进了配置，但 `dsh-proactive` 的 `respectQuietHours`
在闹钟层面才判断 —— 若闹钟设了 `respectQuietHours: false`，配置形同虚设。

**操作**

```bash
# 1. 把安静时段改成「当前时间 ±10 分钟」
docker compose exec dsh bash -lc 'python3 - <<PY
import json, datetime
p = "/home/node/.dsh/proactive/config.json"
d = json.load(open(p))
now = datetime.datetime.now()
d["quietHours"] = {
    "start": (now - datetime.timedelta(minutes=10)).strftime("%H:%M"),
    "end":   (now + datetime.timedelta(minutes=10)).strftime("%H:%M"),
    "timeZone": "Asia/Shanghai",
}
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print("quietHours ->", d["quietHours"])
PY'

# 2. 建一个 1 分钟后触发的闹钟（用 dsh-add-alarm 或手工）
# 3. 等它到点，观察是否被跳过
```

**判定**：到点后日志/`runs.jsonl` 显示因安静时段跳过，**QQ 无消息**。

**能发现什么**

- 闹钟的 `respectQuietHours` 被设成 false
- 安静时段的时区判断错误（容器 TZ 与配置不一致）

---

### C3. `historyLimit` 真的限制注入条数

**被测风险**：`historyLimit` 只用于显示，实际注入的是全部历史 ——
长群会把大量 token 塞进去。

**操作**

```bash
# 1. 改 historyLimit 为 3
# 2. 让群里先有 10 条历史（非重点人员说，不触发）
# 3. 重点人员不 @ 说一句
# 4. 数注入的历史行数
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/--workspace--/*/*.zstd 2>/dev/null \
  | tail -60 | awk "/Chat history begins/,/Chat history ends/" | grep -c "^\["'
```

**判定**：`[Chat history begins]` 与 `[Chat history ends]` 之间的消息行数 **≤ 3**。

**能发现什么**：`historyBuffer({ limit })` 没生效（中间件配置被覆盖）。

---

## 五之二、模型降级链（model-fallback 插件）

上游会对**单个模型**做「模型级限流」（code 6004，同凭证其他模型不受影响）。
只固化一个默认模型时，一被限流每轮请求都直接失败 —— QQ 上就是「她不说话了」。

`image/plugins/model-fallback/` 解决这个：第 0 档用会话选择/默认模型，
失败就自动换 `DSH_SUBAGENT_MODELS` 表里的下一个，不用人管也不用重启。

### F1. 有限流的模型作默认 → 自动降级并完成任务（核心）

用 `dsh headless` 跑一次性任务，对照两组：

```bash
# 准备 overlay（默认模型故意填被限流的那个）
docker cp /tmp/fb-base.yml   dsh:/tmp/fb-base.yml    # provider cpa + agent-default-model=deepseek-v4.1-flash
docker cp /tmp/fb-plugin.yml dsh:/tmp/fb-plugin.yml  # - insert: model-fallback

# 对照组：不打插件 → 必须失败
docker compose exec -T dsh bash -lc 'timeout 120 dsh headless --patch /tmp/fb-base.yml "reply with exactly: OK"'

# 实验组：打插件 → 必须成功且日志写出换模型
docker compose exec -T dsh bash -lc 'timeout 150 dsh headless --patch /tmp/fb-base.yml --patch /tmp/fb-plugin.yml "reply with exactly: OK"'
```

**判定**：

| 组 | 期望 |
|---|---|
| 对照组 | 报 `RATE_LIMIT: 503 ... code 6004` |
| 实验组 | 输出 `OK`，且出现 `[model-fallback] 首选模型 失败（RATE_LIMIT…）→ 第 2 档换到 cpa/step-5-preview` |

**实测结果（2026-10-26）**：对照组失败、实验组成功，与期望一致。

### F2. 未配回退表时不接管

`DSH_SUBAGENT_MODELS` 留空 → 插件 `return` 前只打一行「未启用」，
不挂任何监听。

**判定**：行为与不打这个插件完全一致（`agent/request` 透传原配置）。

### F3. 每轮回到第 0 档，不会永久停在兜底模型

**判定**：连续两轮任务，第一轮降级到第 2 档后，第二轮日志仍从
「首选模型 失败 …」开始，而不是直接用上一轮的兜底模型。

---

## 六、不建议用自动化测的（人工判断）

下面这些**没有客观判据**，写了也是走过场，只做人工抽样：

- 「回复像不像人」—— 只能人看
- 「世界书绿灯有没有触发」—— `grep plugin:worldbook` 就够，不必单列
- 「人设是否生效」—— 同上

---

## 七、优先级

| 优先级 | 用例 | 理由 |
|---|---|---|
| **P0** | R1 补丁真删真装 | 丢了会静默失效，最难查 |
| **P0** | T1 零调用的判定 | 直接烧钱，且功能上无异常 |
| **P0** | T4 连发合并 | 从未验证，可能丢消息 |
| **P1** | T2 带历史 / T3 不串味 | 核心改动，但一次就能看清 |
| **P1** | U1 重启不扫码 | 影响日常使用 |
| **P1** | U2 崩溃自愈 | 影响「不断掉」这个目标 |
| **P2** | C1/C2/C3 配置触发 | 属于调优，不是致命项 |
| **P2** | U3/U4 快速失败 | 已经修过一次，主要防回归 |

---

## 八、需要你配合的部分

| 用例 | 需要你做什么 |
|---|---|
| T1 | 用**另一个号**在群里发 10 条 |
| T2 | 先让另一个号发 3 条，再用你的号不 @ 发 1 条 |
| T3 | 用你的号 @ 她一次 |
| T4 | 用你的号**快速连发 3 条**（间隔 < 3 秒） |
| T5 | 需要第二个群，可能没有 |
| S1 | QQ 客户端观察是否真没消息 |

其余（R1/R2/U1/U2/U3/U4/C1/C2/C3）我可以在容器里独立完成。

---

## 附：每条用例的失败意味着什么

| 失败用例 | 说明什么 | 修哪里 |
|---|---|---|
| R1 | 补丁机制失效 | `pnpm-workspace.yaml` 的 `patchedDependencies` |
| T1 | 门控失效 | `middleware-setup.js` 的 `mentionGate` |
| T2 | 历史没带 | `inbound.js` 的 `includeHistory` |
| T3 | 判定串味 | `isImplicitMention` 与 `wasMentioned` 的优先级 |
| T4 | 消息被合并丢失 | `concurrencyGuard` 的 `strategy: merge` |
| U1 | 凭据不持久 | `data/profiles` 挂载 |
| U2 | 容器不自愈 | `entrypoint.sh` 的 `wait -n` + compose restart |
| U4 | 端口冲突拖垮全局 | 是否又引入了 `webserver` 这类必需 id |
