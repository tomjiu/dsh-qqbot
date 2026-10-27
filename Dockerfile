# ════════════════════════════════════════════════════════════════════
#  DSH + QQ Bot 一体镜像
#
#  设计取舍
#  ─────────────────────────────────────────────────────────────────
#  1. bookworm-slim 而非 alpine
#     glibc 兼容性好，numpy/pandas/Playwright 的预编译轮子直接可用；
#     alpine 上 numpy 要现编译几分钟。
#
#  2. 非 root 运行
#     容器里跑的是能执行任意 shell 的 AI，不该给它 root。
#     复用官方的 node 用户（uid/gid 1000），不另建。
#
#  3. 插件在构建期就装进 profile
#     运行时只做「配置模板 → 实际配置」的渲染，不联网装包。
#     镜像换机器、重建容器都不用重装。
#
#  4. QQ 插件补丁走 pnpm patch
#     不用手工改 node_modules（重装即失效）。
#     patches/*.patch + pnpm-workspace.yaml 的 patchedDependencies
#     让 pnpm 在每次 install 时自动重新应用。
#
#  5. 数据目录与镜像分离
#     /home/node/.dsh 必须是容器内真实目录（Docker Desktop 的 9p
#     挂载点无法 chmod，会让 dsh-attachment-local 的 ensureDurableDirectory
#     失败，表现为 qqbot_describe_image 报 EPERM）。所以只挂子目录。
# ════════════════════════════════════════════════════════════════════
FROM node:22-bookworm-slim

ARG DSH_VERSION=0.2.1-rc.2
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_REGISTRY=https://registry.npmmirror.com \
    NODE_ENV=production

# ── 1. 系统依赖 ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git openssh-client \
        build-essential pkg-config \
        python3 python3-pip python3-venv \
        ripgrep jq unzip zip less file vim-tiny \
        procps tzdata locales sudo socat zstd gettext-base \
        iproute2 net-tools tini \
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
        libdrm2 libdbus-1-3 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 \
        xdg-user-dirs \
    && sed -i 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# ── 2. 用户（复用官方 node 用户，uid/gid 1000）──────────────────────
RUN set -eux; \
    if ! getent passwd "${UID}" >/dev/null; then \
        groupadd -g "${GID}" app; \
        useradd -m -u "${UID}" -g "${GID}" -s /bin/bash app; \
    fi; \
    APP_USER="$(getent passwd "${UID}" | cut -d: -f1)"; \
    mkdir -p /workspace /home/${APP_USER}/.dsh /opt/dsh; \
    echo "${APP_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${APP_USER}; \
    chmod 0440 /etc/sudoers.d/${APP_USER}; \
    chown -R "${UID}:${GID}" /workspace /home/${APP_USER} /opt/dsh

# ── 3. DSH + pnpm ─────────────────────────────────────────────────
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" pnpm@10 \
    && npm cache clean --force \
    && dsh --version && pnpm --version

# ── 4. Python 常用库 ──────────────────────────────────────────────
RUN python3 -m pip install --no-cache-dir --break-system-packages \
        requests httpx beautifulsoup4 lxml pandas numpy matplotlib

# ── 5. 镜像资源（配置模板 / 补丁 / 脚本）────────────────────────────
# 全部放在 /opt/dsh，运行时只读，不参与持久化
COPY --chown=1000:1000 image/ /opt/dsh/image/

# ── 6. 预置 profile（构建期装插件，运行期只渲染配置）────────────────
#
# 为什么在构建期做：
#   - 运行时不需要网络装包，启动快、可离线
#   - 插件版本固化，镜像可复现
#   - 换机器就是 pull + run
USER 1000:1000
ENV HOME=/home/node \
    DSH_HOME=/home/node/.dsh \
    PATH=/home/node/.local/bin:${PATH}

WORKDIR /workspace

