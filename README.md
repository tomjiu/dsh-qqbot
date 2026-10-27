# DSH + QQ Bot

把 DeepSeek Harness 装进容器，接一个官方 QQ 机器人，让她在群里像群友一样聊天，
同时能在容器里真正干活（跑代码、改文件、执行命令）。

- **QQ 接入**：腾讯官方 `@tencent-connect/dsh-qqbot`，走 QQ 开放平台 Bot API v2
  —— 不是第三方协议端，没有封号风险
- **人格**：`dsh-persona-dafeiyu` 人设库 + 酒馆式世界书，可切换、可导入
- **记忆**：`meow-memory` 七层 SQLite 长期记忆
- **主动说话**：`dsh-proactive` 宿主级定时唤醒（能唤醒冷会话）
- **干活**：容器里 python / node / git / gcc 齐全，沙箱放开，AI 能真正操作

---

## 快速开始

```bash
cp .env.example .env
# 编辑 .env，至少填三项：
#   CPA_API_KEY       模型服务商 key
#   DSH_GROUP_ALLOW   允许机器人说话的群 openid
#   （QQBOT_APPID / QQBOT_SECRET 可留空，走扫码）

docker compose up -d --build
docker compose logs -f dsh
```

启动后日志里会依次出现：

```
──────────────────────────────────────
[12:00:00] DSH container
[12:00:00]   dsh      : 0.2.1-rc.2
[12:00:00]   web      : 1  (container :8765 -> host :8766)
──────────────────────────────────────
[12:00:20] WEB UI READY
[12:00:20]   http://127.0.0.1:8766/?token=xxxxxxxx
```

**点开这个带 token 的地址就能进 Web UI。**

---

## QQ 扫码绑定

凭据缺失时（`.env` 里 `QQBOT_APPID` 留空），启动会自动进入扫码引导：

```
[qqbot] ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
[qqbot] █ ▄▄▄▄▄ █ ▀▄▀▄ █▀▀ █ ▄▄▄▄▄ █
[qqbot] █ █   █ █▄█▀ ▀██ ▀▀█ █   █ █
[qqbot] █▄▄▄▄▄█ █ ▀▄▄▀ ▄█ ▀▀ █▄▄▄▄▄█
[qqbot] （用手机 QQ 扫这个码）
[qqbot] 二维码已过期，正在刷新…（自动）
```

用手机 QQ 扫码即可。**二维码过期会自动刷新重打**，直到扫码成功。
凭据写入 `data/profiles/qqbot/`，之后免扫。

重新扫码：

```bash
docker compose exec dsh dsh-ctl relogin
docker compose restart dsh
docker compose logs -f
```

---

## 目录结构

```
.
├── docker-compose.yml        服务定义
├── Dockerfile                镜像构建
├── .env.example              配置模板（复制成 .env）
├── image/                    ← 固化进镜像，运行时只读
│   ├── scripts/
│   │   ├── entrypoint.sh     统一入口：起服务、打印地址
│   │   ├── render-profile.sh 配置模板 → 实际配置
│   │   └── dsh-ctl.sh        维护命令
│   ├── profiles/
│   │   ├── qqbot.cordis.patch.yml.template   profile 配置模板
│   │   └── pnpm-workspace.yaml               pnpm 配置（含补丁声明）
│   ├── plugins/worldbook/    世界书引擎
│   └── patch/                QQ 插件补丁（pnpm patch 格式）
├── data/                     ← 运行时持久化
│   ├── profiles/             profile 配置与插件
│   ├── storages/             人设库等
│   ├── sessions/             会话记录
│   └── proactive/            定时闹钟
└── workspace/                ← AI 的工作区（你的代码）
```

---

## 维护命令

容器内：

```bash
docker compose exec dsh dsh-ctl url        # 打印 Web 地址（含 token）
docker compose exec dsh dsh-ctl status     # 进程 / 端口 / 地址
docker compose exec dsh dsh-ctl logs web   # 跟踪某个服务的日志
docker compose exec dsh dsh-ctl relogin    # 清除 QQ 凭据准备重新扫码
docker compose exec dsh dsh-ctl restart    # 重启 qqbot（不重建容器）
docker compose exec dsh dsh-model          # 模型：查看 / 切换默认模型
docker compose exec dsh dsh-render         # 按 .env 重新渲染配置（改完 .env 用）
docker compose exec dsh dsh-test           # 跑单元测试（改插件后必跑）
```

宿主机：

```bash
docker compose logs -f dsh                  # 全部日志
docker compose logs dsh | grep "Web UI"     # 只找地址
docker compose logs dsh | grep -A25 "DIED"  # 启动失败时看病因
docker compose exec dsh bash                # 进容器
```

