#!/usr/bin/env python3
"""Turn a real Claude Code transcript tail into a synthetic one.

Allow-list only: keeps record types, timestamps, sidechain flags, queue
operations, notification structure (task-id, tool-use-id, status, event) and
tool_use names / ids / run_in_background. Every id is replaced with a stable
fake, and every piece of free text is replaced with filler.

Usage: synth_transcript.py <real.jsonl> <out.jsonl> [tail_lines]
"""
import hashlib, json, re, sys

SRC, DST = sys.argv[1], sys.argv[2]
TAIL = int(sys.argv[3]) if len(sys.argv) > 3 else 300
SESSION = "00000000-0000-4000-8000-000000000001"

_ids, _labels = {}, {}

def fake_id(real, prefix):
    if not real:
        return real
    if real not in _ids:
        h = hashlib.sha256(real.encode()).hexdigest()
        _ids[real] = prefix + h[: max(8, len(real) - len(prefix))]
    return _ids[real]

def label(task_id):
    if task_id not in _labels:
        _labels[task_id] = f"Synthetic task {len(_labels) + 1}"
    return _labels[task_id]

def tag(c, name):
    m = re.search(rf"<{name}>(.*?)</{name}>", c, re.S)
    return m.group(1) if m else None

def notification(c):
    tid = tag(c, "task-id") or ""
    tuid = tag(c, "tool-use-id")
    status = tag(c, "status")
    event = tag(c, "event")
    summary = tag(c, "summary") or ""
    ftid = fake_id(tid, "t")
    name = label(ftid)
    if "stalled" in summary.lower():
        s = f'Agent "{name}" failed: Agent stalled: no progress for 600s (stream watchdog did not recover)'
    elif status:
        s = f'Background task "{name}" {status}'
    else:
        s = f'"{name}" event'
    parts = ["<task-notification>", f"<task-id>{ftid}</task-id>"]
    if tuid is not None:
        parts.append(f"<tool-use-id>{fake_id(tuid, 'toolu_')}</tool-use-id>")
    if status is not None:
        parts.append(f"<status>{status}</status>")
    if event is not None:
        ev = "[Monitor timed out — re-arm if needed.]" if "Monitor timed out" in event else "synthetic monitor event"
        parts.append(f"<event>{ev}</event>")
    parts.append(f"<summary>{s}</summary>")
    parts.append("</task-notification>")
    return "\n".join(parts)

def text_or_notif(t, filler):
    return notification(t) if "<task-notification>" in t else filler

def tool_use(item):
    inp = item.get("input") or {}
    out_in = {"description": "synthetic"}
    if "run_in_background" in inp:
        out_in["run_in_background"] = inp["run_in_background"]
    if item.get("name") == "Bash":
        out_in["command"] = "sleep 1"
    return {"type": "tool_use", "id": fake_id(item.get("id", ""), "toolu_"),
            "name": item.get("name", ""), "input": out_in}

def convert(rec):
    out = {"type": rec.get("type"), "timestamp": rec.get("timestamp"), "sessionId": SESSION}
    if "isSidechain" in rec:
        out["isSidechain"] = rec["isSidechain"]
    t = rec.get("type")
    if t == "queue-operation":
        out["operation"] = rec.get("operation")
        c = rec.get("content")
        if isinstance(c, str):
            out["content"] = text_or_notif(c, "synthetic queued prompt")
    elif t in ("assistant", "user"):
        msg = rec.get("message") or {}
        c = msg.get("content")
        if isinstance(c, str):
            nc = text_or_notif(c, "synthetic user message" if t == "user" else "synthetic reply")
        else:
            nc = []
            for item in c or []:
                if not isinstance(item, dict):
                    continue
                it = item.get("type")
                if it == "tool_use":
                    nc.append(tool_use(item))
                elif it == "tool_result":
                    nc.append({"type": "tool_result", "tool_use_id": fake_id(item.get("tool_use_id", ""), "toolu_"), "content": "ok"})
                elif it == "text":
                    nc.append({"type": "text", "text": text_or_notif(item.get("text", ""), "synthetic text")})
                elif it == "thinking":
                    nc.append({"type": "thinking", "thinking": "synthetic"})
        out["message"] = {"role": msg.get("role", t), "content": nc}
    return out

with open(SRC) as f:
    lines = f.readlines()[-TAIL:]
with open(DST, "w") as f:
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        f.write(json.dumps(convert(rec), ensure_ascii=False) + "\n")
