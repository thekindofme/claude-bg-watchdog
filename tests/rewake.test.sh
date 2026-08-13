#!/usr/bin/env bash
# Tests for hooks/bg-watchdog-rewake.sh.
# Self-contained: run directly (bash tests/rewake.test.sh) or via tests/run.sh.
#
# The hook exposes two test seams, documented in its header:
#   DRY_RUN=1          print "sleep_secs=<n> signal=<what fired>" and exit 0
#                      instead of sleeping and exiting 2.
#   BG_WATCHDOG_NOW=<epoch>  freeze "now" so reset-time arithmetic is deterministic.
# Tests pin TZ=Australia/Melbourne because reset times are local wall-clock
# (real messages read "resets 8:20pm (Australia/Melbourne)").
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export TZ=Australia/Melbourne
HOOK_PATH="$HOOKS_DIR/bg-watchdog-rewake.sh"

# epoch_at <HH:MM> on 2026-08-12 local
epoch_at() { date -j -f "%Y-%m-%d %H:%M:%S" "2026-08-12 $1:00" +%s; }

# secs <fixture> <now-HH:MM> -> prints computed sleep seconds
secs() {
  local fx now
  fx="$(fixture "$1")"; now="$(epoch_at "$2")"
  # The timeout is itself an assertion: DRY_RUN must never actually sleep.
  DRY_RUN=1 BG_WATCHDOG_NOW="$now" with_timeout 10 bash "$HOOK_PATH" <"$fx" 2>/dev/null \
    | sed -nE 's/.*sleep_secs=([0-9]+).*/\1/p' | head -1
}

expect() { # <fixture> <now> <want> <label>
  local got; got="$(secs "$1" "$2")"
  it "$4"
  assert_eq "${got:-<none>}" "$3"
}

# --- 12-hour forms (the only shape the original parser handled) ------------
expect rewake-resets-5pm.json    14:00 10920 "resets 5pm from 14:00 -> 3h + 120s margin"
expect rewake-resets-820pm.json  19:00  4920 "resets 8:20pm from 19:00 -> 1h20m + margin"
expect rewake-resets-1220am.json 22:00  8520 "resets 12:20am from 22:00 -> 2h20m + margin (midnight rollover)"

# --- 24-hour forms (previously fell through to the flat 3600 fallback) -----
expect rewake-resets-24h.json    14:00 10920 "resets 17:00 (24h) parses"
expect rewake-resets-24h-tz.json 14:00 10920 "resets 17:00 with a timezone suffix parses"

# --- relative forms (previously fell through to 3600) ---------------------
expect rewake-resets-in-45-minutes.json 14:00 2820 "resets in 45 minutes -> 2700 + margin"
expect rewake-resets-in-2-hours.json    14:00 7320 "resets in 2 hours -> 7200 + margin"

# --- caps and fallbacks ---------------------------------------------------
expect rewake-resets-5pm.json         09:00 21600 "an 8h wait is capped at 21600s"
expect rewake-limit-garbage.json      14:00  3600 "unparseable reset time falls back to 3600s"
expect rewake-fable-limit-no-time.json 14:00 3600 "model-limit message with no time falls back to 3600s"
expect rewake-529.json                14:00   180 "529 Overloaded uses the 180s path"

# --- must NOT rewake: the noise class the old substring match caught -------
expect rewake-prose-mentions-limits.json 14:00 0 "prose discussing session/usage limits does not rewake"
expect rewake-normal-stop.json           14:00 0 "an ordinary end-of-turn summary does not rewake"
expect rewake-empty.json                 14:00 0 "empty final message does not rewake"

# --- ledger corroboration: a subagent death should still rewake the session -
# The Stop hook's own last_assistant_message is the PARENT's text, which stays
# ordinary when a *subagent* dies; the ledger is the corroborating signal.
reset_ledger
printf '%s\n' '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","agent_id":"a1","agent_type":"impl","session_id":"d387054e-5f4a-4162-a360-7012427e42a6","tail":"You'"'"'ve hit your session limit · resets 5pm (Australia/Melbourne)","signal":"apiErrorStatus:429"}' > "$(ledger)"
got="$(secs rewake-normal-stop.json 14:00)"
it "a fresh genuine ledger death for this session rewakes at its reset time"
assert_eq "${got:-<none>}" 10920

reset_ledger
printf '%s\n' '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","agent_id":"a1","agent_type":"audit","session_id":"d387054e-5f4a-4162-a360-7012427e42a6","tail":"31 of 33 entries merely mention rate limit in prose."}' > "$(ledger)"
got="$(secs rewake-normal-stop.json 14:00)"
it "a legacy ledger entry with no genuine signal does not rewake"
assert_eq "${got:-<none>}" 0

reset_ledger
printf '%s\n' '{"ts":"2026-08-01T00:00:00Z","agent_id":"a1","agent_type":"impl","session_id":"d387054e-5f4a-4162-a360-7012427e42a6","tail":"API Error: 529 Overloaded","signal":"apiErrorStatus:529"}' > "$(ledger)"
got="$(secs rewake-normal-stop.json 14:00)"
it "a stale ledger death (11 days old) does not rewake"
assert_eq "${got:-<none>}" 0
reset_ledger

# --- live behaviour: no DRY_RUN means exit 0 fast when nothing fired -------
run_hook bg-watchdog-rewake.sh "$(fixture rewake-normal-stop.json)"
it "ordinary stop exits 0 without sleeping"
assert_rc 0

run_hook bg-watchdog-rewake.sh 'not json at all'
it "malformed stdin fails open"
assert_rc 0

finish
