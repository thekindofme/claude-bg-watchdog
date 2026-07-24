import json, re, sys, os
from collections import Counter, defaultdict

SCRATCH = "./scratch"

with open(f"{SCRATCH}/all_files.txt") as fh:
    all_files = [l.strip() for l in fh if l.strip()]

ERROR_PATTERNS = [
    ("terminal_api_error", re.compile(r"terminal API error", re.I)),
    ("agent_died", re.compile(r"agent died", re.I)),
    ("api_error_generic", re.compile(r"\bAPI [Ee]rror\b")),
    ("overloaded", re.compile(r"[Oo]verloaded")),
    ("rate_limit", re.compile(r"rate.?limit", re.I)),
    ("aborted", re.compile(r"\baborted\b", re.I)),
    ("was_skipped", re.compile(r"was skipped", re.I)),
    ("returned_null", re.compile(r"returned null", re.I)),
    ("did_not_return", re.compile(r"did not return", re.I)),
    ("no_response", re.compile(r"no response", re.I)),
    ("context_low", re.compile(r"context (is )?(running )?low", re.I)),
    ("ran_out_of_context", re.compile(r"ran out of context", re.I)),
    ("not_found_agent", re.compile(r"agent.{0,20}not found|no such agent", re.I)),
    ("already_completed", re.compile(r"already completed", re.I)),
]

FRUSTRATION_PATTERNS = re.compile(
    r"still running|stuck|hung\b|died\b|taking forever|what happened to|never came back|gave up|try again|come on|wtf|why (is|did|does) (it|this|that)|timed out|timing out",
    re.I
)

agent_tool_names = {"Agent", "Workflow"}
followup_tool_names = {"SendMessage", "TaskOutput", "TaskGet", "TaskList", "TaskStop", "Monitor"}

error_tally = Counter()
agent_calls_total = 0
agent_calls_matched_error = 0
agent_calls_never_returned = 0
agent_calls_ok = 0
followup_error_hits = []  # (file, snippet)
frustration_quotes = []   # (file, ts, text)
workflow_hits = []
never_returned_examples = []
error_examples = defaultdict(list)

def get_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict):
                if "content" in c and isinstance(c["content"], str):
                    parts.append(c["content"])
                elif "content" in c and isinstance(c["content"], list):
                    for cc in c["content"]:
                        if isinstance(cc, dict) and cc.get("type") == "text":
                            parts.append(cc.get("text",""))
                elif c.get("type") == "text":
                    parts.append(c.get("text",""))
        return "\n".join(parts)
    return str(content)

for fi, fpath in enumerate(all_files):
    is_subagent = "/subagents/" in fpath
    pending_agent_calls = {}  # tool_use_id -> info
    try:
        with open(fpath, errors="replace") as fh:
            for lineno, line in enumerate(fh):
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                dtype = d.get("type")
                ts = d.get("timestamp")
                msg = d.get("message", {})
                content = msg.get("content")

                if dtype == "assistant" and isinstance(content, list):
                    for c in content:
                        if not isinstance(c, dict):
                            continue
                        if c.get("type") == "tool_use":
                            name = c.get("name")
                            if name in agent_tool_names:
                                agent_calls_total += 1
                                inp = c.get("input", {})
                                pending_agent_calls[c.get("id")] = {
                                    "file": fpath, "lineno": lineno, "ts": ts,
                                    "name": name,
                                    "subagent_type": inp.get("subagent_type"),
                                    "agent_name": inp.get("name"),
                                    "model": inp.get("model"),
                                    "description": inp.get("description"),
                                }
                            if "wf_" in json.dumps(inp) if name in agent_tool_names else False:
                                pass

                if dtype == "user":
                    if isinstance(content, str):
                        # real human-typed message (or system reminder as string)
                        if not content.lstrip().startswith("<system-reminder") and not content.lstrip().startswith("Caveat:"):
                            if FRUSTRATION_PATTERNS.search(content):
                                frustration_quotes.append((fpath, ts, content[:300].replace("\n"," ")))
                    elif isinstance(content, list):
                        for c in content:
                            if not isinstance(c, dict):
                                continue
                            if c.get("type") == "tool_result":
                                tuid = c.get("tool_use_id")
                                is_err = c.get("is_error", False)
                                text = get_text(c.get("content"))
                                if tuid in pending_agent_calls:
                                    info = pending_agent_calls.pop(tuid)
                                    matched = False
                                    if is_err:
                                        error_tally["is_error_true"] += 1
                                        matched = True
                                        if len(error_examples["is_error_true"]) < 15:
                                            error_examples["is_error_true"].append((fpath, ts, info, text[:300]))
                                    for label, pat in ERROR_PATTERNS:
                                        if pat.search(text):
                                            error_tally[label] += 1
                                            matched = True
                                            if len(error_examples[label]) < 15:
                                                error_examples[label].append((fpath, ts, info, text[:300]))
                                    if matched:
                                        agent_calls_matched_error += 1
                                    else:
                                        agent_calls_ok += 1
                                # followup tool errors (SendMessage/TaskGet etc referencing agents)
                                # we detect via text content matching stall phrases, regardless of matching a pending agent call
                                if re.search(r"\bnot found\b|already completed|no such agent|no active agent", text, re.I):
                                    followup_error_hits.append((fpath, ts, tuid, text[:250]))
    except Exception as e:
        continue

    # any agent calls still pending at EOF = never returned
    for tuid, info in pending_agent_calls.items():
        agent_calls_never_returned += 1
        if len(never_returned_examples) < 30:
            never_returned_examples.append(info)

print("=== AGENT/WORKFLOW TOOL CALL TOTALS ===")
print("total agent/workflow calls:", agent_calls_total)
print("matched with error signal:", agent_calls_matched_error)
print("never returned (no matching tool_result by EOF):", agent_calls_never_returned)
print("ok:", agent_calls_ok)
print()
print("=== ERROR TYPE TALLY (near Agent/Workflow tool_result) ===")
for label, cnt in error_tally.most_common():
    print(f"{label}: {cnt}")
print()
print("=== FOLLOWUP/ORCHESTRATION STALL HITS ===", len(followup_error_hits))
for h in followup_error_hits[:20]:
    print(h)
print()
print("=== NEVER RETURNED EXAMPLES (up to 30) ===")
for e in never_returned_examples:
    print(e)
print()
print("=== FRUSTRATION QUOTES ===", len(frustration_quotes))
for q in frustration_quotes[:40]:
    print(q)
print()
print("=== ERROR EXAMPLES (sample per type) ===")
for label, examples in error_examples.items():
    print(f"--- {label} ---")
    for ex in examples[:5]:
        print(ex)
    print()
