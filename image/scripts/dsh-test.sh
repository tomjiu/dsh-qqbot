#!/usr/bin/env bash
# 运行全部单元测试
#
# 用法（容器内）：dsh-test
#
# 覆盖：
#   test-trigger.mjs     群聊触发策略（三档：@ / 重点人员 / 其他人）
#   test-concurrency.mjs 连发消息合并（内容 / envelope / 附件不丢）
#
# 这些测试直接调用真实的中间件代码 + 构造的 ctx，
# 不需要真人发消息，可重复执行，改动回归时第一时间暴露。
set -Eeuo pipefail

PROFILE_DIR="${DSH_HOME:-/home/node/.dsh}/profiles/${QQ_PROFILE:-qqbot}"
TESTS_SRC="/opt/dsh/image/scripts"
TOTAL_RC=0

cd "$PROFILE_DIR"

# 测试脚本优先用镜像里的副本（保证与镜像版本一致），
# profile 目录里的那份是开发期手工放的。
run_one() {
    local name="$1"
    local src="$TESTS_SRC/$name"
    local dst="$PROFILE_DIR/$name"
    [ -f "$src" ] && cp "$src" "$dst"
    if [ ! -f "$dst" ]; then
        echo "  ✗ $name 不存在（$src）"
        TOTAL_RC=1
        return
    fi
    echo
    echo "══════════════════════════════════════════"
    echo "  $name"
    echo "══════════════════════════════════════════"
    if node "$dst"; then
        echo "  → $name 通过"
    else
        echo "  → $name 失败"
        TOTAL_RC=1
    fi
}

echo "工作目录: $PROFILE_DIR"
run_one "test-trigger.mjs"
run_one "test-concurrency.mjs"

echo
echo "══════════════════════════════════════════"
if [ "$TOTAL_RC" -eq 0 ]; then
    echo "  全部测试通过"
else
    echo "  有测试失败"
fi
echo "══════════════════════════════════════════"
exit "$TOTAL_RC"
