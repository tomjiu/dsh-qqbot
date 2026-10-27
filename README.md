# DSH + QQ Bot

把 DeepSeek Harness 装进容器，接一个官方 QQ 机器人，让她在群里像群友一样聊天，
同时能在容器里真正干活（跑代码、改文件、执行命令）。

- **单进程**：Web UI 和 QQ 机器人跑在**同一个 dsh 宿主**里。QQ 会话在 Web 里能直接看到、
  换模型、接着聊 —— 这不是靠配置同步，是共用一份内存里的会话表
- **QQ 接入**：腾讯官方 `@tencent-connect/dsh-qqbot`，走 QQ 开放平台 Bot API v2
  —— 不是第三方协议端，没有封号风险
- **人格**：`dsh-persona-dafeiyu` 人设库 + 酒馆式世界书，可切换、可导入
- **记忆**：`meow-memory` 七层 SQLite 长期记忆
- **主动说话**：`dsh-proactive` 宿主级定时唤醒（能唤醒冷会话）
- **干活**：容器里 python / node / git / gcc 齐全，沙箱放开，AI 能真正操作

**镜像**：`mingjiu/dsh-qqbot:latest`（[Docker Hub](https://hub.docker.com/r/mingjiu/dsh-qqbot)）
**源码**：[github.com/tomjiu/dsh-qqbot](https://github.com/tomjiu/dsh-qqbot)

---

## 快速开始

### 方式一：docker compose（推荐）

```bash
git clone https://github.com/tomjiu/dsh-qqbot.git
cd dsh-qqbot

cp .env.example .env
# .env 里**只需要** QQ 凭据，两种都可以：
#   A. 留空 —— 启动后在 Web 里扫码
#   B. 填 QQBOT_APPID / QQBOT_SECRET

docker compose up -d      # 直接拉预构建镜像，秒级
docker compose logs -f dsh
```

> 镜像在 Docker Hub：https://hub.docker.com/r/mingjiu/dsh-qqbot
> 标签：`latest` / `0.1.0`。
> 想自己从源码构建就加 `--build`（约 10-15 分钟，装系统依赖比较慢）。

### 方式二：直接 docker run

无需 compose、无需任何环境变量：

```bash
mkdir -p data/{profiles,storages,sessions,proactive,trusted-workspaces,qqbot-prefs} workspace
# 这两个必须先建成空文件，否则 Docker 会把它们当目录创建
touch data/credentials.yaml data/qqbot-credentials.json

docker run -d --name dsh \
  -p 127.0.0.1:8766:8766 \
  -v $PWD/workspace:/workspace \
  -v $PWD/data/profiles:/home/node/.dsh/profiles \
  -v $PWD/data/storages:/home/node/.dsh/storages \
  -v $PWD/data/sessions:/home/node/.dsh/sessions \
  -v $PWD/data/proactive:/home/node/.dsh/proactive \
  -v $PWD/data/trusted-workspaces:/home/node/.dsh/trusted-workspaces \
  -v $PWD/data/qqbot-prefs:/home/node/.dsh-qqbot \
  -v $PWD/data/credentials.yaml:/opt/dsh/state/credentials.yaml \
  -v $PWD/data/qqbot-credentials.json:/opt/dsh/state/qqbot-credentials.json \
  mingjiu/dsh-qqbot:latest
```

### 启动后

日志里会依次出现：

```
──────────────────────────────────────
[12:00:00] DSH container (single host: web + qqbot)
[12:00:00]   dsh      : 0.2.1-rc.2
[12:00:00]   web      : (container :8765 -> host :8766)
──────────────────────────────────────
[12:00:20] WEB UI READY
[12:00:20]   http://127.0.0.1:8766/?token=xxxxxxxx
```

**点开这个带 token 的地址就能进 Web UI。**

### 第一步：填模型 API key

⚠️ **不填 key 时 Web 的模型页是空的（0 个服务商），机器人也发不出消息。**

打开 Web UI → 设置 → 模型 → 找到 **DeepSeek**（`dsh-base` 内置，不需要手动加）
→ 填 API key → 保存。

想用别家就在同一页「添加模型提供商」。改完 QQ 那边**下一次对话立刻跟随** ——
因为两边是同一个进程、同一份配置。

---

## QQ 扫码绑定

凭据缺失时（`.env` 里 `QQBOT_APPID` 留空），机器人以未绑定态启动，两条通道同时可用：

**方式一（推荐）Web 端内绑定页**

打开 Web UI → 侧栏「QQ Bot 绑定」，端内直接渲染二维码 + 实时状态。
**扫完立即生效，不需要重启容器** —— 这是单进程架构的收益：QQ 插件能拿到
`webServer` 注入，绑定页路由（`/qqbot/im-qqbot/bind`）才会注册。
旧版 qqbot 是独立 profile、没有 webServer，这个页面**从来没出现过**。

**方式二 终端二维码（降级通道）**

```
[main] ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
[main] █ ▄▄▄▄▄ █ ▀▄▀▄ █▀▀ █ ▄▄▄▄▄ █
[main] （用手机 QQ 扫这个码）
```

重新扫码：

```bash
docker compose exec dsh dsh-ctl relogin
```

---

### 扫码时的三个坑

**1. 不要点「刷新二维码」**

每次刷新都会调用 `create_bind_task` 新建一个任务，旧的立刻作废。
如果你扫的是旧码，凭据会写到已作废的任务上，插件早就不轮询它了 ——
表现就是「扫了没反应」。

**2. 扫完停在页面上别动**

等它自己变成 bound，中间别刷新页面、别重复扫。

**3. 频率限流是静默的**

腾讯对 `poll_bind_result` 有限流（`retcode 30012`）。上游插件的处理是：

```js
try { t = await poll() } catch { await sleep(2000); continue }   // ← 吞掉了
```

所以触发限流时你**什么都看不到**，只是卡住。等 30 秒再试即可。

> 如果扫码一直卡：`docker compose restart dsh` 拿到全新任务，
> 然后**只扫页面上最新那张**。

---

## 版本与上游兼容性

### 锁定的版本

| 依赖 | 版本 | 位置 |
|---|---|---|
| `@deepseek-ai/dsh` | `0.2.1-rc.2` | `Dockerfile` 的 `ARG DSH_VERSION` |
| `@tencent-connect/dsh-qqbot` | `0.5.3` | `Dockerfile` + `image/profiles/pnpm-workspace.yaml` |
| QQ 插件补丁 | `patches/@tencent-connect__dsh-qqbot@0.5.3.patch` | `image/patch/` |

### ⚠️ 我们跑在未验证的组合上

上游 `dsh-qqbot` 的 `package.json` 只声明了两组验证过的组合：

```json
"compatibility": {
  "dshReleases": {
    "0.1.0-rc.8": "compatible",   // CLI（dsh web）已验证
    "0.2.0-rc.2": "compatible"    // Desktop 内嵌运行时已验证
  }
}
```

**我们用的是 `0.2.1-rc.2`，不在这个矩阵里。** 实际跑起来是正常的（22 项自检全过），
但这是「实测通过」而不是「上游背书」。

升级 dsh 版本时要注意：

1. **重跑 `./check.sh`** —— 它会重新构建并做全新环境自检
2. **客户端席位可能变** —— 上游 note 里写明，绑定页依赖
   `settings.section` / `sidebarRightTabs` / `sidebar.right.pane.tab` 席位契约，
   **宿主大版本升级后要重新验收这些 UI 入口**（打开 Web，确认侧栏有「QQ Bot 绑定」）
3. **插件补丁要重新生成** —— 见下

### 升级 `dsh-qqbot` 时怎么重新生成补丁

补丁改的是 `dist/` 里的编译产物，**插件版本一变就必须重生成**，否则 pnpm 打不上。

```bash
# 1. 拉新版本的 tarball，解出 dist
npm pack @tencent-connect/dsh-qqbot@<新版本>
tar -xzf tencent-connect-dsh-qqbot-*.tgz

# 2. 复制成两份 a/ b/，只在 b/ 里重放这 5 处改动：
#      dist/config.js          + vipSenders 字段
#      dist/gateway/middleware-setup.js   三档触发策略
#      dist/transport/events.js           user/message 的 sourceKind
#      dist/transport/inbound.js          vipTrigger + 群历史
#      dist/transport/outbound.js         纯内部轮次拦截
#    改动内容参照 image/patch/ 里旧补丁的 hunk 注释

# 3. 生成补丁（路径前缀必须是 a/dist/... 与 b/dist/...）
git diff --no-index --src-prefix=a/ --dst-prefix=b/ a/dist b/dist > raw.patch
sed -E 's#^diff --git a/a/dist/(.*) b/b/dist/(.*)$#diff --git a/dist/\1 b/dist/\2#' raw.patch \
  | sed -E 's#^--- a/a/dist/#--- a/dist/#' \
  | sed -E 's#^\+\+\+ b/b/dist/#+++ b/dist/#' \
  > image/patch/@tencent-connect__dsh-qqbot@<新版本>.patch

# 4. 同步三处版本号
#    Dockerfile 的 pnpm add 那一行
#    image/profiles/pnpm-workspace.yaml 的 patchedDependencies
#    删掉旧补丁文件

# 5. 验证
./check.sh
```

构建期有硬校验：补丁没打上或 profile 组合缺条目，**构建直接失败**。

### 为什么钉死版本而不跟随 latest

`dsh-qqbot` 是官方在快速迭代的插件，`0.5.2 → 0.5.3` 之间就有 3 个被我们 patch 的文件
发生了实质变化（`config.js` +6 行、`events.js` +50 行、`outbound.js` +122 行）。
跟着 latest 走意味着每次升级都要重生成补丁并重测，不适合自动跟随。

需要升级时：手动执行上面的流程，跑 `./check.sh` 通过后再改版本号。

---
## 常见故障对照表

这张表里的每一条都是实际踩过的，不是推测。

| 现象 | 根因 | 怎么查 / 怎么修 |
|---|---|---|
| 输入框点不了、模型切不了、新建会话失败 | `subagent-model-selection-settings` 配了 `enabled: true` 但 `allowedModels: []`，上游在建会话时抛错 | 看 `cordis.patch.yml` 里该项是否为 `enabled: false`。模板已改成按 `DSH_SUBAGENT_MODELS` 自动切换 |
| 日志一片空白，报障无从下手 | `log-console` 插件缺失。`ctx.logger` 没有 exporter 时**静默丢弃** | 日志里应出现 `[log-console] 已启用`。`dsh-verify` 会检查 |
| 扫码成功但一直卡在「连接中」/ `phase: saving` | HMR 没工作。两个前提缺一不可：① `--expose-internals`；② bind mount 下必须 `usePolling` | `dsh-launch` 保证 ①；模板保证 ②。`./check.sh` 会校验这两条 |
| 扫码后配置被清空 / 注释全没了 | 上游 `persist.js` 用 `yaml.dump()` 整体覆盖 `cordis.patch.yml` | `credential-guard` 插件会自动恢复。查 `/tmp/credential-guard.log` |
| 机器人看不到图片 | `vision.provider` / `vision.model` 未填（**两者都是必填**，缺一个就不注册工具，只留一行 warn） | 日志应有 `qqbot_describe_image 工具已注册` |
| 容器起不来，日志只有 `unbound variable` | 用 `docker run` 且没传环境变量，脚本 `set -u` 直接退出 | 已在 `render-profile.sh` 顶部加默认值，新版不会了 |
| Web 模型页一个服务商都没有 | 还没填 API key | 设置 → 模型 → DeepSeek → 填 key |
| QQ 里没反应但日志显示已处理 | `requireMention: true` 且群里没人 @ 她 | 这是设计行为。群聊「三档策略」见下 |

### 自检脚本

```bash
docker compose exec dsh dsh-verify
```

19 项断言，覆盖：profile 组合是否完整、是否只有一个宿主进程、
关键配置项是否正确、已下线插件是否清干净、绑定页是否真的注册了。
**任何一项失败都说明架构退化了**，不只是配置写错。

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
│   ├── plugins/worldbook/    世界书引擎（唯一的自写插件）
│   └── patch/                QQ 插件补丁（pnpm patch 格式）
├── data/                     ← 运行时持久化
│   ├── profiles/main/        唯一的 profile（Web + QQ 共用）
│   ├── storages/             工作区注册表等
│   ├── sessions/             会话记录
│   └── proactive/            定时闹钟
└── workspace/                ← AI 的工作区（你的代码）
```

### 只有一个 profile

`data/profiles/main/` 同时承担 Web UI 和 QQ 机器人。它在 `package.json`
里声明的 bundles 是：

```
@deepseek-ai/dsh-base      核心（会话、工具、模型适配器、凭据存储）
@deepseek-ai/dsh-web-app   Web 表面（webserver、session-controller、前端）
@tencent-connect/dsh-qqbot QQ 通道
dsh-persona-dafeiyu        人设库
dsh-proactive              主动说话
meow-memory                长期记忆
```

`dsh-web-app` **必须在** `dsh-base` 之后（它是叠加在 base 上的补丁层）。
`im-qqbot` 和 `webserver` 在**同一棵树**里，这是全部收益的来源。

## 维护命令

容器内：

```bash
docker compose exec dsh dsh-ctl url        # 打印 Web 地址（含 token）
docker compose exec dsh dsh-ctl status     # 进程 / 端口 / 地址
docker compose exec dsh dsh-ctl logs web   # 跟踪某个服务的日志
docker compose exec dsh dsh-ctl relogin    # 清除 QQ 凭据准备重新扫码
docker compose exec dsh dsh-ctl restart    # 重启 qqbot（不重建容器）
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

## 改完东西后：跑 check.sh

```bash
./check.sh              # 完整：静态检查 + 构建 + 全新环境自检（约 3 分钟）
./check.sh --no-build   # 跳过构建（改文档 / 改配置时）
./check.sh --fast       # 只做静态检查，不碰 Docker（秒级）
```

**为什么必须有这个**：这个仓库里反复出现「改了 A，忘了同步 B」——
删了 `log-console` 以为不需要（结果日志全静默）、删了 `vision.provider/model`
以为能继承（结果读图功能消失）、新增插件忘了加白名单（自检假失败）。
这些**都不会让构建报错**，只在运行时悄悄退化。

22 项检查覆盖：

| 类别 | 查什么 |
|---|---|
| 语法 | 所有 `.sh` / `.js` / 模板 YAML |
| 关键内容 | `log-console` 在位、`vision.provider/model` 已填、子智能体用动态 `enabled`、`dsh-launch` 带 `--expose-internals` |
| 危险写法 | 有没有插件在整体重写 `cordis.patch.yml` |
| 构建 | 镜像能否构建（含补丁与组合校验） |
| 运行时 | 全新空目录能否启动、`dsh-verify` 是否全过、**启动日志是否零 warn** |

> 「零 warn」这一项很重要：这次的三个大坑（读图未注册、子智能体配置、
> `vision` 路由）在日志里都只有**一行 warn**，很容易被忽略。

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
[20:46:25]     - profile 配置 YAML 语法错误（检查 data/profiles/main/cordis.patch.yml）
```

**真实原因就在日志尾部**，修好后 `docker compose restart dsh`。

---

## 配置说明

### 模型服务商

**全部在 Web 设置页里配**：`http://127.0.0.1:8766` → 设置 → 模型。

- **DeepSeek 官方**卡片是 `dsh-base` 内置的（路由 `deepseek-official`），
  填个 API key 就能用，**不需要手动添加服务商**
- 要用别家（OpenAI / Anthropic / Kimi / 通义 …）就点「添加模型提供商」，
  42 个内置服务商的 baseUrl、模型表、上下文窗口都在目录里，选一个填 key 即可
- 要接中转站／自建网关就选「自定义模型 API」

**API key 存在 `~/.dsh/.credentials.yaml` 里，不在任何配置文件里。**
Web 模型页把 key 以只写方式存进凭据服务，`cordis.patch.yml` 只记引用名
（`apiKeyEnv`）。所以**永远不需要把 key 写进 `.env`**。

因为 Web 和 QQ 是同一个进程，改完**下一次对话立刻生效**，不需要重启、没有任何同步机制。

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
docker compose exec dsh bash -lc 'zstd -d -c ~/.dsh/sessions/-workspace-/*/session.v4.jsonl.zstd | grep -o "\[.* ([0-9A-F]\{32\})\]" | head -3'
```

### 模型：只有一个真源

**Web 和 QQ 机器人是同一个进程，用同一份模型配置。**

打开 `http://127.0.0.1:8766` → 设置 → 模型：加服务商、填 API key、选模型。
在 Web 顶部选择器里换模型，**QQ 那边下一次对话立刻用新的**，不用重启、不用改文件。

为什么现在这么简单：

```
一个 dsh 宿主
  ├─ Web UI        ← 会话列表、模型选择器、直接对话
  └─ im-qqbot 插件 ← 收发 QQ 消息
```

旧版是 `dsh web` 和 `dsh --profile qqbot` **两个独立进程**，各有一份内存里的
会话表和配置。为了让它俩一致，旧版需要：

| 旧版的东西 | 为什么现在不需要了 |
|---|---|
| `config-sync` 插件（每 5 秒抄配置） | 同一进程，本来就是同一份 |
| `dsh-model` 脚本（改 web profile 再等同步） | Web 顶部选择器直接写 `agent-default-model` |
| `model-fallback` 插件（降级链） | 已移除，见下 |

#### 默认模型怎么解析

qqbot 插件留空了 `provider`/`model`（它自带的 bundle patch 就是这么设计的，
注释写明「从宿主默认模型路由继承」）。运行时走：

```
per-peer /model 偏好  >  cordis.patch.yml 的 agent-default-model  >  兜底
```

那个 `agent-default-model` 就是 **Web 顶部选择器写的同一行**，所以：

- 你在 Web 里换模型 → QQ 立刻跟随
- 你在 QQ 里发 `/model` → 只改那个 peer 的偏好，不影响 Web
- 路由选择阶段**不检查密钥**，所以「默认模型没填 key」不会报错，只会真的调不通

#### 没有自动降级链

旧版有个 `model-fallback` 插件：上游按**单个模型**做限流（code 6004）时，
自动切到下一个模型。**已移除**，理由：

- 它依赖 `DSH_SUBAGENT_MODELS` 那张表，而那张表来自 `.env`、模型表来自 Web，
  两者天然会漂移，需要额外逻辑跳过悬空条目
- 上游 `dsh-llm-retry` 已经处理重试；跨 provider 的换模型确实没有原生方案

需要兜底就在 Web「设置 → 模型」里配多个服务商，自己手动切换。
或者重新引入一个只监听 `agent/request` 失败事件的小插件 —— 但请先想清楚
它怎么拿到「当前可用模型表」。

**思维链不会漏到 QQ**：`outbound.js` 只取 `content` 里 `type === 'text'` 的块，
`reasoning_content` 是独立字段，不会被发送。

### 工作区

**QQ 的会话会自动归到 `/workspace` 这个工作区下，不需要任何插件。**

原因在 `dsh-api-session-controller` 里：Web 打开/新建会话时，除了写
`workspace.json`，还会调 `workspace.attachSession(sessionId)`，用会话
header 里的 `cwd` 校验后挂进工作区。

旧版之所以要 `workspace-bootstrap` 插件，是因为 QQ 的会话建在**另一个进程**里，
那个进程压根没有 `workspaceRegistry`。合并成一个宿主后，Web 侧栏里
QQ 会话和手动开的会话就是同一类东西。

### 子智能体

```bash
DSH_SUBAGENT_MAX_DEPTH=3        # 递归层级：子智能体再派子智能体，最多几层
DSH_SUBAGENT_MAX_PARALLEL=4     # 同时最多跑几个
```

`DSH_SUBAGENT_MODELS` 是子智能体的模型授权表 ——
主 Agent 可以按这张表为每个子智能体挑模型、推理强度。**它不是降级链。**

### 子智能体

```bash
DSH_SUBAGENT_MAX_DEPTH=3        # 递归层级：子智能体再派子智能体，最多几层
DSH_SUBAGENT_MAX_PARALLEL=4     # 同时最多跑几个
```

`DSH_SUBAGENT_MODELS` 同时充当子智能体的模型授权表 ——
主 Agent 可以按这张表为每个子智能体挑模型、推理强度。

### ⚠️ 别删 `data/profiles/main/patches/`

`package.json` 里的 `pnpm.patchedDependencies` 指向这个目录。删了之后
任何 `pnpm add` / `pnpm install` 都会直接报：

```
ENOENT: no such file or directory, open
  '.../profiles/main/patches/@tencent-connect__dsh-qqbot@0.5.3.patch'
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

`data/profiles/main/cordis.patch.yml` 是渲染后的实际配置，**可以直接改**。
`entrypoint.sh` 只在文件不存在时才从模板渲染，不覆盖你的修改。

想重新从模板渲染（模板更新后）：

```bash
DSH_RENDER_FORCE=1 docker compose up -d
```

---

## 为什么 HMR 要开 usePolling

**Docker Desktop（Windows / macOS）的 bind mount 不会把 inotify 事件传进容器。**

实测（同一容器、同一文件）：

```
chokidar 默认（inotify）→ 写入后 5 秒内收到 0 个事件
chokidar usePolling   → 立刻收到 EVENT: change
```

不开 polling，HMR 连文件变化都感知不到，配置改了永远不生效。

所以 `cordis.patch.yml` 里强制写了：

```yaml
- id: hmr
  config:
    usePolling: true    # bind mount 必需
    interval: 1000      # 每 1 秒 stat 一次
```

代价：每秒 stat 一次配置文件和目录（几百微秒），可忽略。

> `@deepseek-ai/dsh-hmr` 的 Config schema 是 `z.object({ base, root, ignored, debounce })`，
> **没有** `usePolling` 字面量 —— 但 schemastery 会保留未知字段，
> 而 dsh-hmr 把 `this.config` 用 `...watchOptions` 原样透传给 chokidar，所以能生效。
> 实测验证过：`{ usePolling: true, interval: 1000 }` 完整存在于解析结果里。

### ⚠️ 验证热重载时别用错字段

排查这段时踩过一个坑：改 `tools.maxParallelSubCalls: 10 → 8`，等 15 秒看日志没反应，
就误判成「HMR 坏了」。

**实际上 HMR 一直是好的。** 加探针后看到：

```
[HMR-PROBE] profileContext: OK
[HMR-PROBE] appReady: OK
[HMR-PROBE] watchConfig: .../cordis.patch.yml
[HMR-PROBE] refresh fired
[HMR-PROBE] reconcile: {"warnings":[],"pending":[]}    ← 零警告，重载成功
```

问题在于 **`reconcileProfile()` 成功时不打日志**（只有 warn/error 才打），
而且部分配置字段只在**创建 agent 时读取一次**，重载不会重建已存在的 agent。

想验证热重载是否工作，用下面任意一种：

| 方法 | 怎么看结果 |
|---|---|
| 改 `im-qqbot.groupPrompt` | 下一条 QQ 消息的人设立刻变 |
| 改 `hmr.interval` 再从 `8` 改回 `1000` | 两次都会有 `refresh fired` |
| 直接查 `cordis.patch.yml` 的 mtime 是否被 guard 回溯 | 证明写入链路通 |
| 扫码绑定 | 成功后 `phase` 从 `saving` 变 `bound` |

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