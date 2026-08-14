#!/usr/bin/env bash
# Stop hook (asyncRewake) — auto-resume after usage-limit / overload stalls.
# Audit 2026-07-24: 18% of background failures were subagents dying on
# "session limit · resets Npm" or 529 Overloaded; the session then sat idle
# until Yasith manually typed "cont" (~10+ min dead time, daily recurrence).
# This hook runs async on Stop: if the turn ended on such a death, sleep until
# the limit likely reset, then exit 2 -> rewake the model.
#
# What counts as a death (audit 2026-08-12): the final message must START with a
# real harness error string, optionally behind an "Agent failed: " wrapper — the
# old unanchored match rewoke the session after ordinary reports that merely
# discussed rate limits. When the PARENT's own message is ordinary but a SUBAGENT
# died, the corroborating signal is a fresh genuine entry in
# ~/.claude/logs/subagent-deaths.jsonl for this session (an entry written by
# bg-watchdog-subagent-stop.sh, carrying a `signal` field; legacy entries only
# count if their tail is itself anchored).
#
# Reset-time parsing handles 12-hour ("resets 5pm", "resets 8:20pm"), 24-hour
# ("resets 17:00"), and relative ("resets in 45 minutes", "in 2 hours") forms,
# with any trailing "(Australia/Melbourne)" style zone stripped. Reset times are
# read as LOCAL wall-clock, which is how the harness prints them. Unparseable ->
# 1h fallback; every wait is capped at 6h; 2 min of margin is added past a parsed
# reset; a 529/Overloaded uses a flat 180s.
#
# Test seams (documented, no effect in normal operation):
#   DRY_RUN=1               print "sleep_secs=<n> signal=<what fired>" and exit 0
#                           instead of sleeping and exiting 2.
#   BG_WATCHDOG_NOW=<epoch> freeze "now" so the arithmetic is deterministic.
set -u

input=$(cat)
last=$(jq -r '.last_assistant_message // ""' <<<"$input" 2>/dev/null)
session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null)

now=${BG_WATCHDOG_NOW:-$(date +%s)}
LEDGER="$HOME/.claude/logs/subagent-deaths.jsonl"

# classify <text> -> "limit" | "overload" | "" (not a death)
classify() {
  local t
  t=$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/^(Agent|Subagent) failed:[[:space:]]*//')
  case "$t" in
    "You've hit your session limit"*|"You've hit your usage limit"*|\
    "You've reached your"*|"Claude AI usage limit reached"*) echo limit ;;
    "API Error"*) echo overload ;;
    *) echo "" ;;
  esac
}