---

## 测试

单元测试直接调用真实的中间件代码 + 构造的 `ctx`，**不需要真人发消息**，可重复执行：

```bash
docker compose exec dsh dsh-test
```

| 测试文件 | 覆盖 |
|---|---|
| `test-trigger.mjs` | 群聊三档策略：被 @ 必回 / 重点人员不 @ 触发 / 其他人拦截；@ 与 vip 不串味；名单变更立即生效 |
| `test-concurrency.mjs` | 连发消息合并：内容 / envelope / 附件不丢；空内容不污染 |

**改插件补丁后必须跑**，防止回归。详见 `TEST-PLAN.md`。

---

## 启动失败怎么排查

`entrypoint.sh` 会在宣布成功前等 8 秒确认各进程存活。失败时日志形如：

```
[20:46:25]   ✗ qqbot DIED (pid=90)
[20:46:25] ──── qqbot 日志尾部（最后 25 行）────
  [qqbot] Error: dsh: failed to parse overlay ...: YAMLException: ...
[20:46:25] ✗ 启动失败：有服务在 8s 内退出
[20:46:25]     - profile 配置 YAML 语法错误（检查 data/profiles/qqbot/cordis.patch.yml）
```

**真实原因就在日志尾部**，修好后 `docker compose restart dsh`。

---

## 配置说明

### 模型服务商

**在 Web 设置页里配**：打开 `http://127.0.0.1:8766` → 设置 → 模型，加服务商、填 API key、加模型。

改完 `qqbot` 会在 5 秒内自动跟随（见下面的「模型：以 Web 为准」）。

镜像里预置了一个指向宿主机 OpenAI 兼容网关（`host.docker.internal:8317`）的 `cpa` 服务商，
那是开发时的默认值。**用自己的服务商时，在 Web 里改掉它** —— 不需要碰 `.env`。

> `apiKeyEnv: CPA_API_KEY` 里的 `CPA_API_KEY` **不是环境变量**，是凭据服务里的一个
> 名字（`llm-pi-ai` 里它的 role 是 `credential-ref`）。在 Web 模型页把 key 填进去，
> 就会存到这个名下，运行时直接取用。所以**永远不需要配 env**。

### 群聊白名单

`DSH_GROUP_ALLOW` 填群 openid，多个用逗号分隔。

⚠️ 两个插件层面的坑：

- `groupMode: disabled` 会让**所有群消息被丢弃**（不是"关闭群功能"）
- `groupMode: allowlist` 但 `groupAllow` 为空时，插件会把空数组
  fallback 成 `['*']` —— **等于放行所有群**

所以必须显式填群 openid。

### 群聊触发策略（三档）

| 触发方式 | 行为 |
|---|---|
| **有人 @ 她** | 触发模型，**应当回**。附最近 N 条群历史 |
| **重点人员没 @ 也说话** | 触发模型 + 附群历史，但**回不回由她决定** |
| **其他人闲聊** | 不调模型（消息已进历史缓冲，下次触发时能看到） |

重点人员由 `DSH_VIP_SENDERS` 配置（QQ openid，**不是 QQ 号**，多个用逗号分隔）：

```bash
# .env
DSH_VIP_SENDERS=<VIP_OPENID>
```

**「不回」怎么实现的**：`outbound.js` 对空文本会跳过发送，
所以模型只需不输出文字。`groupPrompt` 里也写明了「没什么好说的就安静待着」。

**为什么不直接 `requireMention: false`**：那样每条群消息都会开一轮模型，
活跃群一天能烧几十块。精确放行 + 其余静默进缓冲，既有上下文又不烧钱。

**怎么拿自己的 openid**：先 @ 她一次，然后

```bash
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/--workspace--/*/*.zstd | grep -o "\[.* ([0-9A-F]\{32\})\]" | head -3'
```

### 模型：以 Web 为准 + 自动降级链

**模型配置在 Web 里改，不在 `.env` 里改。**

打开 `http://127.0.0.1:8766` 的「模型」设置页：加服务商、填 API key、加模型、选默认模型。
改完 **qqbot 会在 5 秒内自动跟随**，不用重启、不用改文件。

为什么能这样：QQ 机器人和 Web 是两个独立进程、两套 profile 配置 —

```
data/profiles/web/cordis.patch.yml    ← Web 设置页写这份
data/profiles/qqbot/cordis.patch.yml  ← QQ 机器人读这份
```

`config-sync` 插件在 qqbot 进程里每 5 秒比对一次，以 **Web 为准**把这几项同步过来：

