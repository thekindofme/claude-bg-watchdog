#!/usr/bin/env bash
# Deploy watchdog hooks + rules into ~/.claude. Idempotent.
# Installs all 6 hooks (postfail, pretool, subagent-stop, rewake, monitor-guard,
# orphan-sentinel). settings.json wiring is NOT auto-applied (hand-merge; see
# settings-fragment.json).
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
echo
echo "Uninstall (each hook is independently removable):"
echo "  1. Remove its entry from ~/.claude/settings.json (see settings-fragment.json for shape)."
echo "  2. rm the matching ~/.claude/hooks/bg-watchdog-<name>.sh:"
echo "       postfail.sh          -- PostToolUse + PostToolUseFailure[Bash] timeout coaching"
echo "       pretool.sh           -- PreToolUse[Bash] sleep-loop block"
echo "       subagent-stop.sh     -- SubagentStop death ledger"
echo "       rewake.sh            -- Stop async limit-reset rewake"
echo "       monitor-guard.sh     -- PreToolUse[Monitor] sidechain-arm guard (dormant by default)"
echo "       orphan-sentinel.sh   -- Stop async un-actioned-failure rewake + vigil"
echo "  rules/background-work.md can be removed independently from ~/.claude/rules/"
echo "  without touching any hook."
