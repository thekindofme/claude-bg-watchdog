#!/usr/bin/env bash
# Tests for hooks/bg-watchdog-postfail.sh.
# Self-contained: run directly (bash tests/postfail.test.sh) or via tests/run.sh.
# Feeds hook-input JSON on stdin exactly as the harness does; asserts exit code
# and the hookSpecificOutput JSON on stdout.
#
# Schema verified empirically (2026-08-12):
#   - PostToolUseFailure carries the failure text in a top-level `error` string,
#     "Exit code 143\nCommand timed out after 5m 0s\n<partial output>".
#     Real record: ~/.claude/projects/-Users-dev-code-acme/
#     70127369-8aff-4d1d-b387-151615e7593c.jsonl (toolUseResult + the matching
#     hook_success attachment naming hookEvent "PostToolUseFailure").
#   - PostToolUse carries tool_response {stdout, stderr, interrupted, isImage}
#     and has NO error field, so a *successful* command whose OUTPUT contains the
#     timeout phrase must not be treated as a timeout.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HOOK=bg-watchdog-postfail.sh
GUIDANCE="Do NOT re-run the same command unchanged"

fires() { # <fixture> <label>
  run_hook "$HOOK" "$(fixture "$1")"
  it "$2"
  assert_rc 0
  assert_stdout_contains "$GUIDANCE"
}

silent() { # <fixture> <label>
  run_hook "$HOOK" "$(fixture "$1")"
  it "$2"
  assert_rc 0
  assert_stdout_empty
}

# --- must fire: genuine foreground timeouts -------------------------------
fires postfail-genuine-timeout.json    "genuine 5m timeout (PostToolUseFailure) fires"
fires postfail-genuine-timeout-2m.json "genuine 2m timeout on an SFN poll fires"

# Output contract: hookSpecificOutput echoes the firing event name.
run_hook "$HOOK" "$(fixture postfail-genuine-timeout.json)"
it "fired output names the PostToolUseFailure event"
assert_json_field '.hookSpecificOutput.hookEventName' 'PostToolUseFailure'
it "fired output carries additionalContext"
assert_json_field '.hookSpecificOutput.additionalContext | type' 'string'

# A PostToolUse that was interrupted and shows the timeout banner still counts.
fires postfail-interrupted-posttooluse.json "interrupted PostToolUse with timeout banner fires"
run_hook "$HOOK" "$(fixture postfail-interrupted-posttooluse.json)"
it "interrupted PostToolUse echoes PostToolUse as the event name"
assert_json_field '.hookSpecificOutput.hookEventName' 'PostToolUse'

# --- must NOT fire: the reproduced false positives ------------------------
# Confirmed live 2026-08-12: reading/grepping a file that CONTAINS the trigger
# phrase made the hook emit recovery guidance for a command that succeeded.
silent postfail-output-mentions-phrase.json      "head of a file containing the phrase does not fire"
silent postfail-grep-hit-false-positive.json     "grep whose stdout contains the phrase does not fire"
silent postfail-failure-mentions-phrase-midtext.json \
      "ordinary failure quoting the phrase mid-traceback does not fire"
silent postfail-ordinary-failure.json            "ordinary non-timeout failure does not fire"
silent postfail-success-no-phrase.json           "plain successful command does not fire"

# --- robustness -----------------------------------------------------------
run_hook "$HOOK" 'not json at all'
it "malformed stdin fails open"
assert_rc 0
assert_stdout_empty

run_hook "$HOOK" '{}'
it "empty object fails open"
assert_rc 0
assert_stdout_empty

finish
