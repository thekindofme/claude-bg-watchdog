import json, re, sys, os

SCRATCH = "./scratch"

def process(infile, outfile):
    out = []
    with open(infile) as f:
        for line in f:
            line = line.rstrip("\n")
            try:
                path, lineno, rest = line.split(":", 2)
            except ValueError:
                continue
            try:
                obj = json.loads(rest)
            except Exception:
                continue
            content = obj.get("content", "")
            if not content:
                msg = obj.get("message", {})
                if isinstance(msg, dict):
                    content = msg.get("content", "")
            if not content:
                att = obj.get("attachment", {})
                if isinstance(att, dict):
                    content = att.get("prompt", "")
            if isinstance(content, list):
                parts = []
                for c in content:
                    if isinstance(c, dict):
                        v = c.get("text") or c.get("content") or ""
                        parts.append(v if isinstance(v, str) else str(v))
                    else:
                        parts.append(str(c))
                content = " ".join(parts)
            if not isinstance(content, str):
                content = str(content)
            # exclude non task-notification style entries (e.g. raw mcp_task tool_results)
            if "<task-notification>" not in content:
                continue
            # exclude this analysis session's own transcript (meta noise from our own greps)
            if "a8129147-a2a2-4a12-926d-acd615c4731e" in path:
                continue
            ts = obj.get("timestamp","")
            sid = obj.get("sessionId","")
            m = re.search(r"<summary>(.*?)</summary>", content, re.DOTALL)
            summary = m.group(1) if m else ""
            summary = summary.replace("\t", " ").replace("\n", " ⏎ ")
            tid_m = re.search(r"<task-id>(.*?)</task-id>", content)
            tid = tid_m.group(1) if tid_m else ""
            out.append((path, lineno, ts, sid, tid, summary))
    with open(outfile, "w") as f:
        for path, lineno, ts, sid, tid, summary in out:
            f.write(f"{path}\t{lineno}\t{ts}\t{sid}\t{tid}\t{summary}\n")
    return len(out)

n1 = process(os.path.join(SCRATCH, "failed_lines.txt"), os.path.join(SCRATCH, "failed_parsed.tsv"))
n2 = process(os.path.join(SCRATCH, "killed_lines.txt"), os.path.join(SCRATCH, "killed_parsed.tsv"))
print(n1, n2)
