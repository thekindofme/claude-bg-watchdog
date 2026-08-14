#!/usr/bin/env bash
# Stop hook (asyncRewake) — auto-resume after usage-limit / overload stalls.
# Audit 2026-07-24: 18% of background failures were subagents dying on
# "session limit · resets Npm" or 529 Overloaded; the session then sat idle
# until Yasith manually typed "cont" (~10+ min dead time, daily recurrence).
# This hook runs async on Stop: if the last assistant message shows such a
# death, sleep until the limit likely reset, then exit 2 -> rewake the model.
set -u

input=$(cat)
last=$(jq -r '.last_assistant_message // ""' <<<"$input" 2>/dev/null)
[ -z "$last" ] && exit 0

sleep_secs=0

if echo "$last" | grep -qiE '(session|usage) limit'; then
  # Try to parse "resets 5pm" / "resets 12:30pm" style (local time).
  reset=$(echo "$last" | grep -oiE 'resets[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | head -1 | sed -E 's/resets[[:space:]]+//I')
  if [ -n "$reset" ]; then
    hh=$(echo "$reset" | grep -oE '^[0-9]{1,2}')
    mm=$(echo "$reset" | grep -oE ':[0-9]{2}' | tr -d ':')
    ap=$(echo "$reset" | grep -oiE '(am|pm)' | tr '[:upper:]' '[:lower:]')
    mm=${mm:-0}
    [ "$ap" = "pm" ] && [ "$hh" -lt 12 ] && hh=$((hh + 12))
    [ "$ap" = "am" ] && [ "$hh" -eq 12 ] && hh=0
    now=$(date +%s)
    target=$(date -j -f "%H:%M:%S" "$(printf '%02d:%02d:00' "$hh" "$mm")" +%s 2>/dev/null || echo 0)
    if [ "$target" -gt 0 ]; then
      [ "$target" -le "$now" ] && target=$((target + 86400))
      sleep_secs=$((target - now + 120))   # 2 min past the reset
    fi
  fi
  # Parse failed or absurd -> fall back to 1h; cap at 6h.
  [ "$sleep_secs" -le 0 ] && sleep_secs=3600
  [ "$sleep_secs" -gt 21600 ] && sleep_secs=21600
elif echo "$last" | grep -qE '529|Overloaded|rate.?limit'; then
  sleep_secs=180
fi

[ "$sleep_secs" -le 0 ] && exit 0

sleep "$sleep_secs"
exit 2