| 条目 | 同步内容 |
|---|---|
| `llm-pi-ai` | 服务商地址、API key 引用、**模型表** |
| `agent-default-model` | 默认模型 |
| `subagent` / `agent-loop` / `web-search` | 等你在 Web 设置页改过之后自动跟上 |

`permission` **不同步** —— qqbot 必须是 `danger-full-access`（容器里要读写文件、装包），
跟 Web 同步会让机器人直接废掉。`im-qqbot` / `worldbook` / `model-fallback` 也是 qqbot 独有。

日志里看得到：

```bash
docker compose logs dsh | grep config-sync
# [config-sync] 已跟随 Web 配置：llm-pi-ai
# [config-sync] 跟随 Web 默认模型：cpa/step-5-preview → cpa/glm-5.3-flash
```

#### 自动降级链

上游会对**单个模型**做「模型级限流」（code 6004，同凭证其他模型不受影响）。
只配一个模型时，一被限流 agent 每次请求都直接失败，QQ 上就是**「卡死不回」**。

三级分档，每轮都从第 0 档开始试：

| 档位 | 用什么 | 说明 |
|---|---|---|
| 第 0 档 | 会话里挑过的模型 → 没挑过用默认模型 | 尊重你的选择 |
| 第 1..N 档 | `DSH_SUBAGENT_MODELS` 回退表，按顺序 | 便宜模型兜底 |

失败的那一步自动换下一个，**不用人管、不用重启**。

**回退表会自动跳过模型表里不存在的条目。** 这不是可选项 —— 模型表跟着 Web 走
（可能随时被删模型），而回退表来自 `.env`，两者不一致时降级会去调用一个
根本不存在的模型，白白失败一次。所以 `model-fallback` 在**降级那一刻**实时
枚举可用模型，悬空的直接跳过并记日志：

```bash
# [model-fallback] 跳过模型表里不存在的条目：cpa/step-5-preview
# [model-fallback] 首选模型 失败（TRANSPORT: Connection error.）→ 第 2 档换到 cpa/glm-5.3-flash
```

> 为什么是「降级那一刻」而不是启动时算好：实测启动时 `config-sync` 还没同步
> `llm-pi-ai`，拿到的还是旧模型表，过滤等于没做。降级不频繁，实时算开销可忽略。

回退表仍然在 `.env` 里配（它同时是子智能体的模型授权表）：

```bash
DSH_SUBAGENT_MODELS=cpa:deepseek-v4.1-flash,cpa:step-5-preview,cpa:kimi-k3.1-pro,...
```

改完 `docker compose exec dsh dsh-render` 再 `docker compose restart dsh`。

**运行期临时切换默认模型**（会被下一次 config-sync 拉回 Web 的值）：

```bash
docker compose exec dsh dsh-model            # 看当前模型与可用列表
docker compose exec dsh dsh-model probe      # 逐个探活，换服务商后必跑
docker compose exec dsh dsh-model <id>       # 切换
```

**思维链不会漏到 QQ**：`outbound.js` 只取 `content` 里 `type === 'text'` 的块，
`reasoning_content` 是独立字段，不会被发送。聊天里看不到她的内部思考。

### 工作区

`workspace-bootstrap` 插件启动时把 `/workspace` 注册进 `workspaceRegistry`。

不注册的话，所有 QQ 会话在 Web 里都显示「未分配工作区」——因为 qqbot 插件建会话时
只传 `meta.cwd`、不传 `workspaceId`，而 registry 只在 Web 里手动打开目录时才创建记录。
注册是幂等的，重启不会重复建。

### 子智能体

```bash
DSH_SUBAGENT_MAX_DEPTH=3        # 递归层级：子智能体再派子智能体，最多几层
DSH_SUBAGENT_MAX_PARALLEL=4     # 同时最多跑几个
```

`DSH_SUBAGENT_MODELS` 同时充当子智能体的模型授权表 ——
主 Agent 可以按这张表为每个子智能体挑模型、推理强度。

### ⚠️ 别删 `data/profiles/qqbot/patches/`

`package.json` 里的 `pnpm.patchedDependencies` 指向这个目录。删了之后
任何 `pnpm add` / `pnpm install` 都会直接报：

```
ENOENT: no such file or directory, open
  '.../profiles/qqbot/patches/@tencent-connect__dsh-qqbot@0.5.2.patch'
```

`Dockerfile` 里也是先 `COPY image/patch/*.patch` 再 install，同理。

### 待办：按人隔离的长期记忆

需求：**长期记忆按人分开**，短期不用管（会话本身隔离 + 有 openid）。

