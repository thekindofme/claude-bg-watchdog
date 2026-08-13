#!/usr/bin/env bash
# Tests for hooks/bg-watchdog-orphan-sentinel.sh.
# Self-contained: run directly (./tests/orphan-sentinel.test.sh) or via tests/run.sh.
# Feeds Stop-hook input JSON on stdin, asserts exit code and the DRY_RUN decision JSON.
#
# Fixtures are transcript tails in the REAL record shapes mined from two confirmed
# incidents (session dabfb380 @ 2026-08-11T05:08:32Z, session 04cbaa5f @
# 2026-08-03T02:20:20Z). They carry @@T-<seconds-ago>@@ placeholders which this
# harness renders to real ISO timestamps, so the hook's 30-minute tail window is
# exercised against wall-clock rather than frozen dates.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook="$here/../hooks/bg-watchdog-orphan-sentinel.sh"
fixtures="$here/fixtures"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   - $1"; }
no() { fail=$((fail + 1)); echo "  FAIL - $1"; echo "         $2"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/orphan-sentinel-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

# render <fixture> -> path to a transcript with real timestamps
render() {
  local src="$fixtures/$1" dst="$work/${1%.jsonl}.rendered.jsonl"
  python3 - "$src" "$dst" <<'PY'
import re, sys, time
src, dst = sys.argv[1], sys.argv[2]
now = time.time()
def sub(m):
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now - int(m.group(1)))) + '.000Z'
open(dst, 'w').write(re.sub(r'@@T-(\d+)@@', sub, open(src).read()))
PY
  echo "$dst"
}

# stop_input <transcript> <session_id> -> Stop-hook stdin payload
stop_input() {
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":false,"cwd":"/Users/dev/code/acme"}' "$2" "$1"
}

# sentinel <transcript> <session_id> [state_file] -> sets $code and $out (decision JSON)
sentinel() {
  local tp="$1" sid="$2" state="${3:-$work/state.jsonl}"
  out=$(stop_input "$tp" "$sid" | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATE="$state" \
    ORPHAN_SENTINEL_VIGIL="${ORPHAN_SENTINEL_VIGIL:-1}" bash "$hook" 2>/dev/null)
  code=$?
}

field() { printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1" 2>/dev/null; }

expect_rewake() { # <label> <fixture> <session_id> <expected kind> <expected sleep>
  local tp; tp=$(render "$2")
  # These assert the one-shot Stop-time decision; vigil mode is exercised in its
  # own block below and would otherwise swallow the inflight_bg cases.
  ORPHAN_SENTINEL_VIGIL=0 sentinel "$tp" "$3" "$work/$3.state.jsonl"
  if [ "$code" -ne 0 ]; then no "$1" "DRY_RUN must exit 0, got $code"; return; fi
  if [ "$(field decision)" != "rewake" ]; then no "$1" "expected decision=rewake, got: $out"; return; fi
  if [ "$(field kind)" != "$4" ]; then no "$1" "expected kind=$4, got: $out"; return; fi
  if [ "$(field sleep_secs)" != "$5" ]; then no "$1" "expected sleep_secs=$5, got: $out"; return; fi
  ok "$1"
}

expect_no_rewake() { # <label> <fixture> <session_id>
  local tp; tp=$(render "$2")
  # Instant-path assertion; vigil has its own block below.
  ORPHAN_SENTINEL_VIGIL=0 sentinel "$tp" "$3" "$work/$3.state.jsonl"
  if [ "$code" -ne 0 ]; then no "$1" "must exit 0, got $code"; return; fi
  if [ "$(field decision)" = "rewake" ]; then no "$1" "expected no rewake, got: $out"; return; fi
  ok "$1"
}

echo "orphan-sentinel.test.sh"

# ── Detection: the two confirmed incidents must be caught ──────────────────────
# Incident 1 (dabfb380): "Agent stalled: no progress for 600s", zero assistant
# activity for the next 32 minutes until the user typed "status".
expect_rewake "unhandled failed notification -> rewake in 60s" \
  orphan-sentinel-failed-unhandled.jsonl sess-failed failed_task 60

# The rewake must NAME the orphan, or the woken turn cannot act on it.
tp=$(render orphan-sentinel-failed-unhandled.jsonl)
sentinel "$tp" sess-named "$work/sess-named.state.jsonl"
if [ "$(field task_id)" != "ac58a3ed073761ef3" ]; then
  no "rewake names the orphan task id" "got: $out"
elif ! printf '%s' "$out" | grep -q 'Agent stalled: no progress for 600s'; then
  no "rewake quotes the notification summary" "got: $out"
elif ! printf '%s' "$out" | grep -qi 'un-actioned async failure'; then
  no "rewake carries the process-it-now instruction" "got: $out"
else
  ok "rewake names the orphan (task id + quoted summary + instruction)"
fi

# Incident 2 (04cbaa5f): "[Monitor timed out — re-arm if needed.]" never re-armed.
expect_rewake "un-re-armed Monitor timeout -> rewake in 60s" \
  orphan-sentinel-monitor-timeout.jsonl sess-monitor monitor_timeout 60

# Status vocabulary, counted over the sampled transcripts: completed(4286),
# failed(247), killed(72), stopped(4). Only `failed` is on by default — replaying
# 150 real session-final Stops produced three killed/stopped fires and zero failed
# ones, and all three were teardown artifacts ("Start Caddy reverse proxy was
# stopped") rather than anything a turn should have acted on.
expect_no_rewake "killed background command is NOT an orphan by default" \
  orphan-sentinel-killed.jsonl sess-killed

tp=$(render orphan-sentinel-killed.jsonl)
out=$(stop_input "$tp" sess-killed-optin | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATUSES='failed,killed,stopped' \
  ORPHAN_SENTINEL_STATE="$work/killed-optin.state.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ] && [ "$(field kind)" = "failed_task" ]; then
  ok "ORPHAN_SENTINEL_STATUSES opts killed/stopped back in"
else
  no "ORPHAN_SENTINEL_STATUSES opts killed/stopped back in" "exit $code, got: $out"
fi

# ── False positives are the thing that must never happen ──────────────────────
expect_no_rewake "clean session (no async records at all) -> silent" \
  orphan-sentinel-clean.jsonl sess-clean
expect_no_rewake "completed notifications only -> silent" \
  orphan-sentinel-completed-only.jsonl sess-completed
expect_no_rewake "failure the session answered (assistant record after) -> silent" \
  orphan-sentinel-failed-handled.jsonl sess-handled
expect_no_rewake "failure whose notification was dequeued (remove op) -> silent" \
  orphan-sentinel-failed-removed.jsonl sess-removed
expect_no_rewake "Monitor timeout that was re-armed -> silent" \
  orphan-sentinel-monitor-rearmed.jsonl sess-rearmed

# Regression, caught replaying the real 04cbaa5f transcript: one Monitor task-id
# notifies repeatedly, so an EARLIER dequeued event must not mask a later
# un-actioned one. The dequeue only counts if it came after the enqueue.
expect_rewake "re-notifying task id: earlier remove does not mask the later timeout" \
  orphan-sentinel-monitor-renotify.jsonl sess-renotify monitor_timeout 60
expect_no_rewake "orphan older than the tail window -> silent" \
  orphan-sentinel-stale.jsonl sess-stale

# Second guard on the killed/stopped lane, for when it is opted in: a preceding
# KillShell/TaskStop is evidence the session asked for the teardown.
tp=$(render orphan-sentinel-killed-deliberate.jsonl)
out=$(stop_input "$tp" sess-killed-deliberate | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATUSES='failed,killed,stopped' \
  ORPHAN_SENTINEL_STATE="$work/killed-delib.state.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ] && [ "$(field decision)" != "rewake" ]; then
  ok "killed after an explicit KillShell -> deliberate, silent even when opted in"
else
  no "killed after an explicit KillShell -> deliberate, silent" "exit $code, got: $out"
fi

# Fast path: a clean session must not pay for a scan it cannot use. This is a
# smoke check that the grep short-circuit fires at all — the real cost is process
# startup (~50ms), so the bound is loose enough to survive a loaded machine.
tp=$(render orphan-sentinel-clean.jsonl)
start=$(python3 -c 'import time; print(time.time())')
ORPHAN_SENTINEL_VIGIL=0 sentinel "$tp" sess-fast "$work/sess-fast.state.jsonl"
elapsed=$(python3 -c 'import sys,time; print(time.time()-float(sys.argv[1]))' "$start")
if [ "$(field reason)" != "no_async_records" ]; then
  no "clean session takes the grep short-circuit" "expected no_async_records, got: $out"
elif [ "$(python3 -c 'import sys; print(1 if float(sys.argv[1])<3 else 0)' "$elapsed")" = "1" ]; then
  ok "clean-session fast path short-circuits and returns fast (${elapsed}s)"
else
  no "clean-session fast path returns fast" "took ${elapsed}s"
fi

# ── Anti-loop: one rewake per orphan, ever ────────────────────────────────────
st="$work/repeat.state.jsonl"
tp=$(render orphan-sentinel-failed-unhandled.jsonl)
ORPHAN_SENTINEL_VIGIL=0 sentinel "$tp" sess-repeat "$st"
first=$(field decision)
ORPHAN_SENTINEL_VIGIL=0 sentinel "$tp" sess-repeat "$st"
second=$(field decision)
if [ "$first" != "rewake" ]; then
  no "same orphan on a later Stop does not rewake again" "first Stop should rewake, got: $first"
elif [ "$second" = "rewake" ]; then
  no "same orphan on a later Stop does not rewake again" "second Stop rewoke again: $out"
elif [ "$(field reason)" != "already_rewoken" ]; then
  no "repeat suppression is logged with a reason" "expected reason=already_rewoken, got: $out"
else
  ok "same orphan on a later Stop does not rewake again (first rewake evidently failed)"
fi

# The suppression must be recorded, not silently dropped.
if grep -q 'suppressed_repeat' "$st" 2>/dev/null; then
  ok "repeat suppression is appended to the state ledger"
else
  no "repeat suppression is appended to the state ledger" "state file: $(cat "$st" 2>/dev/null)"
fi

# State is keyed per session: another session with the same orphan still fires.
ORPHAN_SENTINEL_VIGIL=0 sentinel "$tp" sess-other "$st"
if [ "$(field decision)" = "rewake" ]; then
  ok "state is keyed by session_id (a different session still rewakes)"
else
  no "state is keyed by session_id (a different session still rewakes)" "got: $out"
fi

# ── Anti-loop: per-session rewake cap ─────────────────────────────────────────
st="$work/cap.state.jsonl"
tp=$(render orphan-sentinel-cap.jsonl)
capfail=""
for i in 1 2 3 4 5; do
  sentinel "$tp" sess-cap "$st"
  [ "$(field decision)" = "rewake" ] || capfail="Stop #$i should have rewoken for a fresh orphan, got: $out"
done
sentinel "$tp" sess-cap "$st"
if [ -n "$capfail" ]; then
  no "per-session rewake cap of 5 is respected" "$capfail"
elif [ "$(field decision)" = "rewake" ]; then
  no "per-session rewake cap of 5 is respected" "6th rewake was allowed: $out"
elif [ "$(field reason)" != "session_cap" ]; then
  no "cap suppression is logged with a reason" "expected reason=session_cap, got: $out"
else
  ok "per-session rewake cap of 5 is respected (6th orphan suppressed)"
fi

# ── In-flight background work (case c): lowest priority, generous grace ───────
expect_rewake "in-flight background launch, never checked -> 900s grace rewake" \
  orphan-sentinel-inflight-bg.jsonl sess-inflight inflight_bg 900
expect_no_rewake "in-flight background launch that WAS checked (BashOutput) -> silent" \
  orphan-sentinel-inflight-checked.jsonl sess-checked

# Lane 3 gets its own, much wider time bound. Replaying the real dabfb380 Stop
# showed the launch had aged 31 min by the time the session went quiet, so the
# 30-minute notification window would have missed the one lane that covers that
# incident. An OLDER unchecked launch is a stronger orphan signal, not a weaker one.
expect_rewake "in-flight launch older than the notification window still counts" \
  orphan-sentinel-inflight-aged.jsonl sess-inflight-aged inflight_bg 900

# A hard failure outranks in-flight work when both are present.
st="$work/prio.state.jsonl"
tp=$(render orphan-sentinel-failed-unhandled.jsonl)
sentinel "$tp" sess-prio "$st"
if [ "$(field kind)" = "failed_task" ]; then
  ok "failure orphans outrank in-flight background work"
else
  no "failure orphans outrank in-flight background work" "got: $out"
fi

# The in-flight lane is the one knob most likely to need tuning; it must be off-able.
tp=$(render orphan-sentinel-inflight-bg.jsonl)
out=$(stop_input "$tp" sess-inflight-off | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_INFLIGHT=0 \
  ORPHAN_SENTINEL_STATE="$work/inflight-off.state.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ] && [ "$(field decision)" != "rewake" ]; then
  ok "ORPHAN_SENTINEL_INFLIGHT=0 disables the in-flight lane"
else
  no "ORPHAN_SENTINEL_INFLIGHT=0 disables the in-flight lane" "exit $code, got: $out"
fi

# ── Re-entrancy and robustness: a Stop hook runs on EVERY stop ────────────────
tp=$(render orphan-sentinel-failed-unhandled.jsonl)
out=$(printf '{"session_id":"sess-reentrant","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":true}' "$tp" \
  | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATE="$work/reentrant.state.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ] && [ "$(field decision)" != "rewake" ]; then
  ok "stop_hook_active=true short-circuits (no rewake-on-rewake loop)"
else
  no "stop_hook_active=true short-circuits" "exit $code, got: $out"
fi

out=$(printf 'not json at all' | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATE="$work/x.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ]; then ok "malformed stdin fails open"; else no "malformed stdin fails open" "exit $code"; fi

out=$(printf '{"session_id":"s","transcript_path":"%s/does-not-exist.jsonl","hook_event_name":"Stop"}' "$work" \
  | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATE="$work/x.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ]; then ok "missing transcript fails open"; else no "missing transcript fails open" "exit $code"; fi

tp="$work/truncated.jsonl"
printf '{"type":"assistant","timestamp":"2026-08-12T00:00:00.000Z"}\n{"type":"queue-oper\n' >"$tp"
out=$(stop_input "$tp" sess-truncated | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATE="$work/x.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ]; then ok "unparseable transcript lines are skipped, not fatal"; else no "unparseable transcript lines are skipped" "exit $code"; fi

# ── Live mode wiring (no DRY_RUN): must exit 2 and put the orphan on stderr ───
# ORPHAN_SENTINEL_MAX_SLEEP caps the sleep so this test does not actually wait 60s.
tp=$(render orphan-sentinel-failed-unhandled.jsonl)
err=$(stop_input "$tp" sess-live | ORPHAN_SENTINEL_STATE="$work/live.state.jsonl" \
  ORPHAN_SENTINEL_MAX_SLEEP=0 bash "$hook" 2>&1 >/dev/null); code=$?
if [ "$code" -ne 2 ]; then
  no "live mode exits 2 to trigger the async rewake" "expected exit 2, got $code (stderr: $err)"
elif ! grep -q 'ac58a3ed073761ef3' <<<"$err"; then
  no "live mode puts the orphan id on stderr (the model-facing channel on exit 2)" "$err"
else
  ok "live mode exits 2 with the orphan named on stderr"
fi

err=$(stop_input "$(render orphan-sentinel-clean.jsonl)" sess-live-clean | ORPHAN_SENTINEL_STATE="$work/live2.state.jsonl" \
  ORPHAN_SENTINEL_MAX_SLEEP=0 bash "$hook" 2>&1 >/dev/null); code=$?
if [ "$code" -eq 0 ]; then ok "live mode on a clean session exits 0 silently"; else no "live mode on a clean session exits 0" "exit $code: $err"; fi

# ── Vigil mode ────────────────────────────────────────────────────────────────
# A Stop hook fires when a turn ENDS, so it cannot see a notification that
# arrives while the session is already quiet — which is what happened in both
# confirmed incidents (dabfb380 stopped 04:44, orphan enqueued 05:08). Vigil mode
# closes that: when in-flight work exists at Stop, the hook stays alive and polls
# the transcript, exiting 2 the moment a failure lands un-actioned.
#
# The wake primitive is proven: 24 real asyncRewake deliveries across 19 days of
# this user's transcripts, 24/24 acted on, longest surviving hook sleep 3600s.
#
# DRY_RUN vigil does not sleep. It runs at most VIGIL_MAX/VIGIL_POLL iterations
# and calls $ORPHAN_SENTINEL_VIGIL_STEP with the poll number before each scan,
# which is how these tests inject transcript growth between polls.

# step_script <name> <poll-number> <fixture-to-append> -> path to a step command
step_script() {
  local sp="$work/step-$1.sh" poll="$2" frag="$3"
  cat >"$sp" <<EOF
#!/usr/bin/env bash
[ "\$1" = "$poll" ] && cat "$frag" >>"$4"
exit 0
EOF
  chmod +x "$sp"; echo "$sp"
}

# vigil <transcript> <session> <state> [extra env assignments...] -> $code/$out
vigil() {
  local tp="$1" sid="$2" state="$3"; shift 3
  out=$(stop_input "$tp" "$sid" | env ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_STATE="$state" \
    ORPHAN_SENTINEL_VIGIL=1 ORPHAN_SENTINEL_VIGIL_MAX=300 ORPHAN_SENTINEL_VIGIL_POLL=60 \
    "$@" bash "$hook" 2>/dev/null)
  code=$?
}

# A failure that lands MID-VIGIL is the whole point: this is incident dabfb380.
tp=$(render orphan-sentinel-inflight-bg.jsonl)
frag="$work/late-failure.jsonl"
render orphan-sentinel-failed-unhandled.jsonl >/dev/null
python3 - "$fixtures/orphan-sentinel-failed-unhandled.jsonl" "$frag" <<'PY'
import re, sys, time, json
now = time.time()
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
out = [r for r in recs if r.get("type") == "queue-operation" and "failed" in (r.get("content") or "")]
for r in out:
    r["timestamp"] = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now)) + '.000Z'
open(sys.argv[2], 'w').write("\n".join(json.dumps(r) for r in out) + "\n")
PY
sp=$(step_script latefail 2 "$frag" "$tp")
vigil "$tp" sess-vigil-trigger "$work/vigil1.state.jsonl" ORPHAN_SENTINEL_VIGIL_STEP="$sp"
if [ "$code" -ne 0 ]; then
  no "vigil triggers on a failure that lands mid-vigil" "DRY_RUN must exit 0, got $code"
elif [ "$(field decision)" != "rewake" ]; then
  no "vigil triggers on a failure that lands mid-vigil" "expected rewake, got: $out"
elif [ "$(field via)" != "vigil" ]; then
  no "vigil trigger is attributed to vigil mode" "expected via=vigil, got: $out"
elif [ "$(field task_id)" != "ac58a3ed073761ef3" ]; then
  no "vigil names the orphan that landed" "got: $out"
else
  ok "vigil triggers on a failure that lands mid-vigil (the dabfb380 case)"
fi

# Debounce: a failure the session picks up within one poll cycle is not an orphan.
tp2=$(render orphan-sentinel-inflight-bg.jsonl)
frag2="$work/late-then-handled.jsonl"
cp "$frag" "$frag2"
python3 - "$frag2" <<'PY'
import sys, time, json
now = time.time()
open(sys.argv[1], 'a').write(json.dumps({
    "type": "assistant", "isSidechain": False,
    "timestamp": time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now + 1)) + '.000Z',
    "message": {"role": "assistant", "content": [
        {"type": "text", "text": "The verifier stalled; resuming it now."}]}}) + "\n")
PY
sp2=$(step_script debounce 1 "$frag2" "$tp2")
vigil "$tp2" sess-vigil-debounce "$work/vigil2.state.jsonl" ORPHAN_SENTINEL_VIGIL_STEP="$sp2"
if [ "$code" -eq 0 ] && [ "$(field decision)" != "rewake" ]; then
  ok "vigil does not fire on a failure the session handles within one poll"
else
  no "vigil does not fire on a failure the session handles within one poll" "exit $code, got: $out"
fi

# Stand-down: the user came back on their own.
tp3=$(render orphan-sentinel-inflight-bg.jsonl)
frag3="$work/user-woke.jsonl"
python3 - "$frag3" <<'PY'
import sys, time, json
now = time.time()
open(sys.argv[1], 'w').write(json.dumps({
    "type": "user", "isSidechain": False,
    "timestamp": time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now)) + '.000Z',
    "message": {"role": "user", "content": "status"}}) + "\n")
PY
sp3=$(step_script userwoke 1 "$frag3" "$tp3")
vigil "$tp3" sess-vigil-standdown "$work/vigil3.state.jsonl" ORPHAN_SENTINEL_VIGIL_STEP="$sp3"
if [ "$code" -eq 0 ] && [ "$(field reason)" = "vigil_stood_down" ]; then
  ok "vigil stands down when the user comes back on their own"
else
  no "vigil stands down when the user comes back" "exit $code, got: $out"
fi

# CRITICAL: a DELIVERED notification also appears as a `user` record carrying the
# same <task-notification> XML. Treating that as user activity would stand the
# vigil down at exactly the moment it should fire.
tp4=$(render orphan-sentinel-inflight-bg.jsonl)
frag4="$work/delivered-notif.jsonl"
python3 - "$frag4" <<'PY'
import sys, time, json
now = time.time()
xml = ("<task-notification>\n<task-id>ac58a3ed073761ef3</task-id>\n"
       "<tool-use-id>toolu_01TQyyJAjHkiprLuQaGVb9ui</tool-use-id>\n<status>failed</status>\n"
       "<summary>Agent \"Verify clock/parse close-gate issues\" failed: Agent stalled: "
       "no progress for 600s (stream watchdog did not recover)</summary>\n</task-notification>")
ts = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now)) + '.000Z'
rows = [
    {"type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": xml},
    {"type": "queue-operation", "operation": "dequeue", "timestamp": ts, "content": xml},
    {"type": "user", "isSidechain": False, "timestamp": ts,
     "message": {"role": "user", "content": xml}},
]
open(sys.argv[1], 'w').write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
sp4=$(step_script delivered 2 "$frag4" "$tp4")
vigil "$tp4" sess-vigil-delivered "$work/vigil4.state.jsonl" ORPHAN_SENTINEL_VIGIL_STEP="$sp4"
if [ "$(field decision)" = "rewake" ]; then
  ok "a delivered task-notification is not user activity (vigil still fires)"
