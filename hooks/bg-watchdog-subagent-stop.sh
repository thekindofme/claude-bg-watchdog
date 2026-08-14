#!/usr/bin/env bash
# SubagentStop — ledger + surface subagents that died on a harness error.
# Audit 2026-07-24: ~3% of subagents end on a crash (529/session-limit) and the
# death is only noticed hours later. Log to ~/.claude/logs/subagent-deaths.jsonl
# and emit a systemMessage so it is visible immediately.
#
# Detection is STRUCTURAL, read from the subagent's own transcript
# (`agent_transcript_path`), not from substrings in its prose. Audit 2026-08-12:
# the old unanchored match over the final message logged any agent that merely
# DISCUSSED these terms — 32 of the 33 live ledger entries were that noise.
#
# A genuine death is the transcript's final substantive record carrying
# `isApiErrorMessage: true` and/or `apiErrorStatus`, or a top-level `error` on a
# record whose message.model is the literal "<synthetic>". Verified over 2142
# transcripts under ~/.claude/projects/*/*/subagents/agent-*.jsonl: rate_limit/429
# (39x), server_error/529 (14x), server_error/no-status (11x).
# Fallback when the transcript is missing: the final message must START with a
# real harness error string (optionally behind an "Agent failed: " wrapper).
#
# Ledger schema is append-only compatible: ts, agent_id, agent_type, session_id,
# tail as before, plus `signal` naming which marker fired (and error_kind /
# api_error_status when the transcript supplied them).
set -u

input=$(cat)
export BGWD_INPUT="$input"

last=$(jq -r '.last_assistant_message // ""' <<<"$input" 2>/dev/null)

read -r -d '' BGWD_PY <<'PYEOF' || true
import json, os, re, sys

try:
    data = json.loads(os.environ.get("BGWD_INPUT", ""))
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)

SKIP_TYPES = {"attachment", "system", "summary", "progress", "hook"}
verdict = {}

path = data.get("agent_transcript_path") or ""
if path and os.path.isfile(path):
    try:
        with open(path, "r", errors="replace") as fh:
            lines = [ln for ln in fh.read().splitlines() if ln.strip()]
    except OSError:
        lines = []
    for raw in reversed(lines[-25:]):
        try:
            rec = json.loads(raw)
        except Exception:
            continue
        if not isinstance(rec, dict) or rec.get("type") in SKIP_TYPES:
            continue
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
        status = rec.get("apiErrorStatus")
        kind = rec.get("error") if isinstance(rec.get("error"), str) else None
        synthetic = msg.get("model") == "<synthetic>"
        if status is not None:
            verdict = {"signal": "apiErrorStatus:%s" % status}
        elif rec.get("isApiErrorMessage") is True:
            verdict = {"signal": "isApiErrorMessage"}
        elif kind and synthetic:
            verdict = {"signal": "synthetic-error:%s" % kind}
        if verdict:
            if kind:
                verdict["error_kind"] = kind
            if status is not None:
                verdict["api_error_status"] = status
        break          # only the final substantive record decides

if not verdict:
    # Anchored text fallback. Real harness death messages ARE the whole message,
    # so they can only open it; a report quoting them never does.
    last = (data.get("last_assistant_message") or "").strip()
    last = re.sub(r"^(Agent failed:|Subagent failed:)\s*", "", last)
    ANCHORS = (
        "API Error",
        "You've hit your session limit",
        "You've hit your usage limit",
        "You've reached your",
        "Claude AI usage limit reached",
    )
    if any(last.startswith(a) for a in ANCHORS):
        verdict = {"signal": "text-anchored"}

if verdict:
    print(json.dumps(verdict))
PYEOF

verdict=$(printf '%s\n' "$BGWD_PY" | python3 - 2>/dev/null)
[ -z "$verdict" ] && exit 0

signal=$(jq -r '.signal // "unknown"' <<<"$verdict" 2>/dev/null)

mkdir -p "$HOME/.claude/logs"
jq -c --argjson v "$verdict" '{ts: (now | todate), agent_id: (.agent_id // ""), agent_type: (.agent_type // ""), session_id: (.session_id // ""), tail: ((.last_assistant_message // "") | .[-300:])} + $v' \
  <<<"$input" >> "$HOME/.claude/logs/subagent-deaths.jsonl" 2>/dev/null

tail_msg=$(echo "$last" | tail -c 200 | tr '\n' ' ')
jq -nc --arg t "$tail_msg" --arg s "$signal" '{systemMessage: ("⚠️ Subagent died (" + $s + ") — logged to ~/.claude/logs/subagent-deaths.jsonl. Resume it via SendMessage once the cause clears: " + $t)}'
exit 0
