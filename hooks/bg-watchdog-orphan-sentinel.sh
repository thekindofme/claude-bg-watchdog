#!/usr/bin/env bash
# Stop hook (async + asyncRewake) — "orphan sentinel".
#
# Audit 2026-08-12: the worst watcher failure class is "alarm fired, nobody
# home" — an async failure signal is DELIVERED into the session and no turn ever
# acts on it. Two confirmed incidents:
#   * 08-11 dabfb380: "Agent stalled: no progress for 600s" enqueued 05:08:32Z;
#     zero assistant activity until the user typed "status" 32 minutes later.
#   * 08-03 04cbaa5f: "[Monitor timed out — re-arm if needed.]" at 02:20:20Z
#     never re-armed; session quiet ~13 min until the user typed "status".
#
# On every Stop this scans a bounded tail of the session transcript and asks
# "is there un-actioned async state?". If so it sleeps briefly, then exits 2 so
# the session wakes itself with the orphan named.
#
# ── Transcript shapes this relies on (mined from real sessions) ───────────────
# A notification is a `queue-operation` record whose `content` holds a
# <task-notification> block. Three operations exist and they mean different
# things: `enqueue` posts it, `dequeue` delivers it (it then also appears as a
# `user` record carrying the same XML), and `remove` withdraws it. Only `remove`
# implies nothing is owed. Delivery is NOT action — that is the whole bug — so
# the action test is "did any assistant record follow it".
#
# ── Detection lanes (highest priority first) ──────────────────────────────────
#   failed_task     a <task-notification> whose <status> is in $STATUSES, with no
#                   assistant record after it and no later 'remove'.  sleep 60s
#   monitor_timeout a <task-notification> whose <event> contains "Monitor timed
#                   out", same un-actioned test.                    sleep 60s
#   inflight_bg     a background launch (Bash run_in_background, Agent, Monitor
#                   arm) with no later status check and no notification
#                   carrying its tool-use id.                       sleep 900s
#
# NOTE on the lanes — read this before tuning them. In BOTH confirmed incidents
# the orphan notification was enqueued AFTER the session had already stopped, so
# no Stop event exists at which lanes 1-2 could see it. Lanes 1-2 only cover the
# narrower case where a notification lands before a turn ends and the turn still
# ignores it. VIGIL MODE (below) is what actually covers the two incidents.
#
# ── Vigil mode ────────────────────────────────────────────────────────────────
# When a Stop leaves recent async footprint behind, the hook does not fire a
# blind one-shot poke — it stays alive and watches, polling the transcript every
# VIGIL_POLL seconds and exiting 2 the moment a real failure lands un-actioned.
#
# The wake primitive is proven, not assumed: 24 asyncRewake deliveries across 19
# days of this user's transcripts, 24/24 acted on by the session, longest
# surviving hook sleep 3600s. (Only 3600s is empirically demonstrated; a 2h
# VIGIL_MAX extrapolates past it, well inside the 25200s hook timeout.)
#
# Trigger = recent async footprint, NOT an unresolved lane-3 launch. Replaying
# dabfb380 showed ZERO of its 20 top-level Agent launches ever appear in a
# notification — every agent that notified was spawned inside a subagent
# orchestrator, invisible up here — so a lane-3 gate would never have started a
# vigil for the incident it is meant to catch. A session that has been receiving
# notifications is a session that can receive another one after it goes quiet.
#
# Stand down (exit 0, silent) when: the session wakes on its own, the in-flight
# work that started the vigil resolves, or VIGIL_MAX elapses. Replayed against
# the real incidents from their real Stop, vigil fires 31 min (dabfb380) and
# 12 min (04cbaa5f) before the user typed "status". Across 150 real
# session-final Stops it produced ZERO pokes and started 38 silent vigils,
# replacing the 6% blind-poke rate of the one-shot lane-3 behaviour.
# ORPHAN_SENTINEL_VIGIL=0 restores that one-shot 900s poke.
#
# ── Anti-loop (the hard requirement) ──────────────────────────────────────────
# Every decision is appended to a JSONL ledger keyed by session_id + a stable
# hash of the orphan record. An orphan is rewoken AT MOST ONCE, ever: if the
# same orphan is still un-actioned at a later Stop the first rewake evidently
# failed, and a second automated poke would loop — so it is logged and
# suppressed. Total rewakes per session are capped (default 5).
#
# ── Env ───────────────────────────────────────────────────────────────────────
#   ORPHAN_SENTINEL_DRY_RUN=1   print the decision as one JSON object and exit 0;
#                               never sleeps, never exits 2. State IS still
#                               written, so a DRY_RUN sequence exercises the
#                               anti-loop rules. Makes the sleep/rewake
#                               computation testable without sleeping.
#   ORPHAN_SENTINEL_STATE=path  ledger path (default ~/.claude/logs/orphan-sentinel-state.jsonl)
#   ORPHAN_SENTINEL_INFLIGHT=0  disable lane 3 (default on)
#   ORPHAN_SENTINEL_STATUSES=…  comma-separated statuses lane 1 treats as a
#                               failure (default "failed"; add killed,stopped to
#                               widen — see the note on STATUSES below)
#   ORPHAN_SENTINEL_VIGIL=0     disable vigil mode; lane 3 reverts to one 900s poke
#   ORPHAN_SENTINEL_VIGIL_MAX=N how long a vigil may watch (default 7200 = 2h).
#                               Must stay well under the hook timeout in
#                               settings.json (25200s) — that is the hard ceiling.
#   ORPHAN_SENTINEL_VIGIL_POLL=N seconds between polls (default 60)
#   ORPHAN_SENTINEL_VIGIL_STEP=cmd  test seam: run `cmd <poll-number>` before each
#                               poll. DRY_RUN never sleeps and runs at most
#                               VIGIL_MAX/VIGIL_POLL polls, so a test injects
#                               transcript growth here instead of waiting.
#   ORPHAN_SENTINEL_CAP=N       rewakes per session (default 5)
#   ORPHAN_SENTINEL_MAX_SLEEP=N clamp the sleep, for tests (default unclamped)
#
# Fails open everywhere: a malformed payload, a missing transcript or a missing
# jq must never wedge a session, so every unexpected condition exits 0.
set -u

