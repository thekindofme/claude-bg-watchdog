#!/usr/bin/env bash
# PostToolUse + PostToolUseFailure [Bash] — coach recovery after a foreground timeout.
# Audit 2026-07-24: agents typically re-ran the identical command after "Command
# timed out", burning duplicate wall-clock (one session lost 2.5h re-polling SFN).
#
# Fires only on a STRUCTURAL timeout signal, never on the phrase appearing in
# ordinary output. Two accepted shapes (both verified against real transcripts):
#   1. hook_event_name == PostToolUseFailure, whose top-level `error` string is
#      "Exit code 143\nCommand timed out after 5m 0s\n<partial output>".
#   2. hook_event_name == PostToolUse with tool_response.interrupted == true and
#      the same banner at the head of the captured output.
# In both cases the banner must appear at the START of one of the first few
# lines — a `head`/`grep` whose output merely contains the phrase does not match.
set -u

input=$(cat)

evt=$(jq -r '.hook_event_name // "PostToolUse"' <<<"$input" 2>/dev/null) || exit 0
[ -z "$evt" ] && evt=PostToolUse

case "$evt" in
  PostToolUseFailure)
    # The failure text lives at top level. `.tool_output` / `.tool_response` are
    # read too so older harness builds keep working.
    text=$(jq -r '[.error, .tool_error, .tool_output, .tool_response]
                  | map(select(. != null) | if type == "string" then . else tostring end)
                  | join("\n")' <<<"$input" 2>/dev/null)
    ;;
  *)
    # A success-path PostToolUse is only a timeout if the harness marked the call
    # interrupted. Otherwise the phrase is just something the command printed.
    interrupted=$(jq -r '.tool_response.interrupted // .interrupted // false' <<<"$input" 2>/dev/null)
    [ "$interrupted" = "true" ] || exit 0
    text=$(jq -r '[.tool_response.stdout, .tool_response.stderr, .error]
                  | map(select(. != null) | if type == "string" then . else tostring end)
                  | join("\n")' <<<"$input" 2>/dev/null)
    ;;
esac

[ -z "$text" ] && exit 0

# Anchored: the banner must open a line, within the first 3 lines (the harness
# emits at most an "Exit code N" / "Error: ..." preamble above it).
if ! printf '%s' "$text" | head -3 \
     | grep -qE '^(Error: )?Command timed out after[[:space:]]'; then
  exit 0
fi

jq -nc --arg evt "$evt" '{hookSpecificOutput:{hookEventName:$evt, additionalContext:"⏱ Foreground Bash timeout. Do NOT re-run the same command unchanged. Pick one: (1) re-run with run_in_background:true and act on the completion notification; (2) if it must stay foreground, re-run ONCE with an explicit timeout sized to the job (max 30m); (3) if the command produced ZERO output before dying, treat it as a hang — kill the process (pkill) rather than waiting longer. For waits on builds/deploys/executions use Monitor, never a sleep loop."}}'
exit 0
