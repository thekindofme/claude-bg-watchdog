# claude-bg-watchdog eval suite

A replay eval for the watchdog hooks in `../hooks/`. Different from `../tests/`
(unit tests, owned by the hook authors, one file per hook): this suite replays
**real, mined incident payloads** — actual hook-input JSON reconstructed from
Yasith's own session transcripts — and scores **aggregate precision/recall per
hook family and per failure category**. It answers "given a set of hooks (old
or new), how good is detection quality across the real incident mix?", not
"does this one function behave as specified?".

## Running it

```sh
./run.sh                 # score the live ../hooks (whatever's on disk right now)
./run.sh baseline-hooks   # score the git-HEAD (pre-rewrite) snapshot
./baseline.sh             # refresh baseline-hooks/ from git HEAD
```

`run.sh <dir>` is a one-line wrapper around `python3 runner.py <dir>`; pass any
hooks directory. Exit code is non-zero iff any case **FAIL**s (SKIPs don't
affect it — a SKIP means "hook not present" or "unsafe to execute for real",
not a defect). Add `--json-out results.json` for machine-readable output.

Dependencies: bash + python3 stdlib only. No pip installs, no network.

## Case inventory

26 cases in `cases/*.json`, 21 `"schema":"real"` (verbatim or near-verbatim
payloads recovered from actual transcripts) and 5 `"schema":"reconstructed"`
(plausible variants built from a real fragment when the exact original
couldn't be recovered — each says so in its own `provenance`).

| hook | cases | categories (fires:true / fires:false) |
|---|---|---|
| postfail | 4 | false-positive-substring (0/2), genuine-timeout (2/0) |
| pretool | 4 | loop-evasion (2/0), legit-background-wait (0/2) |
| subagent-stop | 5 | genuine-death (2/0), quoted-error-text (0/3) |
| rewake | 6 | genuine-timeout (5/0), clean-completion (0/1) |
| monitor-guard | 5 | sidechain-arm (1/0), toplevel-or-dormant-arm (0/4) |
| orphan-sentinel | 2 | unhandled-notification (1/1) |

Every hook has at least one must-fire and one must-not-fire case, so precision
and recall are both measured, not just one.

## How "fires" is decided, per hook family

Hook input/output contracts differ, so a single "exit code 2" rule doesn't
cover them all:

- **pretool, monitor-guard**: `fires = (exit code == 2)`. Both are
  `PreToolUse` deny hooks; stdin is the tool-call envelope, stderr carries the
  deny message.
- **postfail**: `fires = stdout is non-empty` (a firing hook emits one JSON
  line with `hookSpecificOutput.additionalContext`; a pass-through emits
  nothing and exits 0).
- **subagent-stop**: `fires = stdout is non-empty` (a `{"systemMessage": …}`
  blob). The hook also appends a line to
  `~/.claude/logs/subagent-deaths.jsonl` — runner.py sets `HOME` to an
  isolated temp dir for every subagent-stop invocation so the eval **never
  touches the real ledger**.
- **rewake**: two execution modes, auto-detected from the hook source:
  - *native DRY_RUN* (current hook): set `DRY_RUN=1`, hook prints
    `sleep_secs=<n> signal=<what fired|none>` and exits 0 always.
    `fires = (signal not in {none, ""})`.
  - *sed-stubbed* (pre-rewrite baseline, no DRY_RUN): the literal
    `sleep "$sleep_secs"` line is rewritten to
    `echo "WOULD_SLEEP=$sleep_secs"; #` in a throwaway copy (the exact
    technique the hook's own author used by hand during development — see
    provenance on `rewake-resets-5pm-12hr`). `fires = (exit code == 2)`.
  - Either way, runner.py additionally verifies the **reported sleep_secs**
    against a Python re-implementation of the hook's own
    `classify()`/`reset_secs()` logic (`reference_sleep_secs()` in
    `runner.py`), pinned to the same wall-clock instant via
    `BG_WATCHDOG_NOW` (a real test seam the current hook documents; ignored
    harmlessly by hooks that predate it, since runner.py sets it to
    essentially real "now" either way). Tolerance ±15s. If the hook fires but
    reports a materially different number, that's a **FAIL**, not a pass —
    this is what catches the 24-hour/relative-time parsing gap below.
  - A hook script found with neither DRY_RUN nor the known sleep-stub pattern
    is marked **SKIP** rather than executed — a real sleep of up to 6h is not
    something an eval run should risk.
- **orphan-sentinel**: set `ORPHAN_SENTINEL_DRY_RUN=1`; the hook prints one
  JSON decision object and exits 0. `fires = (decision == "rewake")`, with an
  exit-code-2 fallback for a hypothetical hook built without DRY_RUN support.
  runner.py also sets an isolated `ORPHAN_SENTINEL_STATE` ledger path per case
  (never the real one) and widens `ORPHAN_SENTINEL_WINDOW` /
  `_INFLIGHT_WINDOW` (the hook compares embedded transcript timestamps against
  real `date +%s`, so a >1-day-old real-incident replay needs the freshness
  gate opened up or it silently ages out) and clamps `ORPHAN_SENTINEL_VIGIL_MAX`
  (the hook's lane-3 "watch and wait" mode would otherwise burn up to
  7200/`VIGIL_POLL` real jq passes checking a snapshot that, being static,
  never changes).

`expect.output_contains` (when present) is checked against `stdout + stderr`
combined, only on cases that fired as expected — it's for the coaching-text
identity checks (postfail/subagent-stop/pretool), not used for rewake (whose
exact wording differs between the sed-stub and native-DRY_RUN paths; the
numeric sanity check above covers rewake instead).

## Baseline scoreboard — git-HEAD hooks (`./run.sh baseline-hooks`)

`baseline.sh` extracts `git show HEAD:hooks/<name>.sh` into `baseline-hooks/`
— the four hooks as originally shipped 2026-07-24, before the current
in-flight rewrite. `monitor-guard` and `orphan-sentinel` don't exist at HEAD,
so their cases **SKIP** (5 + 2 = 7 of 26).

```
== monitor-guard ==      0 pass / 0 fail / 5 skip   (hook absent at HEAD)
== orphan-sentinel ==    0 pass / 0 fail / 2 skip   (hook absent at HEAD)
== postfail ==           2 pass / 2 fail / 0 skip   precision=0.50 recall=1.00
== pretool ==            2 pass / 2 fail / 0 skip   precision=nan  recall=0.00
== rewake ==             4 pass / 2 fail / 0 skip   precision=1.00 recall=1.00
== subagent-stop ==      4 pass / 1 fail / 0 skip   precision=0.67 recall=1.00
== TOTAL ==              12 pass / 7 fail / 7 skip  (of 26 cases)
```

This is the point of the suite: the old hooks fail exactly the cases their own
2026-08-12 audit and this eval's construction independently found broken.

**The 7 baseline failures, explained:**

1. **`postfail-fp-freq-scan-grep`** and **`postfail-fp-readme-doc-text`** —
   both false positives. The old hook's `case "$out" in *"Command timed out
   after"*)` is an unanchored substring test over `tool_output`/`tool_response`/
   `.error` joined together, so a `grep -l` frequency count whose stdout
   literally contains the string `"Command timed out after:"` as a match-count
   label (real, `a8129147` session — the SAME session's own teammate-message
   independently flags this exact pollution class), or a `cat`/`tail` of this
   repo's own README quoting the phrase in its Success Criteria section, both
   trip it. The current `bg-watchdog-postfail.sh` fixes this by gating on
   `PostToolUseFailure`'s top-level `.error` field or `tool_response.interrupted
   == true`, and anchoring the banner to the start of a line within the first
   3 lines of the actual failure text.

2. **`pretool-loop-sleep10-gap`** — false negative. The 12×`sleep 10`
   foreground poll from session `d889bfca` (2026-07-30) is a real ~2-minute
   blocking loop, but the old hook's sleep-magnitude regex only blocks
   `sleep >= 15`s per iteration, so `sleep 10` slips through.

3. **`pretool-loop-sleep30-foreground`** — false negative, and a **second,
   more important bug found while building this eval**, independent of sleep
   magnitude: the loop-keyword bracket class `[;&|(\s]` does not mean
   "preceded by whitespace" under real POSIX grep (`\s` is a PCRE-only
   shorthand; inside a bracket expression under BSD grep 2.6.0-FreeBSD or GNU
   grep `-E`, it's just the two literal characters `\` and `s`). It only
   matches if `while`/`until`/`for` sits at the very start of the command
   string, or is directly adjacent (no space) to `;`, `&`, `|`, or `(`. Any
   realistic multi-statement script — `cmd; for i in …` (space after the
   semicolon), or a `for` on its own indented line — evades detection
   entirely, for a reason that has nothing to do with the sleep threshold.
   Minimal repro: `printf '; for x in 1; do :; done' | grep -qE
   '(^|[;&|(\s])(while|until|for)[[:space:]]'` → no match. Flagged directly to
   `wp1-hooks-v2`; the current `bg-watchdog-pretool.sh` fixes it (this case is
   TP against live `../hooks`).

4. **`subagent-stop-fp-adjacent-subject`** — false positive. A subagent's
   *own* completion report ("judges hit session limit at 98/112 pairs")
   describes a **different process** hitting a limit, not the reporting agent
   dying; the literal space-separated substring `session limit` still trips
   the unanchored regex. The current hook's replacement anchors detection to
   the message actually *starting* with a canonical harness string
   (`"You've hit your session limit"`, `"API Error"`, etc., optionally behind
   a plain `Agent failed: ` wrapper) instead of matching anywhere in the text.

5. **`rewake-resets-1700-24hr-gap`** and **`rewake-resets-in-45-minutes-gap`**
   — both "fire correctly, compute the wrong wait." The old hook's time regex
   requires an am/pm suffix, so `"resets 17:00"` (24-hour) and `"resets in 45
   minutes"` (relative) never match `reset`, and it silently falls back to a
   flat 3600s — independently confirmed by the infra-audit teammate's own
   live finding ("rewake's time-parser is narrower than its README claim but
   fails safe"). The current hook added explicit 24-hour and relative-time
   parsing (see its own header comment), so these are TP-with-correct-number
   against live `../hooks`.

**What's already fixed** (all 26 pass against the live `../hooks` as of this
write-up): monitor-guard and orphan-sentinel now exist and score cleanly
(5/5, 2/2) — monitor-guard's expectations were confirmed by the team lead
mid-build: WP2's live probe on CLI 2.1.228 refuted the original "Monitor never
delivers in subagents" mining finding (a measurement artifact — sidechain
transcripts never persist `queue-operation` records at all, so the miner
undercounted; live probes delivered 4/4), so the hook ships **dormant by
default**. The four monitor-guard cases already encoded this correctly (built
straight from the real hook source, not the original mining claim): subagent
arm with no env → allow, subagent arm + `BG_WATCHDOG_MONITOR_GUARD=1` → deny,
top-level arm + env set → allow, override token + env set → allow. A 5th case
(`monitor-guard-malformed-stdin`) was added to replay the hook's own
"malformed stdin fails open" unit test (`tests/monitor-guard.test.sh`, 9/9
green) as a case in this suite too. postfail, pretool, and subagent-stop all
score 4/4 or better; the "gap" rewake cases now compute the
numerically-correct wait. This is a point-in-time snapshot — `hooks/*.sh` are
mid-rewrite by sibling agents, so re-run `./run.sh` (no argument) for the
current state.

## Cases that couldn't be grounded in real data

- **`rewake-resets-1700-24hr-gap`**, **`rewake-resets-in-45-minutes-gap`**,
  **`rewake-session-limit-no-time`**: the canonical
  `"You've hit your session limit · resets …"` prefix is real and verified
  (grep-confirmed across 4 sessions); the 24-hour, relative-time, and
  no-time-clause suffixes are reconstructed — the mining window only turned
  up 12-hour am/pm reset times in that exact sentence (a bare `resets 21:50`
  24-hour fragment exists elsewhere, but not confirmed inside the canonical
  sentence).
- **`monitor-guard-override-enabled`**: the `MONITOR_GUARD_OVERRIDE` escape
  hatch has never been exercised live (nobody has hit the guard yet — it
  ships dormant), so no real transcript instance of the token exists. Built
  from the exact escape-hatch wording in the hook's own deny message.
- **`monitor-guard-malformed-stdin`**: no real malformed-stdin incident exists
  (nothing has ever sent the hook broken JSON); built from the hook's own
  documented robustness contract instead, using a `raw_input` literal-bytes
  field (see runner.py) since the whole point is that stdin isn't valid JSON.
- **`orphan-sentinel-unhandled-stall`** / **`-handled-notification`**: the
  hook-input *envelope* (which fields Claude Code sends) had to be
  reconstructed before the hook landed on disk, then corrected against the
  real hook's own `jq` once it did. The *event structure* is real: both
  cases replay the last 300 records of the actual incident transcript (one of
  the two incidents the hook's header comment cites as its motivating case),
  cut at the line the simulated Stop event represents. For privacy the
  published fixtures (`fixtures/synthetic-*.jsonl`) are rebuilt by
  `tools/synth_transcript.py`: it keeps record types, timestamps, queue
  operations, notification tags and tool_use names/ids, swaps every id for a
  stable fake, and replaces all text with filler. The hook reaches the same
  decision on the synthetic files as on the originals.

Every other case (21 of 26) is a verbatim or near-verbatim real payload with a
transcript path + line number in its `provenance` field.
