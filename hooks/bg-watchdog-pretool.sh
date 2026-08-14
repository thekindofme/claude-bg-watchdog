#!/usr/bin/env bash
# PreToolUse[Bash] — block flagrant foreground sleep-loop waits on async work.
# Audit 2026-07-24: 48% of all foreground Bash timeouts were hand-rolled
# while/until/for + sleep polls on builds/SFN/subagent-output. Those belong in
# run_in_background or the Monitor tool.
#
# Detection is structural, not textual: the command is tokenised (quote-aware),
# loop bodies are tracked with a frame stack, and only a `sleep` that actually
# sits INSIDE a loop body counts. Estimated total wait = iterations x per-pass
# sleep, nested loops multiplying outward. Block when:
#   * a countable loop waits >= 15s in total          (12 x sleep 10 = 120s)
#   * an infinite loop (while true / until false) sleeps at all
#   * an uncountable loop (while <cond>, for f in *) sleeps >= 1s per pass
# `sleep $VAR` inside a loop counts as unbounded — unknown is suspicious.
# Left alone: one-shot sleeps (including a long trailing one), loops under the
# threshold, sub-second throttles in uncountable loops, loops detached with `&`,
# and anything the model already sent with run_in_background:true.
# Fails open: any parse problem exits 0 rather than blocking a session.
set -u

BGWD_INPUT=$(cat)
export BGWD_INPUT

# Fast path: this hook sits in front of every Bash call, so the overwhelmingly
# common case (no `sleep` anywhere in the payload) must not pay for a python
# start-up. Over-approximate on the raw input — a false hit just falls through
# to the real analyser below.
case "$BGWD_INPUT" in
  *sleep*) ;;
  *) exit 0 ;;
esac

# The analyser is read into a variable rather than heredoc'd straight into a
# command substitution: bash 3.2 (the macOS system bash) paren-counts the body
# of $( ... ) even across a quoted heredoc, and the regexes below contain
# unbalanced parens inside string literals.
read -r -d '' BGWD_PY <<'PYEOF' || true
import json, os, re, sys

INF = float("inf")
THRESHOLD = 15.0          # policy: total in-loop wait, seconds
UNCOUNTABLE_MIN = 1.0     # per-pass sleep that makes an uncountable loop suspicious
UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}

try:
    data = json.loads(os.environ.get("BGWD_INPUT", ""))
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)

ti = data.get("tool_input") or {}
cmd = ti.get("command") or ""
bg = ti.get("run_in_background")
if not cmd or bg is True or str(bg).lower() == "true":
    sys.exit(0)

SQ = "'"
DQ = '"'
OPS = [";;", "&&", "||", ";", "&", "|", "(", ")", "\n"]


def tokenize(s):
    """Yield (text, is_op, was_quoted). Quoted text can never be a command name."""
    out, i, n = [], 0, len(s)
    buf, quoted = "", False

    def flush():
        nonlocal buf, quoted
        if buf:
            out.append((buf, False, quoted))
        buf, quoted = "", False

    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            buf += s[i + 1]
            i += 2
            continue
        if c == SQ:
            j = s.find(SQ, i + 1)
            if j < 0:
                j = n
            buf += s[i + 1:j]
            quoted = True
            i = j + 1
            continue
        if c == DQ:
            j, seg = i + 1, ""
            while j < n:
                if s[j] == "\\" and j + 1 < n:
                    seg += s[j + 1]
                    j += 2
                    continue
                if s[j] == DQ:
                    break
                seg += s[j]
                j += 1
            buf += seg
            quoted = True
            i = j + 1
            continue
        if c == "$" and i + 1 < n and s[i + 1] == "(":      # $( ... ) kept whole
            depth, j = 1, i + 2
            while j < n and depth:
                if s[j] == "(":
                    depth += 1
                elif s[j] == ")":
                    depth -= 1
                j += 1
            buf += s[i:j]
            i = j
            continue
        if c == "`":
            j = s.find("`", i + 1)
            if j < 0:
                j = n
            buf += s[i:j + 1]
            i = j + 1
            continue
        if c.isspace() and c != "\n":
            flush()
            i += 1
            continue
        matched = None
        for op in OPS:
            if s.startswith(op, i):
                matched = op
                break
        if matched:
            # (( ... )) arithmetic (C-style for header) is kept as one word.
            if matched == "(" and s.startswith("((", i):
                depth, j = 0, i
                while j < n:
                    if s[j] == "(":
                        depth += 1
                    elif s[j] == ")":
                        depth -= 1
                        if depth == 0:
                            j += 1
                            break
                    j += 1
                buf += s[i:j]
                i = j
                continue
            flush()
            out.append((matched, True, False))
            i += len(matched)
            continue
        buf += c
        i += 1
    flush()
    return out


def num(tok):
    """sleep argument -> seconds, or INF when it cannot be known."""
    t = tok.strip()
    if not t or "$" in t or "`" in t:
        return INF
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([smhd]?)", t)
    if not m:
        return INF
    return float(m.group(1)) * UNITS[m.group(2)]


