#!/bin/zsh
# 跑 WKWebView harness 测试，带超时看门狗，只输出结果摘要。
#   macos/run-tests.sh                   全部测试，默认 300 秒超时
#   macos/run-tests.sh --filter 名称 120  只跑匹配的测试，120 秒超时
# 超时只终止本次测试自己的进程组，不影响其他 worktree 里同时在跑的测试。
# 串行执行：多个 WKWebView 同时解码视频会互相卡死，全量并行跑会偶发挂起。
set -uo pipefail
cd "$(dirname "$0")"

FILTER=()
TIMEOUT=300
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) FILTER=(--filter "$2"); shift 2 ;;
    *) TIMEOUT="$1"; shift ;;
  esac
done

# 递归列出子孙进程（先子后父）。testing helper 会自建进程组，只杀进程组会漏掉它。
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    descendants "$child"
    echo "$child"
  done
}

LOG="$(mktemp)"
# 用 setsid 让 swift test 自成一个进程组，超时时整组终止。
python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  swift test --no-parallel "${FILTER[@]}" > "$LOG" 2>&1 &
PID=$!

for ((i = 0; i < TIMEOUT; i++)); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "⏱ 超过 ${TIMEOUT} 秒，终止本次测试"
  kill -TERM $(descendants "$PID") "$PID" 2>/dev/null
  kill -TERM -- "-$PID" 2>/dev/null
fi
wait "$PID"
STATUS=$?

sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error:|✘|↳|Test run with" | grep -vE "Target Platform|Testing Library Version" | sort -u
rm -f "$LOG"
exit "$STATUS"