TAIL_LINES=${ORPHAN_SENTINEL_TAIL_LINES:-300}   # bounded scan: last N records
WINDOW=${ORPHAN_SENTINEL_WINDOW:-1800}          # lanes 1-2: only the last 30 min
FWINDOW=${ORPHAN_SENTINEL_INFLIGHT_WINDOW:-14400} # lane 3: age is evidence, not decay
MIN_AGE=${ORPHAN_SENTINEL_MIN_AGE:-120}         # lane 3 grace before it counts
CAP=${ORPHAN_SENTINEL_CAP:-5}
# Only `failed` by default. Replaying 150 real session-final Stops produced three
# killed/stopped fires and zero failed ones, and all three were teardown artifacts
# (a backgrounded server reaped at session end), not work a turn owed anything to.
STATUSES=${ORPHAN_SENTINEL_STATUSES:-failed}
INFLIGHT=${ORPHAN_SENTINEL_INFLIGHT:-1}
VIGIL=${ORPHAN_SENTINEL_VIGIL:-1}               # watch instead of a blind poke
VIGIL_MAX=${ORPHAN_SENTINEL_VIGIL_MAX:-7200}    # 2h; hook timeout is the ceiling
VIGIL_POLL=${ORPHAN_SENTINEL_VIGIL_POLL:-60}
VIGIL_STEP=${ORPHAN_SENTINEL_VIGIL_STEP:-}      # test seam, see header
STATE=${ORPHAN_SENTINEL_STATE:-$HOME/.claude/logs/orphan-sentinel-state.jsonl}
DRY=${ORPHAN_SENTINEL_DRY_RUN:-0}

# emit <json>  — DRY_RUN prints the decision; live mode stays quiet.
emit() { [ "$DRY" = "1" ] && printf '%s\n' "$1"; return 0; }
quiet() { emit "{\"decision\":\"none\",\"reason\":\"$1\"}"; exit 0; }

command -v jq >/dev/null 2>&1 || quiet "jq_unavailable"

input=$(cat 2>/dev/null) || quiet "no_stdin"
session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || quiet "unparseable_input"
[ -z "$session" ] && quiet "unparseable_input"

# A rewake ends in another Stop. Without this guard the sentinel would inspect
# the turn it just caused and could poke again.
[ "$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null)" = "true" ] && quiet "stop_hook_active"

transcript=$(jq -r '.transcript_path // ""' <<<"$input" 2>/dev/null)
[ -z "$transcript" ] || [ ! -r "$transcript" ] && quiet "no_transcript"