else
  no "a delivered task-notification is not user activity" "vigil stood down instead: $out"
fi

# Clean resolution: the in-flight work finished, nothing is owed.
tp5=$(render orphan-sentinel-inflight-bg.jsonl)
frag5="$work/resolved.jsonl"
python3 - "$frag5" <<'PY'
import sys, time, json
now = time.time()
ts = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now)) + '.000Z'
xml = ("<task-notification>\n<task-id>bdone0001</task-id>\n"
       "<tool-use-id>toolu_01FullSuiteRerunBackground</tool-use-id>\n<status>completed</status>\n"
       "<summary>Background command \"Full-suite rerun on the branch\" finished</summary>\n"
       "</task-notification>")
open(sys.argv[1], 'w').write(json.dumps(
    {"type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": xml}) + "\n")
PY
sp5=$(step_script resolved 1 "$frag5" "$tp5")
vigil "$tp5" sess-vigil-resolved "$work/vigil5.state.jsonl" ORPHAN_SENTINEL_VIGIL_STEP="$sp5"
if [ "$code" -eq 0 ] && [ "$(field reason)" = "vigil_all_resolved" ]; then
  ok "vigil stands down when all in-flight work resolves cleanly"
else
  no "vigil stands down when all in-flight work resolves cleanly" "exit $code, got: $out"
