#!/bin/zsh
# 跑 WKWebView harness 测试，带超时看门狗，只输出结果摘要。
#   macos/run-tests.sh                   全部测试，默认 300 秒超时
#   macos/run-tests.sh --filter 名称 120  只跑匹配的测试，120 秒超时
# 设置 MEDIACRAFT_TEST_LOG 为绝对路径时，完整日志写到那里并保留（CI 收集用）。
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

if [[ -n "${MEDIACRAFT_TEST_LOG:-}" ]]; then
  LOG="$MEDIACRAFT_TEST_LOG"
  if [[ "$LOG" != /* ]]; then
    echo "MEDIACRAFT_TEST_LOG 必须是绝对路径" >&2
    exit 64
  fi
  mkdir -p "$(dirname "$LOG")" || exit 1
else
  LOG="$(mktemp)" || exit 1
fi
# 用 setsid 让 swift test 自成一个进程组，超时时整组终止。
python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  swift test --no-parallel "${FILTER[@]}" > "$LOG" 2>&1 &
PID=$!

TIMED_OUT=0
TEST_DEADLINE=$((SECONDS + TIMEOUT))
while (( SECONDS < TEST_DEADLINE )); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  TIMED_OUT=1
  echo "⏱ 超过 ${TIMEOUT} 秒，终止本次测试"
  TEST_DESCENDANTS=($(descendants "$PID"))
  kill -TERM "${TEST_DESCENDANTS[@]}" "$PID" 2>/dev/null
  kill -TERM -- "-$PID" 2>/dev/null

  # swift 退出后 helper 可能被重新挂到系统进程；保留本次测试的子孙编号，仍只清理这一组。
  testProcessesAlive() {
    local descendant
    kill -0 "$PID" 2>/dev/null && return 0
    kill -0 -- "-$PID" 2>/dev/null && return 0
    for descendant in "${TEST_DESCENDANTS[@]}"; do
      kill -0 "$descendant" 2>/dev/null && return 0
    done
    return 1
  }
  TERM_DEADLINE=$((SECONDS + 10))
  while (( SECONDS < TERM_DEADLINE )) && testProcessesAlive; do
    sleep 1
  done
  TEST_KILL_TARGETS=($(descendants "$PID"))
  # helper 自建的进程组里，宽限期内新开的子进程也属于本次测试。
  for descendant in "${TEST_DESCENDANTS[@]}"; do
    if kill -0 "$descendant" 2>/dev/null; then
      TEST_KILL_TARGETS+=($(descendants "$descendant") "$descendant")
    fi
  done
  kill -KILL "${TEST_KILL_TARGETS[@]}" "$PID" 2>/dev/null
  kill -KILL -- "-$PID" 2>/dev/null
fi
wait "$PID"
STATUS=$?
if (( TIMED_OUT )); then STATUS=124; fi

LC_ALL=C sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error:|✘|↳|Test run with" | grep -vE "Target Platform|Testing Library Version" | sort -u
if [[ -z "${MEDIACRAFT_TEST_LOG:-}" ]]; then
  rm -f "$LOG"
else
  echo "完整测试日志：$LOG"
fi
exit "$STATUS"
