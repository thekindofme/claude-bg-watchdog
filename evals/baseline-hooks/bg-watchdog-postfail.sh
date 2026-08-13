#!/usr/bin/env bash
# PostToolUse + PostToolUseFailure [Bash] — coach recovery after a foreground timeout.
# Audit 2026-07-24: agents typically re-ran the identical command after "Command
# timed out", burning duplicate wall-clock (one session lost 2.5h re-polling SFN).
set -u

input=$(cat)
out=$(jq -r '[.tool_output, .tool_response, .error] | map(select(. != null) | tostring) | join(" ")' <<<"$input" 2>/dev/null)

case "$out" in
  *"Command timed out after"*)
    evt=$(jq -r '.hook_event_name // "PostToolUse"' <<<"$input" 2>/dev/null)
    jq -nc --arg evt "$evt" '{hookSpecificOutput:{hookEventName:$evt, additionalContext:"⏱ Foreground Bash timeout. Do NOT re-run the same command unchanged. Pick one: (1) re-run with run_in_background:true and act on the completion notification; (2) if it must stay foreground, re-run ONCE with an explicit timeout sized to the job (max 30m); (3) if the command produced ZERO output before dying, treat it as a hang — kill the process (pkill) rather than waiting longer. For waits on builds/deploys/executions use Monitor, never a sleep loop."}}'
    ;;
esac
exit 0