fi

# Max duration: quiet exit, no poke.
tp6=$(render orphan-sentinel-inflight-bg.jsonl)
vigil "$tp6" sess-vigil-max "$work/vigil6.state.jsonl"
if [ "$code" -eq 0 ] && [ "$(field reason)" = "vigil_max_duration" ]; then
  if [ "$(field polls)" = "5" ]; then
    ok "vigil exits quietly at max duration (VIGIL_MAX/VIGIL_POLL = 5 polls)"
  else
    no "vigil runs VIGIL_MAX/VIGIL_POLL polls" "expected polls=5, got: $out"
  fi
else
  no "vigil exits quietly at max duration" "exit $code, got: $out"
fi

# One vigil per session: a live lock holder blocks a second instance.
st="$work/vigil-lock.state.jsonl"
lock="${st%.jsonl}-vigil-sess-vigil-lock.lock"
mkdir -p "$(dirname "$lock")"
printf '{"pid":%s,"start":%s}\n' "$$" "$(date +%s)" >"$lock"
tp7=$(render orphan-sentinel-inflight-bg.jsonl)
vigil "$tp7" sess-vigil-lock "$st"
if [ "$code" -eq 0 ] && [ "$(field reason)" = "vigil_already_running" ]; then
  ok "a fresh lock held by a live PID blocks a second vigil"
