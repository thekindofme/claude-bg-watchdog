#!/usr/bin/env bash
# Tests for hooks/bg-watchdog-subagent-stop.sh.
# Self-contained: run directly (bash tests/subagent-stop.test.sh) or via tests/run.sh.
# lib.sh points HOME at a sandbox, so the real ~/.claude/logs ledger is never touched.
#
# Schema verified empirically (2026-08-12) over 2142 subagent transcripts under
# ~/.claude/projects/*/*/subagents/agent-*.jsonl. A genuine death ends with an
# assistant record carrying top-level isApiErrorMessage:true plus error
# ("rate_limit" | "server_error") and usually apiErrorStatus (429 seen 39x,
# 529 seen 14x), whose message.model is the literal "<synthetic>". A normal
# completion ends with an ordinary assistant record (real model id).
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HOOK=bg-watchdog-subagent-stop.sh

logs() { # <fixture> <label>
  reset_ledger
  run_hook "$HOOK" "$(fixture "$1")"
  it "$2"
  assert_rc 0
  assert_eq "$(ledger_lines)" 1 "$2 (ledger gains 1 entry)"
  assert_stdout_contains "systemMessage"
}

quiet() { # <fixture> <label>
  reset_ledger
  run_hook "$HOOK" "$(fixture "$1")"
  it "$2"
  assert_rc 0
  assert_eq "$(ledger_lines)" 0 "$2 (ledger untouched)"
  assert_stdout_empty
}

# --- must NOT log: the confirmed noise class ------------------------------
# An audit agent that merely QUOTED "API Error" / "rate limit" was ledger-logged;
# 32 of the 33 live ledger entries are this class.
quiet subagent-quoting-terms-normal.json  "report quoting API Error / rate limit is not logged"
quiet subagent-normal-completion.json     "ordinary completion is not logged"
quiet subagent-no-transcript-quoting.json "prose mentioning a death, no transcript, is not logged"
quiet subagent-missing-transcript.json    "unreadable transcript + prose message is not logged"
quiet subagent-empty-message.json         "empty final message is not logged"

# --- must log: genuine deaths ---------------------------------------------
logs subagent-death-529.json                "genuine 529 death is logged"
logs subagent-death-session-limit.json      "genuine session-limit (429) death is logged"
logs subagent-death-trailing-attachment.json "death followed by a trailing attachment is logged"
logs subagent-no-transcript-genuine.json    "anchored 'Agent failed: API Error' fallback is logged"

# --- ledger schema: backward compatible, plus the new signal field ---------
reset_ledger
run_hook "$HOOK" "$(fixture subagent-death-529.json)"
entry=$(tail -1 "$(ledger)")
field() { printf '%s' "$entry" | jq -r "$1" 2>/dev/null; }

it "ledger keeps ts"
assert_eq "$(field 'has("ts")')" true
it "ledger keeps agent_id"
assert_eq "$(field '.agent_id')" "ainfra-audit-083646370637c9b9"
it "ledger keeps agent_type"
assert_eq "$(field '.agent_type')" "infra-audit"
it "ledger keeps session_id"
assert_eq "$(field '.session_id')" "d387054e-5f4a-4162-a360-7012427e42a6"
it "ledger keeps tail"
assert_eq "$(field '.tail | type')" "string"
it "ledger adds a signal naming the structural marker"
[ -n "$(field '.signal')" ] && [ "$(field '.signal')" != "null" ] \
  && _ok "signal = $(field '.signal')" || _bad "signal" "missing signal field in: $entry"
it "signal names the api-error marker for a 529 death"
case "$(field '.signal')" in *apiError*|*isApiErrorMessage*|*api_error*) _ok "signal is structural" ;;
  *) _bad "signal" "expected a structural marker name, got '$(field '.signal')'" ;; esac

reset_ledger
run_hook "$HOOK" "$(fixture subagent-no-transcript-genuine.json)"
it "text-fallback death is labelled distinctly from a structural one"
assert_eq "$(printf '%s' "$(tail -1 "$(ledger)")" | jq -r '.signal')" "text-anchored"

# --- robustness -----------------------------------------------------------
reset_ledger
run_hook "$HOOK" 'not json at all'
it "malformed stdin fails open"
assert_rc 0
assert_eq "$(ledger_lines)" 0 "malformed stdin writes nothing"

finish
