#!/usr/bin/env bash
# PreToolUse[Monitor] — DORMANT guard against arming Monitor where its
# notifications never arrive.
#
# Background. Transcript mining (2026-07-24 → 2026-08-12, 169 Monitor arms)
# found that arms made INSIDE subagent sidechains received zero notifications in
# 132/137 cases, while top-level arms delivered 31/32. Since 81% of all arms
# happen inside subagents (build/test watchers in implement flows), a silently
# dead watcher there is the dominant watcher failure mode.
#
# Why this hook is OFF by default. Live re-verification on CLI 2.1.228
# (2026-08-12, run from inside a real subagent sidechain) showed subagent
# delivery WORKING on all three paths: match event, timeout notice, and
# persistent-monitor events. See notes/monitor-subagent-delivery.md. The mining
# window therefore describes a bug that is fixed — or at least not reproducible
# on the current CLI — so blocking on it would deny a working tool.
#
# Enable only if subagent delivery regresses: set BG_WATCHDOG_MONITOR_GUARD=1
# (env, or "env" block in settings.json). Re-run the probes in the notes file
# before flipping it — the evidence, not the memory of the bug, decides.
set -u

input=$(cat)

# Defensive: only ever act on Monitor. If routed a different tool, allow.
tool=$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)
[ -n "$tool" ] && [ "$tool" != "Monitor" ] && exit 0

# Escape hatch: an explicit override token anywhere in the tool input lets the
# arm through even when the guard is enabled. Nothing is ever hard-impossible.
if jq -r '.tool_input // {} | tostring' <<<"$input" 2>/dev/null | grep -q 'MONITOR_GUARD_OVERRIDE'; then
  exit 0
fi

# Sidechain detection. Primary signal is transcript_path: a subagent's
# transcript lives at
#   ~/.claude/projects/<project>/<session-uuid>/subagents/agent-<agent_id>.jsonl
# verified against the real on-disk layout (2689 such files) and cross-checked
# against SubagentStop ledger rows whose agent_id matches the filename stem.
# Secondary signal is a populated agent_id/agent_type, which only sidechain hook
# inputs carry.
transcript=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
agent_id=$(jq -r '.agent_id // empty' <<<"$input" 2>/dev/null)
agent_type=$(jq -r '.agent_type // empty' <<<"$input" 2>/dev/null)

in_sidechain=0
case "$transcript" in
  */subagents/agent-*) in_sidechain=1 ;;
esac
[ -n "$agent_id" ] && in_sidechain=1
[ -n "$agent_type" ] && in_sidechain=1

[ "$in_sidechain" -eq 0 ] && exit 0

# Dormant unless explicitly enabled.
[ "${BG_WATCHDOG_MONITOR_GUARD:-0}" = "1" ] || exit 0

echo "Blocked: Monitor armed inside a subagent sidechain, where notifications are not being delivered (guard enabled via BG_WATCHDOG_MONITOR_GUARD=1). The monitor would run to timeout and you would never hear about the event. Instead: use Bash run_in_background with a command that exits when the condition is true, then read the output file; or return your result and let the top-level session arm the watch. If you have re-verified that delivery works, unset BG_WATCHDOG_MONITOR_GUARD rather than working around this. To bypass for one call, include MONITOR_GUARD_OVERRIDE in the monitor description." >&2
exit 2
