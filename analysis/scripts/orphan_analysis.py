#!/usr/bin/env python3
"""
Analyze Claude Code session transcripts for orphaned/hung background tasks.

Background task launches:
  - Agent tool_use with input.run_in_background == true
      -> tool_result has toolUseResult.agentId (task-id), status "async_launched"
  - Bash tool_use with input.run_in_background == true
      -> tool_result has toolUseResult.backgroundTaskId (task-id)

Notifications arrive as `queue-operation` events (any operation type) whose
`content` field contains a `<task-notification>` block with a `<task-id>`.
These can land in a DIFFERENT file than the launch (e.g. a subagent launches
a background Bash, but the notification is delivered to the top-level
session file). So we group all files that share a sessionId (main file +
its subagents/*.jsonl) into one "session group" and match task-ids within
the group, not just within a single file.
"""
import json
import os
import re
import glob
import statistics
from datetime import datetime, timezone
from collections import defaultdict

ROOT = os.path.expanduser("~/.claude/projects")
CUTOFF_DAYS = 21
NOW = datetime.now(timezone.utc)

def parse_ts(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None

def session_group_key(path):
    """Group files by top-level sessionId: main file X.jsonl and X/subagents/*.jsonl share group X."""
    parts = path.split(os.sep)
    if "subagents" in parts:
        idx = parts.index("subagents")
        # parent dir name is the session id
        return parts[idx - 1]
    return os.path.splitext(os.path.basename(path))[0]

TASK_NOTIF_RE = re.compile(
    r"<task-id>(?P<id>[^<]+)</task-id>.*?<status>(?P<status>[^<]+)</status>(?:.*?<summary>(?P<summary>.*?)</summary>)?",
    re.DOTALL,
)

def find_files():
    all_files = glob.glob(os.path.join(ROOT, "**", "*.jsonl"), recursive=True)
    out = []
    for f in all_files:
        try:
            mtime = os.path.getmtime(f)
        except OSError:
            continue
        age_days = (NOW.timestamp() - mtime) / 86400
        if age_days <= CUTOFF_DAYS:
            out.append(f)
    return out

def main():
    files = find_files()
    print(f"Files in corpus: {len(files)}")

    # group -> list of files
    groups = defaultdict(list)
    for f in files:
        groups[session_group_key(f)].append(f)

    # per group: launches[task_id] = dict, notifications[task_id] = list of (ts, status, summary, file)
    all_launches = {}  # task_id -> launch info (global, task ids should be unique)
    all_notifications = defaultdict(list)  # task_id -> list of (ts, status, summary, file)
    group_last_ts = {}  # group -> last timestamp seen anywhere in group
    group_files_map = {}  # group -> list of files (for reporting)

    for group, flist in groups.items():
        group_files_map[group] = flist
        last_ts = None
        for f in flist:
            try:
                with open(f, errors="replace") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        # cheap prefilter
                        has_bg_marker = "run_in_background" in line
                        has_queue_op = '"type":"queue-operation"' in line or '"type": "queue-operation"' in line
                        has_notif = "task-notification" in line
                        has_resolve_marker = "agentId" in line or "backgroundTaskId" in line
                        if not (has_bg_marker or has_queue_op or has_notif or has_resolve_marker):
                            # still need last_ts tracking; do light timestamp scan
                            m = re.search(r'"timestamp"\s*:\s*"([^"]+)"', line)
                            if m:
                                ts = parse_ts(m.group(1))
                                if ts and (last_ts is None or ts > last_ts):
                                    last_ts = ts
                            continue
                        try:
                            d = json.loads(line)
                        except Exception:
                            continue

                        ts_top = parse_ts(d.get("timestamp"))
                        if ts_top and (last_ts is None or ts_top > last_ts):
                            last_ts = ts_top

                        # --- notifications ---
                        if d.get("type") == "queue-operation":
                            content = d.get("content")
                            if isinstance(content, str) and "task-notification" in content:
                                for m in TASK_NOTIF_RE.finditer(content):
                                    tid = m.group("id").strip()
                                    status = m.group("status").strip()
                                    summary = (m.group("summary") or "").strip()
                                    all_notifications[tid].append(
                                        (ts_top, status, summary, f, d.get("operation"))
                                    )
                            continue

                        # --- launches ---
                        if d.get("type") == "assistant":
                            msg = d.get("message", {})
                            content_list = msg.get("content", [])
                            if not isinstance(content_list, list):
                                continue
                            for c in content_list:
                                if not isinstance(c, dict) or c.get("type") != "tool_use":
                                    continue
                                inp = c.get("input", {})
                                if not isinstance(inp, dict) or not inp.get("run_in_background"):
                                    continue
                                name = c.get("name")
                                tool_use_id = c.get("id")
                                launch_ts = ts_top or parse_ts(d.get("timestamp"))
                                desc = inp.get("description") or inp.get("command") or ""
                                cmd = inp.get("command") or inp.get("prompt", "")[:200]
                                # stash pending launch keyed by tool_use_id; resolve task id from
                                # the subsequent tool_result (user message) which we scan next
                                all_launches.setdefault("_pending", {})[tool_use_id] = {
                                    "name": name,
                                    "description": desc,
                                    "command": cmd,
                                    "launch_ts": launch_ts,
                                    "file": f,
                                    "group": group,
                                }
                            continue

                        # --- resolve tool_use_id -> task_id via tool_result ---
                        if d.get("type") == "user":
                            msg = d.get("message", {})
                            content_list = msg.get("content", [])
                            if not isinstance(content_list, list):
                                continue
                            tur = d.get("toolUseResult")
                            if not isinstance(tur, dict):
                                continue
                            agent_id = tur.get("agentId")
                            bg_id = tur.get("backgroundTaskId")
                            task_id = agent_id or bg_id
                            if not task_id:
                                continue
                            for c in content_list:
                                if not isinstance(c, dict) or c.get("type") != "tool_result":
                                    continue
                                tool_use_id = c.get("tool_use_id")
                                pending = all_launches.get("_pending", {})
                                launch = pending.pop(tool_use_id, None)
                                if launch is None:
                                    continue
                                launch["task_id"] = task_id
                                launch["kind"] = "Agent" if agent_id else "Bash"
                                all_launches[task_id] = launch
            except Exception as e:
                print(f"ERROR reading {f}: {e}")
        group_last_ts[group] = last_ts

    # drop the pending bucket (unmatched tool_use_id -> tool_result, shouldn't happen much)
    unresolved_pending = all_launches.pop("_pending", {})

    launches = {k: v for k, v in all_launches.items() if k != "_pending"}

    print(f"\nTotal background launches resolved to task-id: {len(launches)}")
    print(f"Unresolved launch->task_id (no matching tool_result seen): {len(unresolved_pending)}")
    print(f"Total distinct task-ids with >=1 notification: {len(all_notifications)}")

    # classify
    orphans = []
    resolved = []
    for tid, launch in launches.items():
        notifs = all_notifications.get(tid)
        if not notifs:
            orphans.append((tid, launch))
        else:
            notifs_sorted = sorted([n for n in notifs if n[0] is not None], key=lambda x: x[0])
            first = notifs_sorted[0] if notifs_sorted else notifs[0]
            resolved.append((tid, launch, first))

    print(f"\nORPHANS (launched, never notified): {len(orphans)}")
    print(f"RESOLVED (launched, notified at least once): {len(resolved)}")
    if launches:
        print(f"Orphan rate: {len(orphans)/len(launches)*100:.1f}%")

    # latency distribution for resolved, split by status
    latencies_by_status = defaultdict(list)
    for tid, launch, (ts, status, summary, f, op) in resolved:
        lts = launch.get("launch_ts")
        if lts and ts:
            secs = (ts - lts).total_seconds()
            if secs >= 0:
                latencies_by_status[status].append(secs)

    print("\n--- Time-to-notification distribution by status ---")
    for status, vals in sorted(latencies_by_status.items(), key=lambda x: -len(x[1])):
        vals_sorted = sorted(vals)
        n = len(vals_sorted)
        med = statistics.median(vals_sorted)
        p90 = vals_sorted[int(n * 0.9)] if n > 1 else vals_sorted[0]
        mx = max(vals_sorted)
        over_30 = sum(1 for v in vals_sorted if v > 1800)
        print(f"{status:12s} n={n:4d}  median={med/60:6.1f}min  p90={p90/60:6.1f}min  max={mx/60:7.1f}min  >30min={over_30}")

    # classify orphans as expected (server/watch/tail) vs lost work
    SERVER_KEYWORDS = re.compile(
        r"\b(serve|vite|webpack|next dev|npm run dev|yarn dev|sls offline|watch|tail -f|"
        r"nodemon|dev server|localhost|listen|--watch|air\b|hot.?reload)\b", re.IGNORECASE
    )
    def classify(launch):
        text = f"{launch.get('description','')} {launch.get('command','')}"
        if SERVER_KEYWORDS.search(text):
            return "expected-orphan (server/watch/tail)"
        return "lost-work (test/deploy/poll/agent)"

    class_counts = defaultdict(int)
    for tid, launch in orphans:
        class_counts[classify(launch)] += 1
    print("\n--- Orphan classification ---")
    for k, v in class_counts.items():
        print(f"{k}: {v}")

    # orphans per session group
    orphans_per_group = defaultdict(list)
    for tid, launch in orphans:
        orphans_per_group[launch["group"]].append((tid, launch))

    print("\n--- Top 15 sessions by orphan count ---")
    top_groups = sorted(orphans_per_group.items(), key=lambda x: -len(x[1]))[:15]
    for group, items in top_groups:
        print(f"\nGroup {group}  ({len(items)} orphans, {len(group_files_map.get(group))} files in group)")
        for tid, launch in items[:5]:
            lts = launch.get("launch_ts")
            print(f"    task={tid} kind={launch.get('kind')} launch_ts={lts} desc={launch.get('description','')[:100]!r}")

    # sessions ended while non-server task still running (orphan launched near end of group's activity)
    print("\n--- Sessions that ended with a non-server orphan still pending ---")
    ended_with_pending = []
    for tid, launch in orphans:
        cls = classify(launch)
        if cls.startswith("expected-orphan"):
            continue
        group = launch["group"]
        last_ts = group_last_ts.get(group)
        lts = launch.get("launch_ts")
        if last_ts and lts:
            ended_with_pending.append((group, tid, launch, last_ts, lts))

    for group, tid, launch, last_ts, lts in ended_with_pending[:30]:
        print(f"group={group} task={tid} launched={lts} session_last_activity={last_ts} desc={launch.get('description','')[:90]!r}")

    print(f"\nTotal non-server orphans where session had further/last activity tracked: {len(ended_with_pending)}")

    # dump full orphan list + resolved list to json for further sampling
    out_path = "./scratch/orphan_results.json"
    def ser_launch(l):
        d = dict(l)
        if d.get("launch_ts"):
            d["launch_ts"] = d["launch_ts"].isoformat()
        return d

    with open(out_path, "w") as fh:
        json.dump({
            "orphans": [{"task_id": tid, **ser_launch(l)} for tid, l in orphans],
            "resolved_count": len(resolved),
            "group_last_ts": {g: (ts.isoformat() if ts else None) for g, ts in group_last_ts.items()},
        }, fh, indent=2)
    print(f"\nWrote detail to {out_path}")

if __name__ == "__main__":
    main()