已确认的事实：

- 同一个人在**群聊和私聊拿到的 openid 是同一个值**（实测 `40A86F78...`），
  所以「跨群聊 / 个人会话认人」不需要 ID 映射表，直接用 openid 当分区键
- 官方 bundle 里**没有任何 memory 相关条目**（`dsh-base` / `dsh-web-app` 都查过）
- `meow-memory` 是工作区级共享，schema 只有 `disabledWorkspaces`，
  **没有按人分区的字段**；表结构也没有用户 ID 列
- npm 上有第三方跨会话记忆包（`dsh-mem` / `@tom2012/dsh-memory` /
  `dsh-workspace-recollection` 等），但描述里都是「单 store」或「按工作区隔离」，
  **没有一个直接按人分区**

进行到一半的两个阻塞点（下次接着做）：

1. `pnpm add` 会卡在构建脚本审批 —— `pnpm-workspace.yaml` 需要
   ```yaml
   onlyBuiltDependencies:
     - meow-memory
   ```
2. 补上之后重跑 `pnpm add dsh-mem`，看它的 store 是不是 JSON 单文件；
   能按 openid 分就直接配，不能就在上面加一层分区：
   `data/personas/<openid>/memory.json`，对话时按当前消息里的 openid 取对应的那份

配套还差一步：私聊消息现在**不带身份**（`buildUserMessage` 里
`if (!isGroup) return quotePart+userContent`），得加个 hunk 让它也拼上
`[昵称 (openid)]`，否则私聊里拿不到 openid 做分区键。

`data/profiles/qqbot/cordis.patch.yml` 是渲染后的实际配置，**可以直接改**。
`entrypoint.sh` 只在文件不存在时才从模板渲染，不覆盖你的修改。

想重新从模板渲染（模板更新后）：

```bash
DSH_RENDER_FORCE=1 docker compose up -d
```

---

## 关键实现说明

### 为什么 DSH_HOME 不能整体挂载

Docker Desktop 在 Windows/macOS 上用 9p / virtiofs 挂载，**挂载点本身无法 chmod**：

```
chmod: changing permissions of '/home/node/.dsh': Operation not permitted
```

而 `@deepseek-ai/dsh-attachment-local` 的 `ensureDurableDirectory()` 需要把
`DSH_HOME/attachments/v1` 及其**所有上级目录** chmod 成 700。最顶层正好是挂载点，
于是每次 `qqbot_describe_image` 都在读图之前炸 `EPERM` —— 机器人永远看不到图片。

**所以只挂子目录**（profiles / storages / sessions / proactive），
让 `DSH_HOME` 本身是容器内真实目录。

### 为什么 web 端口要经过 socat

`dsh web` 拒绝绑定 `0.0.0.0`：

```
--host 0.0.0.0 is intentionally not supported yet for safety:
it would expose remote code execution to the network
```

这个限制是对的（容器里的 AI 能执行任意命令），不绕过。
所以：web 绑容器内 `127.0.0.1:8765` → socat 转发到 `0.0.0.0:8766`
→ Docker 映射到**宿主机 `127.0.0.1:8766`**（只有本机能访问）。

### QQ 插件补丁

`image/patch/` 里是对 `@tencent-connect/dsh-qqbot` 的 pnpm patch，
作用是**拦掉「纯内部任务」的轮次**。

背景：有些插件会往会话里塞一条 user 消息触发整轮（meow-memory 的记忆反思、
外部记忆库提示等）。模型照常产出回复，QQ 插件再无条件发出去 —— 用户看到的是
「记好了，本鱼这次确实动了脑子：profile 配置的分层方式…」，像机器人在暴露日志。

判定逻辑：

```
本轮有 plugin:* 消息 + 本轮没有真人消息  →  拦截（纯内部任务）
本轮有真人消息                         →  发送（不管有没有插件消息）
```

**不是整轮一刀切**，因为同一轮可能既有插件提示、又有真人的图片。

补丁走 `pnpm patch` 机制（`patchedDependencies` 声明在 `pnpm-workspace.yaml`），
**插件升级后 pnpm 会自动重新应用**，不用手工改 `node_modules`。
升级 QQ 插件版本后需要重新生成补丁。

---

## 资源占用

| 项 | 默认 | 说明 |
|---|---|---|
| CPU | 3 核 | `DSH_CPUS` |
| 内存 | 4 GiB | `DSH_MEM` |
| 进程数 | 2048 | 防 fork 炸弹 |
| 日志 | 20MB × 3 | 自动轮转 |

实测稳态：空载约 150-200 MB。
