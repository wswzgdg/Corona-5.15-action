#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 本地顺序构建所有管理器
# 用法: ./run_all.sh [额外参数...]
# 额外参数会透传给 common.sh（如内核后缀、SUSFS 开关等）
EXTRA_ARGS=("$@")

for mgr in resukisu sukisu ksunext ksu kowsu; do
  echo "=== 构建管理器: $mgr ==="
  "$SCRIPT_DIR/common.sh" "$mgr" "${EXTRA_ARGS[@]}"
done