else
  no "a fresh lock held by a live PID blocks a second vigil" "exit $code, got: $out"
fi

# ...but a lock left behind by a killed hook must not wedge the sentinel forever.
st="$work/vigil-stale.state.jsonl"
lock="${st%.jsonl}-vigil-sess-vigil-stale.lock"
printf '{"pid":999999,"start":%s}\n' "$(( $(date +%s) - 99999 ))" >"$lock"
tp8=$(render orphan-sentinel-inflight-bg.jsonl)
vigil "$tp8" sess-vigil-stale "$st"
if [ "$code" -eq 0 ] && [ "$(field reason)" = "vigil_max_duration" ]; then
  ok "a stale lock (dead PID) is taken over, not obeyed"
else
  no "a stale lock (dead PID) is taken over" "exit $code, got: $out"
fi

# Anti-loop still governs: an orphan already rewoken is not re-poked by vigil.
st="$work/vigil-antiloop.state.jsonl"
tp9=$(render orphan-sentinel-inflight-bg.jsonl)
sp9=$(step_script antiloop 2 "$frag" "$tp9")
vigil "$tp9" sess-vigil-antiloop "$st" ORPHAN_SENTINEL_VIGIL_STEP="$sp9"
first=$(field decision)
tp10=$(render orphan-sentinel-inflight-bg.jsonl)
sp10=$(step_script antiloop2 2 "$frag" "$tp10")
vigil "$tp10" sess-vigil-antiloop "$st" ORPHAN_SENTINEL_VIGIL_STEP="$sp10"
if [ "$first" = "rewake" ] && [ "$(field decision)" != "rewake" ]; then
  ok "vigil respects one-rewake-ever (same orphan not re-poked on a later vigil)"
