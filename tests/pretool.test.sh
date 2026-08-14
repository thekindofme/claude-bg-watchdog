#!/usr/bin/env bash
# Tests for hooks/bg-watchdog-pretool.sh.
# Self-contained: run directly (bash tests/pretool.test.sh) or via tests/run.sh.
#
# Policy under test: block a FOREGROUND Bash call whose estimated total in-loop
# sleep is >= 15s. One-shot sleeps, sleeps below the threshold, and anything with
# run_in_background:true are left alone.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HOOK=bg-watchdog-pretool.sh

blocks() { # <fixture> <label>
  run_hook "$HOOK" "$(fixture "$1")"
  it "$2"
  assert_rc 2
  assert_stderr_contains "run_in_background"
  assert_stderr_contains "Monitor"
}

allows() { # <fixture> <label>
  run_hook "$HOOK" "$(fixture "$1")"
  it "$2"
  assert_rc 0
  assert_stderr_empty
}

# --- under-blocking: evasions the numeric-literal regex missed -------------
# Real evasion found in transcripts: 12 iterations x sleep 10 = 120s foreground.
blocks pretool-seq12-sleep10.json      "seq 1 12 loop with sleep 10 (120s total) is blocked"
blocks pretool-sleep-15s-suffix.json   "sleep 15s (unit suffix) in a loop is blocked"
blocks pretool-sleep-var-in-loop.json  "sleep \$DELAY in a loop is blocked (unknown = suspicious)"
blocks pretool-brace-range-20x1.json   "{1..20} loop with sleep 1 (20s total) is blocked"
blocks pretool-cstyle-for-10x5.json    "C-style for 10x sleep 5 (50s total) is blocked"
blocks pretool-sleep-minutes-unit.json "until-loop with sleep 1m is blocked"
blocks pretool-nested-loops.json       "nested loops 3x2x sleep 3 (18s total) are blocked"
blocks pretool-seq-step.json           "seq 0 5 20 (5 iterations) x sleep 4 (20s) is blocked"
blocks pretool-multiline-loop.json     "multi-line while loop with sleep 20 is blocked"

# Regression: the case the original regex already caught must stay blocked.
blocks pretool-legacy-while-sleep30.json "while true with sleep 30 stays blocked"

# --- over-blocking: loop keyword AND sleep, but not structurally tied ------
allows pretool-oneshot-trailing-sleep.json  "loop followed by a one-shot sleep 20 is allowed"
allows pretool-oneshot-long-sleep.json      "bare one-shot sleep 60 is allowed"
allows pretool-short-total-under-threshold.json "3 iterations x sleep 1 (3s) is allowed"
allows pretool-no-sleep-loop.json           "loop with no sleep is allowed"
allows pretool-detached-loop.json           "loop detached with & is allowed"
allows pretool-sleep-word-in-string.json    "the word sleep inside a quoted string is allowed"
allows pretool-backgrounded-loop.json       "run_in_background:true poll loop is allowed"
allows pretool-subsecond-throttle.json      "sub-second throttle in an uncountable loop is allowed"

# An infinite loop is unbounded no matter how small the per-pass sleep is.
blocks pretool-infinite-subsecond.json      "while true with sleep 0.5 is blocked (unbounded)"

# --- robustness -----------------------------------------------------------
allows pretool-empty-command.json           "empty command is allowed"

run_hook "$HOOK" 'not json at all'
it "malformed stdin fails open"
assert_rc 0

# Latency budget: the hook sits in front of EVERY Bash call. Measured against the
# hook directly (no harness plumbing) over 10 runs.
bench() { # <fixture> -> average ms
  local fx n=10 start end
  fx="$(fixture "$1")"
  start=$(python3 -c 'import time;print(int(time.time()*1000))')
  local k=0
  while [ "$k" -lt "$n" ]; do
    "$HOOKS_DIR/$HOOK" <"$fx" >/dev/null 2>&1
    k=$((k + 1))
  done
  end=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo $(( (end - start) / n ))
}

avg=$(bench pretool-no-sleep-loop.json)
it "fast path (command has no sleep) stays under 25ms (avg ${avg}ms)"
[ "$avg" -lt 25 ] && _ok "fast-path latency ${avg}ms" || _bad "fast-path latency" "avg ${avg}ms exceeds 25ms"

avg=$(bench pretool-seq12-sleep10.json)
it "full parse stays under 100ms (avg ${avg}ms)"
[ "$avg" -lt 100 ] && _ok "parse latency ${avg}ms" || _bad "parse latency" "avg ${avg}ms exceeds 100ms budget"

finish
