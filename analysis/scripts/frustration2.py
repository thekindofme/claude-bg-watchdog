import json, re

SCRATCH = "./scratch"
with open(f"{SCRATCH}/all_files.txt") as fh:
    all_files = [l.strip() for l in fh if l.strip()]

SYSTEM_PREFIXES = (
    "<task-notification", "Another Claude session sent a message",
    "This session is being continued", "<system-reminder", "Caveat:",
    "<teammate-message", "<agent-message", "<local-command",
    "You're being invoked on a timer",
)

PAT = re.compile(
    r"still running|\bstuck\b|\bhung\b|\bdied\b|taking forever|what happened to|"
    r"never came back|gave up|try again|come on\b|wtf|why (is|did|does|hasn.t|isn.t) "
    r"|timed out|timing out|is this (stuck|broken|hung)|hello\?|still (there|going|waiting)|"
    r"any (update|progress)|how long|not (working|responding)|frozen|freeze|"
    r"kill (it|this)|cancel (it|this)|restart it|forget it|nvm|never ?mind",
    re.I
)

hits = []
for fpath in all_files:
    try:
        with open(fpath, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "user":
                    continue
                msg = d.get("message", {})
                content = msg.get("content")
                if not isinstance(content, str):
                    continue
                stripped = content.lstrip()
                if any(stripped.startswith(p) for p in SYSTEM_PREFIXES):
                    continue
                if len(content) > 2000:
                    continue
                if PAT.search(content):
                    hits.append((fpath, d.get("timestamp"), content.strip()[:400]))
    except Exception:
        continue

print(f"TOTAL genuine human hits: {len(hits)}")
for h in hits:
    print(h)
    print("---")
