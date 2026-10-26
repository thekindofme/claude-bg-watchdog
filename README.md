# claude-bg-watchdog

Fixpack for a recurring Claude Code pain: **long-running background work
(background shells, subagents, deploys, pollers, Monitor arms) dies, times
out, hangs, or finishes without the orchestrating session ever acting on
it** — and the session stalls until a human notices.

Canonical source; the **live** copies deploy to `~/.claude` via `./install.sh`.
Built 2026-07-24 from a 5-agent audit of 21 days of session transcripts
(~2,200 `.jsonl` files); re-audited 2026-08-12 (see "08-12 re-audit" below).

## Install / uninstall

```sh
./install.sh          # copies all 6 hooks + rules/background-work.md into ~/.claude, prints settings diff hints
```

`install.sh` does not touch `settings.json` — hand-merge it against
`settings-fragment.json`, which records the exact wiring (matcher, event,
async/asyncRewake flags) for every hook. Each hook is independently
removable: delete its entry from `settings.json` and `rm` the matching
`~/.claude/hooks/bg-watchdog-*.sh` (see `install.sh`'s own output for the
file-to-hook map). `rules/background-work.md` can be removed on its own
without touching any hook. Env vars (`BASH_DEFAULT_TIMEOUT_MS`,
`BASH_MAX_TIMEOUT_MS`) revert by deleting the `env` block entries.

## The 6 hooks

| Hook | Event | Status |
|---|---|---|
| `bg-watchdog-postfail.sh` | PostToolUse + PostToolUseFailure[Bash] | active |
| `bg-watchdog-pretool.sh` | PreToolUse[Bash] | active |
| `bg-watchdog-subagent-stop.sh` | SubagentStop | active |
| `bg-watchdog-rewake.sh` | Stop (async, asyncRewake) | active |
| `bg-watchdog-monitor-guard.sh` | PreToolUse[Monitor] | **dormant** by default |
| `bg-watchdog-orphan-sentinel.sh` | Stop (async, asyncRewake) | active |

### postfail — timeout recovery coaching

Fires only on a **structural** timeout signal: `PostToolUseFailure`'s
top-level `.error`, or `PostToolUse` with `tool_response.interrupted == true`
— and only when the "Command timed out after…" banner opens one of the first
3 lines of that text. Injects `additionalContext` telling the model not to
re-run the identical command: background it, re-run once with a sized
timeout, or if it produced zero output, treat it as a hang and kill it.

### pretool — sleep-loop block

Blocks a foreground Bash call structurally, not by regex over the raw string:
the command is tokenised (quote-aware), loop bodies tracked with a frame
stack, and only a `sleep` that actually sits inside a loop body counts.
Blocks when a countable loop's total wait is ≥15s, an infinite loop
(`while true`) sleeps at all, or an uncountable loop (`while <cond>`, `for f
in *`) sleeps ≥1s per pass. One-shot sleeps, sub-threshold loops, and
anything already sent with `run_in_background:true` pass. A raw-string `*sleep*`
check short-circuits the python3 analyser for the common case (no `sleep`
anywhere in the payload); measured budget is <25ms average for that fast
path and <100ms for a full parse (`tests/pretool.test.sh`).

### subagent-stop — death ledger

Reads the subagent's own transcript structurally: a genuine death is the
final substantive record carrying `isApiErrorMessage: true` and/or
`apiErrorStatus`, or a top-level `error` on a record whose `message.model` is
the literal `"<synthetic>"`. Falls back to an anchored text check (message
must *start with* a real harness error string) when the transcript is
missing. Appends to `~/.claude/logs/subagent-deaths.jsonl` with `ts`,
`agent_id`, `agent_type`, `session_id`, `tail`, plus new fields `signal`,
`error_kind`, `api_error_status`, and emits a `systemMessage` so the death is
visible immediately instead of hours later.

### rewake — limit-reset auto-resume

