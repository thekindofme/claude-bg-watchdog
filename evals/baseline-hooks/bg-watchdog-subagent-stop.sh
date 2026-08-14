#!/usr/bin/env bash
# SubagentStop — ledger + surface subagents that end on an error-looking message.
# Audit 2026-07-24: ~3% of subagents end on a crash (529/session-limit) and the
# death is only noticed hours later. Log to ~/.claude/logs/subagent-deaths.jsonl
# and emit a systemMessage so it is visible immediately.
set -u

input=$(cat)
last=$(jq -r '.last_assistant_message // ""' <<<"$input" 2>/dev/null)
[ -z "$last" ] && exit 0

if echo "$last" | grep -qE 'session limit|usage limit|API Error|Overloaded|rate.?limit'; then
  mkdir -p "$HOME/.claude/logs"
  jq -c '{ts: (now | todate), agent_id: (.agent_id // ""), agent_type: (.agent_type // ""), session_id: (.session_id // ""), tail: ((.last_assistant_message // "") | .[-300:])}' <<<"$input" >> "$HOME/.claude/logs/subagent-deaths.jsonl" 2>/dev/null
  tail_msg=$(echo "$last" | tail -c 200 | tr '\n' ' ')
  jq -nc --arg t "$tail_msg" '{systemMessage: ("⚠️ Subagent ended on an error-looking message (logged to ~/.claude/logs/subagent-deaths.jsonl). Resume it via SendMessage once the cause clears: " + $t)}'
fi
exit 0