# reset_secs <text> -> seconds to wait, or 0 when no reset time could be read
reset_secs() {
  local text clean hh mm ap n unit target today
  text="$1"
  # Drop a trailing zone so it cannot be mistaken for part of the time.
  clean=$(printf '%s' "$text" | sed -E 's/\([A-Za-z_]+\/[A-Za-z_]+\)//g; s/\b(UTC|GMT|AEST|AEDT|PST|PDT|EST|EDT)\b//g')

  # Relative: "resets in 45 minutes" / "in 2 hours".
  n=$(printf '%s' "$clean" | grep -oiE 'in[[:space:]]+[0-9]+[[:space:]]*(minutes?|mins?|hours?|hrs?|seconds?|secs?)' | head -1)
  if [ -n "$n" ]; then
    unit=$(printf '%s' "$n" | grep -oiE '(minutes?|mins?|hours?|hrs?|seconds?|secs?)$' | tr '[:upper:]' '[:lower:]')
    n=$(printf '%s' "$n" | grep -oE '[0-9]+' | head -1)
    case "$unit" in
      h*) n=$(( n * 3600 )) ;;
      m*) n=$(( n * 60 )) ;;
    esac
    echo $(( n + 120 ))                   # same 2 min of margin as an absolute time
    return
  fi

  # Absolute 12-hour: "resets 5pm" / "resets 8:20pm".
  local t12 t24
  t12=$(printf '%s' "$clean" | grep -oiE 'resets[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | head -1)
  # Absolute 24-hour: "resets 17:00" (a colon is required, so "resets 5" is not a time).
  t24=$(printf '%s' "$clean" | grep -oiE 'resets[[:space:]]+[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?([[:space:]]*(am|pm))?' | head -1)

  if [ -n "$t12" ]; then
    hh=$(printf '%s' "$t12" | grep -oE '[0-9]{1,2}' | head -1)
    mm=$(printf '%s' "$t12" | grep -oE ':[0-9]{2}' | head -1 | tr -d ':')
    ap=$(printf '%s' "$t12" | grep -oiE '(am|pm)' | tr '[:upper:]' '[:lower:]')
    mm=${mm:-0}
    hh=$((10#$hh)); mm=$((10#$mm))
    [ "$ap" = "pm" ] && [ "$hh" -lt 12 ] && hh=$((hh + 12))
    [ "$ap" = "am" ] && [ "$hh" -eq 12 ] && hh=0
  elif [ -n "$t24" ]; then
    hh=$(printf '%s' "$t24" | grep -oE '[0-9]{1,2}:' | head -1 | tr -d ':')
    mm=$(printf '%s' "$t24" | grep -oE ':[0-9]{2}' | head -1 | tr -d ':')
    hh=$((10#$hh)); mm=$((10#${mm:-0}))
    [ "$hh" -gt 23 ] && { echo 0; return; }
  else
    echo 0
    return
  fi

  today=$(date -j -r "$now" +%Y-%m-%d 2>/dev/null) || { echo 0; return; }
  target=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today $(printf '%02d:%02d:00' "$hh" "$mm")" +%s 2>/dev/null || echo 0)
  [ "$target" -le 0 ] && { echo 0; return; }
  [ "$target" -le "$now" ] && target=$((target + 86400))
  echo $(( target - now + 120 ))          # 2 min past the reset
}

# Fresh, genuine subagent death recorded for THIS session -> that text decides.
ledger_death() {
  [ -f "$LEDGER" ] || return 0
  [ -n "$session" ] || return 0
  tail -50 "$LEDGER" 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue
    sid=$(jq -r '.session_id // ""' <<<"$line" 2>/dev/null)
    [ "$sid" = "$session" ] || continue
    ts=$(jq -r '.ts // ""' <<<"$line" 2>/dev/null)
    epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)
    [ "$epoch" -gt 0 ] || continue
    [ $(( now - epoch )) -le 900 ] || continue        # stale entries do not rewake
    sig=$(jq -r '.signal // ""' <<<"$line" 2>/dev/null)
    tail_txt=$(jq -r '.tail // ""' <<<"$line" 2>/dev/null)
    if [ -z "$sig" ] && [ -z "$(classify "$tail_txt")" ]; then
      continue                                        # legacy noise entry
    fi
    [ -n "$(classify "$tail_txt")" ] || continue
    printf '%s' "$tail_txt"
    break
  done
}

signal=""
text=""
kind=$(classify "$last")
if [ -n "$kind" ]; then
  signal="stop-message"
  text="$last"
else
  text=$(ledger_death)
  if [ -n "$text" ]; then
    kind=$(classify "$text")
    signal="ledger"
  fi
fi

sleep_secs=0
case "$kind" in
  limit)
    sleep_secs=$(reset_secs "$text")
    [ "$sleep_secs" -le 0 ] && sleep_secs=3600      # unparseable -> 1h
    [ "$sleep_secs" -gt 21600 ] && sleep_secs=21600 # cap at 6h
    ;;
  overload)
    sleep_secs=180
    ;;
esac

if [ -n "${DRY_RUN:-}" ]; then
  echo "sleep_secs=$sleep_secs signal=${signal:-none}"
  exit 0
fi

[ "$sleep_secs" -le 0 ] && exit 0

sleep "$sleep_secs"
exit 2