Stop hook, async + asyncRewake. If the turn ended on a death (own message
anchored-matches a harness error string, or a subagent died — corroborated by
a fresh `signal`-bearing ledger entry for this session), sleeps until the
usage-limit likely reset, then exits 2 to wake the session. Parses 12-hour
("resets 5pm"), 24-hour ("resets 17:00"), and relative ("resets in 45
minutes") reset times, with trailing zone suffixes stripped; unparseable
falls back to 1h, every wait capped at 6h, 529/Overloaded uses a flat 180s.
Test seams: `DRY_RUN=1` (print `sleep_secs=<n> signal=<what fired>`, exit 0
instead of sleeping), `BG_WATCHDOG_NOW=<epoch>` (freeze "now").

### monitor-guard — dormant sidechain-arm guard

PreToolUse[Monitor]. Built after transcript mining (169 Monitor arms,
2026-07-24→08-12) suggested subagent-sidechain arms almost never got their
notification delivered (5/137) while top-level arms did (31/32). A live
re-probe on CLI 2.1.228, run from inside a real sidechain, found delivery
**working** on all three paths (match, timeout, persistent) — the mining
number was a measurement artifact: sidechain transcripts never persist the
`queue-operation` record type at all (0/2693 files), so nothing landing there
would ever look like delivery to a transcript miner. Full writeup:
[`notes/monitor-subagent-delivery.md`](notes/monitor-subagent-delivery.md).

Because the underlying tool works, this hook ships **dormant** — it allows
every Monitor call. Set `BG_WATCHDOG_MONITOR_GUARD=1` to deny sidechain arms
if delivery ever genuinely regresses (re-run the probes in the notes file
first — evidence decides, not memory of the bug). `MONITOR_GUARD_OVERRIDE`
anywhere in the tool input bypasses the guard for one call even when enabled.

### orphan-sentinel — un-actioned-failure catcher

Stop hook, async + asyncRewake. Covers the failure mode "alarm delivered,
nobody acted": an async failure notification (failed task, Monitor timeout)
lands and no turn ever acts on it before the session goes idle. Three lanes:
`failed_task` and `monitor_timeout` are instant (60s) pokes for a
notification that's un-actioned at Stop time; `inflight_bg` is a 900s poke
for a background launch with no later status check. Because both real
incidents that motivated this hook had their orphan notification arrive
*after* the session had already stopped — no Stop event existed for the
instant lanes to see — the hook also runs **vigil mode**: when a Stop leaves
recent async footprint behind, it stays alive polling the transcript every
60s for up to `ORPHAN_SENTINEL_VIGIL_MAX` (default 7200s/2h, capped by the
25200s hook timeout) and exits 2 the moment a failure lands un-actioned.
Replaying the two motivating incidents (08-11 agent-stall, 08-03 Monitor
timeout), vigil fires 31 and 12 minutes earlier than the user noticed
manually; a 150-real-Stop sweep produced zero noise pokes and 38 silent
vigils. Anti-loop: every decision is appended to
`~/.claude/logs/orphan-sentinel-state.jsonl`; a given orphan is rewoken at
most once ever, and a session caps at `ORPHAN_SENTINEL_CAP` (default 5)
total rewakes.

## 08-12 re-audit, in brief

The 2026-07-24 hooks used unanchored substring matching in 3 of 4 cases
(postfail, subagent-stop, and part of pretool's loop-keyword regex). Replaying
150 real Stop events and mining the live death ledger found this cost real
precision: **1 genuine death out of 33 ledger entries** — the other 32 were
subagents merely *discussing* rate limits or session limits in their own
prose, not dying. pretool's regex separately had a POSIX bracket-expression
bug (`\s` inside `[...]` is two literal characters under BSD/GNU grep, not
whitespace) that let any multi-statement command with a space before
`while`/`for` evade detection entirely, independent of the sleep-magnitude
threshold. All 4 hooks were rewritten to detect structurally (transcript
fields, tokenised commands) instead of matching substrings; two new hooks
(monitor-guard, orphan-sentinel) were added; the monitor-in-subagents mining
claim was independently re-probed live and refuted (see monitor-guard
section above). Full incident-by-incident detail:
[`notes/monitor-subagent-delivery.md`](notes/monitor-subagent-delivery.md)
and `evals/README.md`'s baseline-failure writeup.

## Testing

```sh
tests/run.sh                 # unit tests, one file per hook, sample stdin payloads
evals/run.sh                 # replay eval: 26 real mined incidents, scored per hook
evals/run.sh baseline-hooks  # same eval against the git-HEAD (pre-rewrite) hooks
```

`tests/` (185/185 passing) is owned by each hook's author and checks
input→output behavior in isolation. `evals/` (26/26 passing live) is a
different question: given a set of hooks, how good is detection quality
across a mix of real, mined incident payloads (21 real, 5 reconstructed —
each case's `provenance` says which)? Run against the git-HEAD snapshot, the
same 26 cases score **12 pass / 7 fail / 7 skip** (5+2 skip because
monitor-guard/orphan-sentinel didn't exist yet) — the old hooks fail exactly
the cases the audit and this suite independently found broken. Full
scoreboard and per-case explanation: `evals/README.md`.

## Env-knob reference

| Var | Hook | Default | Effect |
|---|---|---|---|
| `DRY_RUN` | rewake | unset | Print `sleep_secs=<n> signal=<what fired\|none>` and exit 0 instead of sleeping + exit 2. |
| `BG_WATCHDOG_NOW` | rewake | real `date +%s` | Freeze "now" for deterministic time-math tests. |
| `BG_WATCHDOG_MONITOR_GUARD` | monitor-guard | `0` (dormant) | `1` denies Monitor arms made inside a subagent sidechain. |
| `MONITOR_GUARD_OVERRIDE` | monitor-guard | — | Token anywhere in the Monitor tool input bypasses the guard for one call. |
| `ORPHAN_SENTINEL_DRY_RUN` | orphan-sentinel | `0` | Print the decision as one JSON object, exit 0, never sleep/exit 2. State is still written. |
| `ORPHAN_SENTINEL_STATE` | orphan-sentinel | `~/.claude/logs/orphan-sentinel-state.jsonl` | Anti-loop ledger path. |
| `ORPHAN_SENTINEL_INFLIGHT` | orphan-sentinel | `1` | `0` disables lane 3 (in-flight background launch, no status check). |
| `ORPHAN_SENTINEL_STATUSES` | orphan-sentinel | `failed` | Comma-separated statuses lane 1 treats as failure; add `killed,stopped` to widen (150-Stop replay found those two were teardown artifacts, not real orphans — widen with that in mind). |
| `ORPHAN_SENTINEL_VIGIL` | orphan-sentinel | `1` | `0` reverts lane 3 to a one-shot 900s poke instead of watching. |
| `ORPHAN_SENTINEL_VIGIL_MAX` | orphan-sentinel | `7200` (2h) | How long a vigil may watch. Must stay under the 25200s hook timeout. |
| `ORPHAN_SENTINEL_VIGIL_POLL` | orphan-sentinel | `60` | Seconds between vigil polls. |
| `ORPHAN_SENTINEL_VIGIL_STEP` | orphan-sentinel | unset | Test seam: run `cmd <poll-number>` before each poll (drives transcript growth in tests instead of waiting). |
| `ORPHAN_SENTINEL_CAP` | orphan-sentinel | `5` | Max rewakes per session. |
| `ORPHAN_SENTINEL_MAX_SLEEP` | orphan-sentinel | unclamped | Clamp the instant-lane sleep, for tests. |
| `ORPHAN_SENTINEL_TAIL_LINES` | orphan-sentinel | `300` | Bounded transcript-tail scan size. |
| `ORPHAN_SENTINEL_WINDOW` | orphan-sentinel | `1800` (30m) | Lanes 1–2 freshness window. |
| `ORPHAN_SENTINEL_INFLIGHT_WINDOW` | orphan-sentinel | `14400` (4h) | Lane 3 freshness window. |
| `ORPHAN_SENTINEL_MIN_AGE` | orphan-sentinel | `120` | Lane 3 grace period before an in-flight launch counts as orphaned. |

postfail, pretool, and subagent-stop have no env knobs — detection is fixed
and structural (loop-wait threshold 15s and per-pass 1s are hardcoded policy
constants, not env-tunable).

## Double-rewake interaction (by design)

`rewake` and `orphan-sentinel` are two **independent** Stop array elements,
both async + asyncRewake, and both can fire off the same Stop event. This is
accepted, not a bug: their trigger conditions are disjoint — rewake fires on
a death signal in the *current* turn (the parent's own message, or a fresh
ledger entry), orphan-sentinel fires on *past* async state nobody acted on
(a failed notification, a Monitor timeout, vigil). Both are independently
deduped and capped (rewake naturally can't refire on the same death once the
session has woken and moved on; orphan-sentinel's ledger caps at one rewake
per orphan, 5 per session), so a double-fire means two genuinely different
problems were found, not the same one reported twice.

## Deliberately NOT set (candidate tunables)

- `CLAUDE_AUTO_BACKGROUND_TASKS=1` — auto-backgrounds subagents after ~2min
  (and long MCP calls in non-interactive mode, v2.1.212+). Behavior change;
  enable if foreground Agent blocking becomes a pain.
- `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS` — default 10m stall-abort for background
  subagents (progress-resettable). No audit evidence it was a top killer; raise
  to 30m only if stall-aborts show up in the death ledger.

## Success criteria for next re-audit (~2026-09-02)

1. **Death-ledger precision.** Every new `subagent-deaths.jsonl` entry has a
   `signal` field, and a spot-check sample confirms they're genuine deaths
   (the 08-12 baseline was 1 genuine / 33 total).
2. **Zero substring false positives from postfail** — no firing traced to a
   command whose *output* merely contained the timeout banner text.
3. **orphan-sentinel state file** shows rewakes correlating with real
   un-actioned failures: no `orphan_key` with more than one rewake, and
   vigil noise stays ~0 on quiet stops (08-12 baseline: 38 silent vigils, 0
   pokes across 150 real Stops).
4. **Bare "status" pings during active watches drop** versus the 08-12
   baseline of 4 in one session.
5. **First vigil observed surviving >3600s** — or, failing that, note that
   the 1-hour ceiling (the longest asyncRewake sleep empirically confirmed
   so far, out of a 2h `VIGIL_MAX`) still stands.

Extraction scripts: `analysis/scripts/`. The raw audit outputs they produced
came from private session transcripts and are not published.
