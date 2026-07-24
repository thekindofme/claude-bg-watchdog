import os

SCRATCH = "./scratch"

def dedupe(infile, outfile):
    seen = {}
    order = []
    with open(os.path.join(SCRATCH, infile)) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t", 5)
            if len(parts) < 6:
                continue
            path, lineno, ts, sid, tid, summary = parts
            # dedupe key: same session + same task-id + same summary text collapses the
            # enqueue-event/delivered-event double-write artifact, while still keeping
            # genuinely distinct re-failures of a resumed task-id (different summary/time)
            key = (sid, tid, summary) if tid else (path, summary)
            if key not in seen:
                seen[key] = (path, lineno, ts, sid, tid, summary)
                order.append(key)
    with open(os.path.join(SCRATCH, outfile), "w") as f:
        for key in order:
            path, lineno, ts, sid, tid, summary = seen[key]
            f.write(f"{path}\t{lineno}\t{ts}\t{sid}\t{tid}\t{summary}\n")
    return len(order)

print("failed dedup:", dedupe("failed_parsed.tsv", "failed_dedup.tsv"))
print("killed dedup:", dedupe("killed_parsed.tsv", "killed_dedup.tsv"))