else
  no "vigil respects one-rewake-ever" "first=$first second=$out"
fi

# The one-shot 900s poke remains available when vigil is switched off.
tp11=$(render orphan-sentinel-inflight-bg.jsonl)
out=$(stop_input "$tp11" sess-vigil-off | ORPHAN_SENTINEL_DRY_RUN=1 ORPHAN_SENTINEL_VIGIL=0 \
  ORPHAN_SENTINEL_STATE="$work/vigil-off.state.jsonl" bash "$hook" 2>/dev/null); code=$?
if [ "$code" -eq 0 ] && [ "$(field decision)" = "rewake" ] && [ "$(field sleep_secs)" = "900" ]; then
  ok "ORPHAN_SENTINEL_VIGIL=0 falls back to the one-shot 900s poke"
else
  no "ORPHAN_SENTINEL_VIGIL=0 falls back to the one-shot 900s poke" "exit $code, got: $out"
fi

# Replaying the real dabfb380 session showed ZERO of its 20 top-level Agent
# launches ever appear in a notification — every agent that notified was spawned
# inside a subagent orchestrator, invisible up here. So gating the vigil on an
# unresolved lane-3 launch would never have started one for that incident. The
# trigger is therefore any RECENT ASYNC FOOTPRINT: a session that has been
# receiving task-notifications is a session that can receive another one.
tp13=$(render orphan-sentinel-completed-only.jsonl)
sp13=$(step_script footprint 2 "$frag" "$tp13")
vigil "$tp13" sess-vigil-footprint "$work/vigil-fp.state.jsonl" ORPHAN_SENTINEL_VIGIL_STEP="$sp13"
if [ "$(field decision)" = "rewake" ] && [ "$(field via)" = "vigil" ]; then
  ok "async footprint alone (notifications, no in-flight launch) starts a vigil"
