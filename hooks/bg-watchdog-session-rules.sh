#!/usr/bin/env bash
# SessionStart hook: load the background-work rules into the session's context.
# Plugins can't ship always-loaded rules files, so this prints them instead.
cat "$(dirname "$0")/../rules/background-work.md" 2>/dev/null
exit 0
