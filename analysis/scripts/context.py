import json, sys

def show(path, lineno, after=40):
    lineno = int(lineno)
    with open(path) as f:
        lines = f.readlines()
    start = lineno - 1
    end = min(len(lines), start + after)
    for i in range(start, end):
        try:
            o = json.loads(lines[i])
        except Exception:
            continue
        t = o.get("type")
        ts = o.get("timestamp", "")
        if t == "assistant":
            for c in o.get("message", {}).get("content", []):
                if c.get("type") == "text":
                    print(ts, "ASSISTANT:", c["text"][:180].replace("\n"," "))
                elif c.get("type") == "tool_use":
                    print(ts, "TOOL_USE:", c.get("name"), str(c.get("input"))[:160].replace("\n"," "))
        elif t == "user":
            msg = o.get("message", {})
            content = msg.get("content", "")
            if isinstance(content, str):
                if content:
                    print(ts, "USER:", content[:160].replace("\n"," "))
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        cc = c.get("content","")
                        print(ts, "TOOL_RESULT:", str(cc)[:160].replace("\n"," "))
        elif t in ("queue-operation",):
            print(ts, t, o.get("operation"))
        elif t == "system":
            print(ts, "SYSTEM:", o.get("subtype"), str(o.get("content",""))[:120].replace("\n"," "))

if __name__ == "__main__":
    path, lineno = sys.argv[1], sys.argv[2]
    after = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    show(path, lineno, after)
