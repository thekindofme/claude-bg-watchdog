#!/usr/bin/env bash
# PreToolUse[Bash] — block flagrant foreground sleep-loop waits on async work.
# Audit 2026-07-24: 48% of all foreground Bash timeouts were hand-rolled
# while/until/for + sleep polls on builds/SFN/subagent-output. Those belong in
# run_in_background or the Monitor tool. Blocks only loops sleeping >=15s per
# iteration (remote polling cadence); short local waits pass through.
set -u

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)
bg=$(jq -r '.tool_input.run_in_background // false' <<<"$input" 2>/dev/null)

[ -z "$cmd" ] && exit 0
[ "$bg" = "true" ] && exit 0

if echo "$cmd" | grep -qE '(^|[;&|(\s])(while|until|for)[[:space:]]' \
   && echo "$cmd" | grep -qE '\bsleep[[:space:]]+(1[5-9]|[2-9][0-9]|[0-9]{3,})\b'; then
  echo "Blocked: foreground poll loop (loop + sleep>=15s) waiting on something async. Re-issue with run_in_background:true (single completion notification), or use the Monitor tool (streaming events; persistent:true for session-length watches; filter must match FAILURE states too, not just success). If this truly must run foreground, remove the loop and wait on the condition once with an explicit sized timeout." >&2
  exit 2
fi
exit 0
