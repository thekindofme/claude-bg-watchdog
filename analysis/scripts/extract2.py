import json, re

files_list = "files_clean.txt"
timeout_re = re.compile(r"Command timed out after (\d+m \d+s|\d+h \d+m \d+s)")

results = []

with open(files_list) as fl:
    files = [l.strip() for l in fl if l.strip()]

for fpath in files:
    try:
        fh = open(fpath, errors='replace')
    except Exception:
        continue
    with fh:
        lines = fh.readlines()

    tool_uses = {}
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        msg = obj.get('message')
        if not isinstance(msg, dict):
            continue
        content = msg.get('content')
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get('type')
            if btype == 'tool_use' and block.get('name') == 'Bash':
                tid = block.get('id')
                inp = block.get('input', {}) or {}
                tool_uses[tid] = {
                    'command': inp.get('command'),
                    'description': inp.get('description'),
                    'timeout': inp.get('timeout'),
                    'run_in_background': inp.get('run_in_background'),
                    'line_no': i,
                    'timestamp': obj.get('timestamp'),
                }
            elif btype == 'tool_result':
                tuid = block.get('tool_use_id')
                c = block.get('content')
                text = ''
                if isinstance(c, str):
                    text = c
                elif isinstance(c, list):
                    for cb in c:
                        if isinstance(cb, dict) and cb.get('type') == 'text':
                            text += cb.get('text','')
                m = timeout_re.search(text)
                if m:
                    results.append({
                        'file': fpath,
                        'line_no': i,
                        'timestamp': obj.get('timestamp'),
                        'tool_use_id': tuid,
                        'timeout_str': m.group(1),
                        'tool_use': tool_uses.get(tuid),
                        'result_snippet': text[:400],
                    })

with open("timeouts2.jsonl", "w") as out:
    for r in results:
        out.write(json.dumps(r) + "\n")

print("total timeouts found:", len(results))