def iters(header):
    """Iteration count of a loop: int, None (uncountable) or INF (infinite)."""
    words = [w for w, is_op, _ in header if not is_op]
    if not words:
        return None
    kw = words[0]
    if kw in ("while", "until"):
        rest = words[1:]
        if rest and rest[0] in ("true", ":", "false"):
            return INF
        return None
    if len(words) > 1 and words[1].startswith("(("):
        body = words[1].strip("()")
        parts = [p.strip() for p in body.split(";")]
        if len(parts) == 3:
            a = re.search(r"=\s*(-?\d+)", parts[0])
            b = re.search(r"[<>]=?\s*(-?\d+)", parts[1])
            st = re.search(r"\+=\s*(\d+)", parts[2])
            step = int(st.group(1)) if st else 1
            if a and b and step > 0:
                lo, hi = int(a.group(1)), int(b.group(1))
                span = hi - lo
                if "<=" in parts[1] or ">=" in parts[1]:
                    span += 1
                return max(0, -(-span // step))
        return None
    if "in" not in words:
        return None
    lst = words[words.index("in") + 1:]
    if not lst:
        return None
    total = 0
    for item in lst:
        m = (re.fullmatch(r"\$\(\s*seq\s+([^)]*)\)", item)
             or re.fullmatch(r"`\s*seq\s+([^`]*)`", item))
        if m:
            try:
                nums = [float(a) for a in m.group(1).split()]
            except ValueError:
                return None
            if len(nums) == 1:
                a, step, b = 1.0, 1.0, nums[0]
            elif len(nums) == 2:
                a, step, b = nums[0], 1.0, nums[1]
            elif len(nums) == 3:
                a, step, b = nums
            else:
                return None
            if step == 0:
                return None
            total += max(0, int((b - a) / step) + 1)
            continue
        m = re.fullmatch(r"\{(-?\d+)\.\.(-?\d+)(?:\.\.(\d+))?\}", item)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            step = int(m.group(3)) if m.group(3) else 1
            if step == 0:
                return None
            total += abs(b - a) // step + 1
            continue
        if "$" in item or "`" in item or any(ch in item for ch in "*?["):
            return None
        total += 1
    return total


def contribution(frame):
    """Seconds a finished loop frame contributes to its parent."""
    if frame["sleep"] <= 0:
        return 0.0
    it = frame["iters"]
    if it is INF:
        return INF
    if it is None:
        return INF if frame["sleep"] >= UNCOUNTABLE_MIN else 0.0
    return it * frame["sleep"]


toks = tokenize(cmd)
KW_OPENS = {"do", "then", "else", "elif", "in"}

frames = []
global_worst = 0.0
pending = None
at_cmd_pos = True
i = 0
while i < len(toks):
    text, is_op, was_quoted = toks[i]

    if is_op:
        at_cmd_pos = True
        i += 1
        continue
    if was_quoted:
        at_cmd_pos = False
        i += 1
        continue

    if pending is not None:
        if text == "do":
            frames.append({"iters": iters(pending), "sleep": 0.0})
            pending = None
            at_cmd_pos = True
        else:
            pending.append((text, False, False))
        i += 1
        continue

    if at_cmd_pos and text in ("while", "until", "for"):
        pending = [(text, False, False)]
        i += 1
        continue

    if text == "done":
        if frames:
            f = frames.pop()
            j = i + 1
            while j < len(toks) and toks[j][0] in (")", "}"):
                j += 1
            detached = j < len(toks) and toks[j][0] == "&"
            if not detached:
                got = contribution(f)
                if frames:
                    frames[-1]["sleep"] += got
                else:
                    global_worst = max(global_worst, got)
        at_cmd_pos = False
        i += 1
        continue

    if at_cmd_pos and (text == "sleep" or text.endswith("/sleep")):
        secs, j = 0.0, i + 1
        while j < len(toks) and not toks[j][1]:
            secs += num(toks[j][0])
            j += 1
        if frames:
            frames[-1]["sleep"] += secs
        i = j
        at_cmd_pos = False
        continue

    at_cmd_pos = text in KW_OPENS
    i += 1

# Unterminated loops (truncated command) still count what they accumulated.
for f in frames:
    global_worst = max(global_worst, contribution(f))

if global_worst >= THRESHOLD:
    print("unbounded" if global_worst == INF else str(int(global_worst)))
PYEOF

verdict=$(printf '%s\n' "$BGWD_PY" | python3 - 2>/dev/null)

[ -z "$verdict" ] && exit 0

if [ "$verdict" = "unbounded" ]; then
  est="an unbounded in-loop wait"
else
  est="~${verdict}s of in-loop sleeping"
fi

echo "Blocked: foreground poll loop ($est) waiting on something async. Re-issue with run_in_background:true (single completion notification), or use the Monitor tool (streaming events; persistent:true for session-length watches; filter must match FAILURE states too, not just success). If this truly must run foreground, remove the loop and wait on the condition once with an explicit sized timeout." >&2
exit 2
