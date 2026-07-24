import re, os
from collections import Counter, defaultdict

SCRATCH = "./scratch"

def load(fn):
    rows = []
    with open(os.path.join(SCRATCH, fn)) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t", 5)
            if len(parts) < 6:
                continue
            path, lineno, ts, sid, tid, summary = parts
            rows.append((path, lineno, ts, sid, summary))
    return rows

def categorize(summary):
    s = summary.lower()
    is_agent = s.startswith('agent "') or s.startswith("agent '")
    if is_agent and ("session limit" in s or "api error" in s):
        return "agent-session-limit/API-error"
    if is_agent:
        return "agent-other-failure"
    if s.startswith("mcp task") or "chrome-devtools/" in s:
        return "browser-automation/screenshot"
    if re.search(r"screenshot|headless chrome|render page|render ad library|dark main view|ambiguous state", s):
        return "browser-automation/screenshot"
    if re.search(r"sls offline|dev gateway|start.*gateway|vite|caddy|reverse proxy|frontend.*dev server|\bdev server\b|launch dev|relaunch dev|restart dev|launch the app|relaunch app|restart app", s):
        return "dev-server-startup/app-relaunch"
    if re.search(r"\bdeploy\b|buildkite|\bbuild \d|wait for.*build|pr \d+.*check|pipelines quiet|sso login", s):
        return "deploy/CI-build-wait"
    if re.search(r"\bpoll\b|\bpolling\b|wait for|wait until|block until|monitor|watch prod|watch g |gap watcher", s):
        return "poll/wait-loop"
    if re.search(r"e2e|end-to-end|test suite|run tests|\btest\b|lint|auth suite", s):
        return "test/e2e/lint"
    if re.search(r"assemble the video|generate frames|render.*video|full run.*480p|frame library", s):
        return "video/frame-render"
    if re.search(r"find /|diff |verify fence|compare files", s):
        return "filesystem-scan/diff-verify"
    if re.search(r"\.mjs|\.py\b|node |script|spike", s):
        return "adhoc-script"
    return "other"

def exit_code(summary):
    m = re.search(r"exit code (\-?\d+)", summary)
    if m:
        return m.group(1)
    m = re.search(r"\(exit (\-?\d+)\)", summary)
    if m:
        return m.group(1)
    return None

for label, fn in [("FAILED", "failed_dedup.tsv"), ("KILLED", "killed_dedup.tsv")]:
    rows = load(fn)
    cat_counter = Counter()
    exit_counter = Counter()
    cat_exit = defaultdict(Counter)
    for path, lineno, ts, sid, summary in rows:
        cat = categorize(summary)
        cat_counter[cat] += 1
        ec = exit_code(summary)
        if ec:
            exit_counter[ec] += 1
            cat_exit[cat][ec] += 1
    print(f"=== {label} (n={len(rows)}) ===")
    for cat, cnt in cat_counter.most_common():
        top_exits = cat_exit[cat].most_common(5)
        print(f"  {cat}: {cnt}  exit_codes={dict(top_exits)}")
    print(f"  overall exit codes: {dict(exit_counter.most_common(10))}")
    print()
