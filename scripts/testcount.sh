#!/usr/bin/env bash
# 统计真实的测试总数。
#
# 为什么需要这个脚本：`swift test` 对**每个 test target 各打一行 summary**，
# 只看最后一行会把单个 target 的数字误当成总数（曾因此把 305 误报为 174）。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$DIR/env.sh" >/dev/null 2>&1

cd "$PRISM_ROOT" || exit 1
OUTPUT="$(swift test --disable-sandbox --cache-path "$PRISM_SWIFT_CACHE_PATH" 2>&1)"
STATUS=$?

echo "$OUTPUT" | grep -E 'Test run with' | sed 's/^/  /'
echo
TOTAL="$(echo "$OUTPUT" | grep -oE 'Test run with [0-9]+ test' | grep -oE '[0-9]+' | paste -sd+ - | bc)"
echo "真实总数: ${TOTAL:-0} 个测试"
exit $STATUS
