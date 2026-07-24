import json, re, sys, os

files_list = "./scratch/files.txt"

timeout_re = re.compile(r"Command timed out after (\d+m \d+s|\d+h \d+m \d+s|\S+ ?\S*)")

results = []

with open(files_list) as fl:
    files = [l.strip() for l in fl if l.strip()]

for fpath in files:
    try:
        with open(fpath, 'r', errors='replace') as f:
            lines = f.readlines()
    except Exception as e:
        continue

    # build map of tool_use id -> (command, description, timeout_param, timestamp, line_no)
    tool_uses = {}
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        if '"tool_use"' not in line and '"type":"tool_use"' not in line and 'toolu_' not in line:
            # quick filter but not fully reliable; still try parse selectively
            pass
        try:
            obj = json.loads(line)
        except Exception:
            continue
        # navigate structure: message.content is list of blocks
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
                # content can be str or list
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
                        'result_snippet': text[:300],
                    })

with open("./scratch/timeouts.jsonl", "w") as out:
    for r in results:
        out.write(json.dumps(r) + "\n")

print("total timeouts found:", len(results))
