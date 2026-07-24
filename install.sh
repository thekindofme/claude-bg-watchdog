#!/usr/bin/env bash
# Deploy watchdog hooks + rules into ~/.claude. Idempotent.
# settings.json wiring is NOT auto-applied (hand-merge; see settings-fragment.json).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p ~/.claude/hooks ~/.claude/rules ~/.claude/logs
cp hooks/bg-watchdog-*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/bg-watchdog-*.sh
cp rules/background-work.md ~/.claude/rules/

echo "Deployed: $(ls hooks/) rules/background-work.md"
echo
echo "Verify settings.json wiring matches settings-fragment.json:"
echo "  jq '{env, hooks: {PreToolUse, PostToolUse, PostToolUseFailure, SubagentStop, Stop}}' ~/.claude/settings.json"
