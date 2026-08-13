# Does Monitor deliver notifications inside subagent sidechains?

**Verdict: yes, it does — on CLI 2.1.228, all three delivery paths worked, 4/4 events received.
And the mining statistic that said otherwise is a measurement artifact, not a bug.**

Sidechain transcripts never persist notification records at all, so "did this subagent get
notified?" is not a question transcript mining can answer. No upstream bug report is warranted
on this evidence.

- **CLI version:** 2.1.228 (Claude Code)
- **Date of test:** 2026-08-12
- **Test context:** run from inside a real subagent sidechain — agent
  `awp2-monitor-guard-cab29fd69853eb6a`, spawned by session
  `d387054e-5f4a-4162-a360-7012427e42a6`. `isSidechain: true` on every entry of its transcript.

## What prompted the test

Transcript mining over 2026-07-24 → 2026-08-12 (169 Monitor arms) reported:

| where armed | arms | "notification observed" |
|---|---|---|
| top level | 32 | 31 |
| subagent sidechain | 137 | 5 (all clustered 07-28/29) |

Since ~81% of arms happen inside subagents, a silent watcher there would be the dominant
watcher failure mode. That premise is what this note tests.

## Part A — live probes

All three probes were armed from inside the sidechain. Times are UTC.

| probe | armed | condition | satisfied | notification received? |
|---|---|---|---|---|
| A — match | 09:25:40 (task `bzk4pdjf0`, 120s) | file gains `PROBE_A_HIT` | 09:26:10 | **yes** — `MATCH_A at 09:26:10Z`, delivered in-band, observed before 09:26:39 |
| B — timeout | 09:25:40 (task `be5tbo2wj`, 60s) | never satisfiable | n/a | **yes** — `[Monitor timed out — re-arm if needed.]`, observed before 09:27:07 |
| C — persistent | 09:27:05 (task `bf1jm4fef`, `persistent: true`) | emits 2 events, then idles | 09:27:10, 09:27:15 | **yes, both** — `PERSISTENT_C_EVENT1`, `PERSISTENT_C_EVENT2`; `TaskStop` then cleanly ended it |

Probe A was satisfied 30s *after* arming by a separate backgrounded Bash write, so the match was
detected live rather than being true at arm time. Result: match events, timeout notices, and
persistent-monitor events all reach a subagent.

## Why the mining number was wrong

Delivered notifications are **never written into sidechain transcripts**. Across the whole
projects tree:

| transcript kind | files containing a `queue-operation` record |
|---|---|
| top level | 424 |
| subagent sidechain | **0 of 2693** |

`queue-operation` is the entry type under which a top-level transcript persists an inbound
Monitor notification. This agent's own transcript contains **zero** of them, despite four
notifications demonstrably arriving in-band during this session.

So mining a sidechain transcript for evidence of delivery will find nothing whether or not
delivery happened — the observable simply does not exist there. The 132/137 "no notification"
figure measures transcript logging, not tool behaviour.

That also explains the oddly-clustered 5 successes on 07-28/29 without needing a race: the only
way a delivered event leaves a mark in a sidechain transcript is if the agent happens to *write
about it* in its own prose or a later shell command. That is incidental, not systematic. (This
note's own transcript is an example — the strings `Monitor event` and `task-notification` appear
in it several times, every one of them from my own greps and prose, none from a real
notification record.)

The version timeline rules out the remaining version-dependence story: the 07-28/29 cluster ran
on 2.1.220, and so did 07-27, 07-30, 07-31 and 08-02→08-05, which the mining scored as failures.
Same version, both outcomes — so version never explained that cluster either.

| hypothesis | verdict |
|---|---|
| Delivery is scoped to top level, silently dropped in sidechains | **Disproved** — 4/4 received here |
| Version-dependent regression fixed before 2.1.228 | **Unsupported** — successes and failures share 2.1.220 |
| Race / timing-dependent delivery | **Unsupported** — no failures reproduced across 3 probes and 3 code paths |
| Mining measured an observable that does not exist in sidechains | **Supported** — 0/2693 sidechain transcripts carry the record type |

Caveat worth keeping: this is one agent, one session, one CLI build, three probes. It is enough
to refute "notifications never arrive in sidechains", not enough to prove delivery is reliable
under load, at depth > 1, or across session boundaries. What it does establish firmly is that
*transcript mining cannot measure this at all* — any future claim about subagent watcher
delivery needs a live probe like the ones above, not a grep.

## Consequence for the hook

`hooks/bg-watchdog-monitor-guard.sh` therefore ships **dormant** — it allows every Monitor call
by default. It denies sidechain arms only when `BG_WATCHDOG_MONITOR_GUARD=1` is set, so the
machinery exists if delivery ever genuinely regresses. Re-run the probes above before enabling
it; the evidence decides, not the memory of the bug.

## Reproducing

From inside a subagent, arm a Monitor whose condition you satisfy afterwards from a backgrounded
Bash write, plus one that cannot be satisfied, and watch for the events in-band. Do **not** try
to confirm delivery by reading the sidechain `.jsonl` — as shown above, it will not be there.