# ── Fast path ────────────────────────────────────────────────────────────────
# Stop fires on EVERY stop, including the overwhelming majority of sessions that
# have no async work at all. Those must cost one tail + one grep and nothing more.
tail_file=$(mktemp "${TMPDIR:-/tmp}/orphan-sentinel.XXXXXX") || quiet "no_tmp"
trap 'rm -f "$tail_file"' EXIT
tail -n "$TAIL_LINES" "$transcript" >"$tail_file" 2>/dev/null || quiet "unreadable_transcript"
grep -qE 'task-notification|run_in_background|Monitor' "$tail_file" || quiet "no_async_records"

now=$(date +%s)
statuses_json=$(printf '%s' "$STATUSES" | jq -R 'split(",")')

# ── Candidate extraction ─────────────────────────────────────────────────────
# One jq pass over the rendered tail. Unparseable lines are dropped rather than
# aborting: a transcript can be truncated mid-write while a session is live.
# scan <vigil_start_epoch>  — 0 disables wake detection (the instant path).
# Sets $candidates (one compact JSON object per line), $scan_wake, $scan_inflight.
scan() {
  now=$(date +%s)
  tail -n "$TAIL_LINES" "$transcript" >"$tail_file" 2>/dev/null || return 1
  local out
  out=$(
  jq -R 'fromjson? // empty' <"$tail_file" 2>/dev/null | jq -cs \
    --argjson now "$now" --argjson window "$WINDOW" --argjson fwindow "$FWINDOW" \
    --argjson minage "$MIN_AGE" --argjson inflight "$INFLIGHT" \
    --argjson vstart "${1:-0}" \
    --argjson statuses "$statuses_json" '
  def ep: if . == null then 0 else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) end;
  def grab($re): ((capture($re) // {}) | .v // "");

  . as $recs
  | ($now - $window) as $floor

  # Any assistant record after a notification means the session saw it. Simple
  # and conservative on purpose: a false negative costs nothing, a false-positive
  # rewake is a self-inflicted loop.
  | ([ $recs[] | select(.type == "assistant" and (.isSidechain != true))
       | (.timestamp | ep) ] | max // 0) as $lastAsst

  # A dequeued notification was delivered; treat it as handled. The dequeue must
  # come at or after the enqueue: one Monitor task-id notifies repeatedly, so an
  # earlier handled event must not mask a later un-actioned one (real regression
  # from session 04cbaa5f, task b84t2otx3).
  | ([ $recs[] | select(.type == "queue-operation" and .operation == "remove") | . as $q
       | { task_id: (($q.content // "") | grab("<task-id>(?<v>[^<]*)</task-id>")),
           ts: ($q.timestamp | ep) } ]) as $removed

  | ([ $recs[] | select(.type == "assistant" and (.isSidechain != true)) as $r
       | (($r.message.content) // [])[]
       | select((type == "object") and .type == "tool_use")
       | { name: (.name // ""), id: (.id // ""), ts: ($r.timestamp | ep),
           bg: (.input.run_in_background) } ]) as $tools

  | ([ $tools[] | . as $t
       | select(["BashOutput","TaskOutput","TaskGet","TaskList",
                 "TaskStop","KillShell","SendMessage","Monitor"] | index($t.name))
       | $t.ts ] | max // 0) as $lastCheck

  # killed/stopped is usually a teardown the session asked for. An explicit
  # KillShell/TaskStop before the notification is evidence of intent, so that
  # notification is not an orphan. (2 of 3 lane-1 fires in a 150-session sweep.)
  | ([ $tools[] | . as $t
       | select(["KillShell","TaskStop"] | index($t.name)) | $t.ts ] | min // 0) as $firstKill

  # Lanes 1-2: notifications nobody answered.
  | ([ $recs[]
       | select(.type == "queue-operation" and .operation == "enqueue")
       | select((.content // "") | contains("<task-notification>")) as $r
       | ($r.content) as $c
       | { ts:      ($r.timestamp | ep),
           task_id: ($c | grab("<task-id>(?<v>[^<]*)</task-id>")),
           status:  ($c | grab("<status>(?<v>[^<]*)</status>")),
           summary: ($c | grab("<summary>(?<v>[^<]*)</summary>")),
           event:   ($c | grab("<event>(?<v>[^<]*)</event>")) }
       | . as $n
       | . + { kind: (if ($statuses | index($n.status)) then "failed_task"
                      elif ($n.event | contains("Monitor timed out")) then "monitor_timeout"
                      else "" end) }
       | select(.kind != "")
       | select((["killed","stopped"] | index($n.status) | not)
                or $firstKill == 0 or $firstKill > $n.ts)
       | select(.ts >= $floor and .ts > $lastAsst)
       | select([ $removed[] | select(.task_id == $n.task_id and .ts >= $n.ts) ] | length == 0)
       | { kind, task_id, ts, sleep_secs: 60,
           summary: (if .summary != "" then .summary else .event end) } ]) as $notif

  # Lane 3: launched, never checked. Keyed per launch so a session with several
  # in-flight children can still be poked about each of them (once, and within cap).
  | ([ if $inflight == 1 then
         $tools[] | . as $t
         | select(($t.name == "Bash" and $t.bg == true)
                  or ($t.name == "Agent" and $t.bg != false)
                  or ($t.name == "Monitor"))
         | select($t.ts >= ($now - $fwindow) and ($now - $t.ts) >= $minage)
         | select($t.ts > $lastCheck)
         | select([ $recs[] | select(.type == "queue-operation")
                    | select((.content // "") | contains($t.id)) ] | length == 0)
         | { kind: "inflight_bg", task_id: $t.id, ts: $t.ts, sleep_secs: 900,
             summary: ("background " + $t.name + " launched and never checked") }
       else empty end ]) as $flight

  # Has the session woken on its own? Counted, not timestamp-compared: transcript
  # timestamps have second resolution, so a record written in the same second the
  # vigil starts is indistinguishable by time. The vigil takes this count as a
  # baseline and watches it grow.
  #
  # An assistant record is unambiguous. A user record is NOT: a DELIVERED
  # notification also arrives as a user record carrying the same
  # <task-notification> XML, so counting that as user activity would stand the
  # vigil down at the exact moment it should fire. Only real typed input counts —
  # text content that is not a notification, never a tool_result-only record.
  | ([ $recs[] | select(.type == "assistant" and (.isSidechain != true)) ] | length) as $asstWake
  | ([ $recs[] | select(.type == "user" and (.isSidechain != true))
       | (.message.content) as $c
       | select(if ($c | type) == "string"
                then ($c | contains("<task-notification>") | not)
                else ([ $c[]? | select((type == "object") and .type == "text")
                        | select(.text | contains("<task-notification>") | not) ] | length > 0)
                end) ] | length) as $userWake

  | (($notif + $flight)
     | map(. + { rank: (if .kind == "failed_task" then 1
                        elif .kind == "monitor_timeout" then 2 else 3 end) })
     | sort_by(.rank, .ts)) as $all
  # Recent async footprint: has this session been receiving notifications at all?
  # This is what triggers a vigil, because a session that gets notifications can
  # get another one after it goes quiet (see the header note on subagent work).
  | ([ $recs[] | select(.type == "queue-operation" and .operation == "enqueue")
       | select((.content // "") | contains("<task-notification>"))
       | select((.timestamp | ep) >= ($now - $fwindow)) ] | length) as $asyncfoot

  | { wakecount: ($asstWake + $userWake),
      inflight: ($flight | length),
      asyncfoot: $asyncfoot,
      candidates: $all }
' 2>/dev/null)
  [ -z "$out" ] && return 1
  candidates=$(jq -c '.candidates[]?' <<<"$out" 2>/dev/null)
  scan_wakecount=$(jq -r '.wakecount' <<<"$out" 2>/dev/null)
  scan_inflight=$(jq -r '.inflight' <<<"$out" 2>/dev/null)
  scan_asyncfoot=$(jq -r '.asyncfoot' <<<"$out" 2>/dev/null)
  return 0
}

scan 0 || quiet "scan_failed"
# No candidates is not the end of the story: a session with async footprint is
# still worth watching, because the next notification may land after this Stop.
if [ -z "$candidates" ] && { [ "$VIGIL" != "1" ] || [ "${scan_asyncfoot:-0}" = "0" ]; }; then
  quiet "no_orphans"
fi

# ── Anti-loop ledger ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$STATE")" 2>/dev/null
: >>"$STATE" 2>/dev/null

sha() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 1 | cut -c1-16
  elif command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-16
  else printf '%s' "$1" | cksum | tr -d ' \n' | cut -c1-16
  fi
}

log_state() { # <json object>
  printf '%s\n' "$1" >>"$STATE" 2>/dev/null || true
}

rewoken=$(grep -F "\"session_id\":\"$session\"" "$STATE" 2>/dev/null | grep -cF '"action":"rewake"')
rewoken=$(printf '%s' "$rewoken" | tr -dc '0-9')
rewoken=${rewoken:-0}

# pick_orphan [instant] [nolog] — first candidate not already rewoken.
# "instant" drops the inflight_bg lane (vigil polls trigger only on real
# failures). "nolog" skips the suppression ledger line, so a 120-poll vigil does
# not write 120 identical suppressed_repeat rows.
pick_orphan() {
  local only="${1:-all}" logmode="${2:-log}" cand kind task_id cts key
  pick=""; pick_key=""; pick_kind=""; pick_task=""
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    kind=$(jq -r '.kind' <<<"$cand" 2>/dev/null)
    [ "$only" = "instant" ] && [ "$kind" = "inflight_bg" ] && continue
    task_id=$(jq -r '.task_id' <<<"$cand" 2>/dev/null)
    cts=$(jq -r '.ts' <<<"$cand" 2>/dev/null)
    key=$(sha "$session|$kind|$task_id|$cts")
    # One rewake per orphan, ever. Still un-actioned on a later Stop means the
    # first rewake did not work; poking again would loop.
    if grep -qF "\"orphan_key\":\"$key\"" "$STATE" 2>/dev/null; then
      [ "$logmode" = "log" ] && log_state "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg s "$session" --arg k "$key" --arg kind "$kind" --arg t "$task_id" \
        '{ts:$ts,session_id:$s,orphan_key:$k,kind:$kind,task_id:$t,action:"suppressed_repeat"}')"
      continue
    fi
    pick="$cand"; pick_key="$key"; pick_kind="$kind"; pick_task="$task_id"
    break
  done <<<"$candidates"
}

pick_orphan all log

if [ -z "$pick" ] && { [ "$VIGIL" != "1" ] || [ "${scan_asyncfoot:-0}" = "0" ]; }; then
  emit '{"decision":"suppressed","reason":"already_rewoken"}'
  exit 0
fi

# ── Vigil mode ───────────────────────────────────────────────────────────────
# A Stop hook fires when a turn ENDS, so it cannot see a notification that
# arrives while the session is already quiet — the shape of both confirmed
# incidents. When the only thing outstanding is in-flight work, stay alive and
# watch instead of firing a blind one-shot poke: poll the transcript and exit 2
# the moment a real failure lands un-actioned.
#
# Proven primitive: 24 asyncRewake deliveries across 19 days of this user's
# transcripts, 24/24 acted on, longest surviving hook sleep 3600s.
vigil_via=""
if [ "$VIGIL" = "1" ] \
   && { [ "$pick_kind" = "inflight_bg" ] || [ -z "$pick" ] || [ "${scan_asyncfoot:-0}" != "0" ]; } \
   && [ "$pick_kind" != "failed_task" ] && [ "$pick_kind" != "monitor_timeout" ]; then
  lockfile="${STATE%.jsonl}-vigil-$(printf '%s' "$session" | tr -c 'A-Za-z0-9_-' '_').lock"
  if [ -f "$lockfile" ]; then
    lpid=$(jq -r '.pid // 0' <"$lockfile" 2>/dev/null | tr -dc '0-9')
    lstart=$(jq -r '.start // 0' <"$lockfile" 2>/dev/null | tr -dc '0-9')
    # A killed hook leaves its lock behind, so liveness AND age both matter.
    if [ "${lpid:-0}" -gt 0 ] && kill -0 "${lpid}" 2>/dev/null \
       && [ $(( now - ${lstart:-0} )) -lt $(( VIGIL_MAX + VIGIL_POLL )) ]; then
      emit '{"decision":"none","reason":"vigil_already_running"}'
      exit 0
    fi
  fi
  printf '{"pid":%s,"start":%s}\n' "$$" "$now" >"$lockfile" 2>/dev/null
  trap 'rm -f "$tail_file" "$lockfile"' EXIT

  # Why this vigil exists decides how it may end early. A vigil started FOR an
  # in-flight launch is done when that work resolves; one started on async
  # footprint alone has nothing to resolve and simply watches out its window.
  if [ "$pick_kind" = "inflight_bg" ]; then vigil_start_reason=inflight
  else vigil_start_reason=footprint; fi

  vstart=$now
  wake_base=${scan_wakecount:-0}
  max_polls=$(( VIGIL_MAX / VIGIL_POLL )); [ "$max_polls" -lt 1 ] && max_polls=1
  pending=""; poll=0
  while [ "$poll" -lt "$max_polls" ]; do
    poll=$(( poll + 1 ))
    [ -n "$VIGIL_STEP" ] && "$VIGIL_STEP" "$poll" >/dev/null 2>&1
    if [ "$DRY" != "1" ]; then
      sleep "$VIGIL_POLL"
      [ $(( $(date +%s) - vstart )) -ge "$VIGIL_MAX" ] && break
    fi
    scan "$vstart" || continue
    if [ "${scan_wakecount:-0}" -gt "$wake_base" ]; then
      emit "{\"decision\":\"none\",\"reason\":\"vigil_stood_down\",\"polls\":$poll}"
      exit 0
    fi
    pick_orphan instant nolog
    if [ -n "$pick" ]; then
      # Debounce one cycle: a failure the session is actively picking up is not
      # an orphan. Only a failure that survives a full poll counts.
      if [ "$pick_key" = "$pending" ]; then vigil_via="vigil"; break; fi
      pending="$pick_key"
    else
      pending=""
      if [ "$vigil_start_reason" = "inflight" ] && [ "${scan_inflight:-0}" = "0" ]; then
        emit "{\"decision\":\"none\",\"reason\":\"vigil_all_resolved\",\"polls\":$poll}"
        exit 0
      fi
    fi
  done
  if [ -z "$vigil_via" ]; then
    emit "{\"decision\":\"none\",\"reason\":\"vigil_max_duration\",\"polls\":$poll}"
    exit 0
  fi
fi

if [ "$rewoken" -ge "$CAP" ]; then
  log_state "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$session" \
    --arg k "$pick_key" --arg kind "$pick_kind" --arg t "$pick_task" --argjson cap "$CAP" \
    '{ts:$ts,session_id:$s,orphan_key:$k,kind:$kind,task_id:$t,action:"suppressed_cap",cap:$cap}')"
  emit "{\"decision\":\"suppressed\",\"reason\":\"session_cap\",\"cap\":$CAP}"
  exit 0
fi

summary=$(jq -r '.summary' <<<"$pick" 2>/dev/null)
sleep_secs=$(jq -r '.sleep_secs' <<<"$pick" 2>/dev/null)
# A vigil already spent its wait watching, so it fires immediately.
[ -n "$vigil_via" ] && sleep_secs=0
[ -n "${ORPHAN_SENTINEL_MAX_SLEEP:-}" ] && [ "$sleep_secs" -gt "$ORPHAN_SENTINEL_MAX_SLEEP" ] \
  && sleep_secs=$ORPHAN_SENTINEL_MAX_SLEEP

if [ "$pick_kind" = "inflight_bg" ]; then
  message="Orphan sentinel: un-actioned async work — background task ${pick_task} (${summary}) was launched and no turn has checked it since. Process it now: check TaskList / BashOutput / TaskOutput for its state, act on the result, and report to the user. If it is genuinely still running, say so explicitly rather than stopping silently."
else
  message="Orphan sentinel: un-actioned async failure detected — process it now (re-arm / diagnose / report to user). Orphan: [${pick_kind}] task ${pick_task} — \"${summary}\". No assistant turn followed this notification in the transcript, so nothing has acted on it."
fi

log_state "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$session" \
  --arg k "$pick_key" --arg kind "$pick_kind" --arg t "$pick_task" \
  --argjson sl "$sleep_secs" --arg sum "$summary" --arg via "${vigil_via:-stop}" \
  '{ts:$ts,session_id:$s,orphan_key:$k,kind:$kind,task_id:$t,action:"rewake",sleep_secs:$sl,via:$via,summary:$sum}')"

if [ "$DRY" = "1" ]; then
  jq -nc --arg kind "$pick_kind" --arg t "$pick_task" --arg k "$pick_key" \
    --argjson sl "$sleep_secs" --arg sum "$summary" --arg msg "$message" \
    --arg via "${vigil_via:-stop}" --argjson polls "${poll:-0}" --arg ts "$(jq -r '.ts' <<<"$pick")" \
    '{decision:"rewake",kind:$kind,task_id:$t,key:$k,sleep_secs:$sl,ts:$ts,via:$via,polls:$polls,summary:$sum,message:$msg}'
  exit 0
fi

# Live: settings.json wires this as async + asyncRewake, so exit 2 after the
# sleep wakes the session. stderr is the model-facing channel on Stop exit 2 and
# carries the orphan-specific detail the static rewakeMessage cannot; stdout
# systemMessage surfaces the same thing to the user.
[ "$sleep_secs" -gt 0 ] && sleep "$sleep_secs"
jq -nc --arg m "$message" '{systemMessage: $m}'
printf '%s\n' "$message" >&2
exit 2