# 6a. 初始化 profile 并预置 pnpm 配置（patchedDependencies 必须在安装前就位，
#     否则 pnpm 不会应用补丁）
RUN set -eux; \
    P="${DSH_HOME}/profiles/qqbot"; \
    mkdir -p "$P/patches"; \
    cp /opt/dsh/image/profiles/pnpm-workspace.yaml "$P/pnpm-workspace.yaml"; \
    cp /opt/dsh/image/patch/*.patch "$P/patches/"; \
    printf '%s\n' \
      '{' \
      '  "name": "dsh-profile-qqbot",' \
      '  "private": true,' \
      '  "dsh": { "profile": { "bundles": [' \
      '    "@deepseek-ai/dsh-base",' \
      '    "@tencent-connect/dsh-qqbot",' \
      '    "dsh-persona-dafeiyu",' \
      '    "dsh-proactive",' \
      '    "meow-memory"' \
      '  ] } }' \
      '}' > "$P/package.json"

# 6b. 装插件（含补丁）
RUN set -eux; \
    cd "${DSH_HOME}/profiles/qqbot"; \
    CI=true pnpm add \
        "@tencent-connect/dsh-qqbot@0.5.2" \
        dsh-persona-dafeiyu \
        dsh-proactive \
        meow-memory \
        "dsh-speak-up@github:Yuuyuko-uu/dsh-speak-up"; \
    pnpm store prune || true

# 6c. 本地插件（不是 npm 包，拷进 profile 的 plugins 目录）
RUN set -eux; \
    P="${DSH_HOME}/profiles/qqbot/plugins"; \
    mkdir -p "$P"; \
    cp -r /opt/dsh/image/plugins/worldbook "$P/worldbook"; \
    cp -r /opt/dsh/image/plugins/log-console "$P/log-console"; \
    cp -r /opt/dsh/image/plugins/config-sync "$P/config-sync"; \
    cp -r /opt/dsh/image/plugins/workspace-bootstrap "$P/workspace-bootstrap"

# 6d. 验证补丁确实应用了（构建期就失败，别等到运行）
RUN set -eux; \
    F="${DSH_HOME}/profiles/qqbot/node_modules/@tencent-connect/dsh-qqbot/dist/transport/outbound.js"; \
    grep -q "PATCH" "$F" || { echo "ERROR: qqbot patch not applied"; exit 1; }; \
    echo "patch verified"

# 6e. 保存一份 profile 骨架，供首次启动时铺到挂载目录
# 为什么需要：运行期 data/profiles 是宿主机 bind mount，会把镜像里的
# $DSH_HOME/profiles/qqbot 整个遮住。于是别人拿到镜像、建了空 data 目录
# 之后，profile 根本不存在，启动直接报：
#
#   Error: dsh: profile "qqbot" does not exist;
#          create it with 'dsh plugin --profile qqbot add <package>'
#
# 机器人根本起不来。entrypoint 会用这里存的骨架在首次启动时补齐。
RUN set -eux; \
    mkdir -p /opt/dsh/image/skeleton; \
    cp -a "${DSH_HOME}/profiles/qqbot" /opt/dsh/image/skeleton/qqbot; \
    rm -rf /opt/dsh/image/skeleton/qqbot/cordis.patch.yml; \
    printf '# dsh profile root — an empty entry list.\n[]\n' \
        > /opt/dsh/image/skeleton/qqbot/cordis.yml; \
    du -sh /opt/dsh/image/skeleton/qqbot

# ── 7. 入口 & 辅助命令 ────────────────────────────────────────────
USER root
RUN set -eux; \
    chmod +x /opt/dsh/image/scripts/*.sh; \
    chmod +x /opt/dsh/image/scripts/*.mjs; \
    ln -sf /opt/dsh/image/scripts/dsh-ctl.sh /usr/local/bin/dsh-ctl; \
    ln -sf /opt/dsh/image/scripts/dsh-ctl.sh /usr/local/bin/dsh-url; \
    ln -sf /opt/dsh/image/scripts/dsh-ctl.sh /usr/local/bin/dsh-relogin; \
    ln -sf /opt/dsh/image/scripts/dsh-ctl.sh /usr/local/bin/dsh-status; \
    ln -sf /opt/dsh/image/scripts/dsh-add-alarm.sh /usr/local/bin/dsh-add-alarm; \
    ln -sf /opt/dsh/image/scripts/dsh-test.sh /usr/local/bin/dsh-test; \
    ln -sf /opt/dsh/image/scripts/dsh-model.sh /usr/local/bin/dsh-model; \
    ln -sf /opt/dsh/image/scripts/dsh-render.sh /usr/local/bin/dsh-render; \
    chown -R 1000:1000 "${DSH_HOME}"

USER 1000:1000
WORKDIR /workspace
EXPOSE 8766

# tini 做 PID 1：正确转发信号、回收僵尸
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/dsh/image/scripts/entrypoint.sh"]



