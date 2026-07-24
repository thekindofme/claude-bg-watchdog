import json, random

SCRATCH = "./scratch"
with open(f"{SCRATCH}/subagent_files.txt") as fh:
    files = [l.strip() for l in fh if l.strip()]

random.seed(42)
sample = random.sample(files, min(150, len(files)))

results = {"clean": 0, "clean_structured_output": 0, "abnormal_midtool": 0, "abnormal_dangling_result": 0, "abnormal_error": 0, "abnormal_user_interrupt": 0, "empty_or_unparseable": 0}
abnormal_examples = []

for fpath in sample:
    try:
        with open(fpath, errors="replace") as fh:
            lines = [l.strip() for l in fh if l.strip()]
        if not lines:
            results["empty_or_unparseable"] += 1
            continue
        # parse last 5 lines
        parsed = []
        for l in lines[-8:]:
            try:
                parsed.append(json.loads(l))
            except Exception:
                pass
        if not parsed:
            results["empty_or_unparseable"] += 1
            continue
        last = parsed[-1]
        ltype = last.get("type")
        msg = last.get("message", {})
        content = msg.get("content")

        classified = None

        # Check for explicit error markers anywhere in last few
        for p in parsed:
            m = p.get("message", {})
            c = m.get("content")
            txt = json.dumps(c) if c else ""
            if "API error" in txt or "terminated early" in txt or "session limit" in txt or "Overloaded" in txt:
                classified = "abnormal_error"
                break

        if not classified:
            if ltype == "assistant" and isinstance(content, list):
                last_block = content[-1] if content else None
                if isinstance(last_block, dict) and last_block.get("type") == "tool_use":
                    classified = "abnormal_midtool"
                elif last.get("stop_reason") in ("tool_use",):
                    classified = "abnormal_midtool"
                else:
                    classified = "clean"
            elif ltype == "user":
                txt = json.dumps(content) if content else ""
                if "Structured output provided successfully" in txt:
                    classified = "clean_structured_output"
                elif "Request interrupted by user" in txt or "interrupted by user" in txt:
                    classified = "abnormal_user_interrupt"
                else:
                    # last thing is a tool_result / user turn with no assistant follow-up
                    classified = "abnormal_dangling_result"
            elif ltype in ("summary", "result"):
                classified = "clean"
            else:
                classified = "clean"

        results[classified] += 1
        if classified not in ("clean", "clean_structured_output") and len(abnormal_examples) < 25:
            tail_txt = json.dumps(content)[:200] if content else str(last)[:200]
            abnormal_examples.append((fpath, classified, ltype, tail_txt))
    except Exception as e:
        results["empty_or_unparseable"] += 1

print("SAMPLE SIZE:", len(sample))
print(results)
total = sum(results.values())
abnormal = total - results["clean"] - results["clean_structured_output"]
print(f"abnormal ratio: {abnormal}/{total} = {abnormal/total:.2%}")
print()
print("=== ABNORMAL EXAMPLES ===")
for e in abnormal_examples:
    print(e)