else
  no "async footprint alone starts a vigil" "got: $out"
fi

# A session with no async footprint at all must never pay for a vigil.
tp14=$(render orphan-sentinel-clean.jsonl)
vigil "$tp14" sess-vigil-clean "$work/vigil-clean.state.jsonl"
if [ "$code" -eq 0 ] && [ "$(field reason)" = "no_async_records" ]; then
  ok "a clean session never starts a vigil"
else
  no "a clean session never starts a vigil" "exit $code, got: $out"
fi

# The one-rewake-ever guarantee has to hold on the vigil path too, where the
# second Stop watches instead of returning immediately.
st2="$work/repeat-vigil.state.jsonl"
tpv=$(render orphan-sentinel-failed-unhandled.jsonl)
vigil "$tpv" sess-repeat-vigil "$st2"
firstv=$(field decision)
vigil "$tpv" sess-repeat-vigil "$st2"
if [ "$firstv" = "rewake" ] && [ "$(field decision)" != "rewake" ]; then
  ok "one-rewake-ever holds on the vigil path too"
else
  no "one-rewake-ever holds on the vigil path too" "first=$firstv second=$out"
fi

# Lanes 1-2 must stay instant — a visible failure is never deferred into a vigil.
tp12=$(render orphan-sentinel-failed-unhandled.jsonl)
vigil "$tp12" sess-vigil-instant "$work/vigil-instant.state.jsonl"
if [ "$(field decision)" = "rewake" ] && [ "$(field sleep_secs)" = "60" ] && [ "$(field via)" != "vigil" ]; then
  ok "an already-visible failure still takes the instant 60s path, not a vigil"
else
  no "an already-visible failure still takes the instant path" "got: $out"
fi

echo "orphan-sentinel.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
