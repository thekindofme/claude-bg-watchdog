# claude-bg-watchdog

Durable fixpack for a recurring Claude Code pain: **long-running background work
(background shells, subagents, deploys, pollers) dies, times out, hangs, or
finishes without the orchestrating session ever acting on it** — and the session
stalls until Yasith notices.

Built 2026-07-24 from a 5-agent audit of 21 days of session transcripts
(~2,200 `.jsonl` files under `~/.claude/projects`). This repo is the canonical
source + write-up; the **live** copies deploy to `~/.claude` via `./install.sh`.

## Audit findings (what actually goes wrong)

| Rank | Failure mode | Scale (21 days) | Self-heals? |
|---|---|---|---|
| 1 | Subagent dies at **usage-limit reset** ("session limit · resets 5pm"); session sits idle until user types "cont" | 18% of bg-task failures; recurs daily at Melbourne reset times (12:30pm/4pm/5pm) | **No** — worst offender |
| 2 | Foreground **sleep-loop polls** on Buildkite/Step Functions/subagent output + missing `timeout` param | 102 foreground timeouts ≈ **6.2h blocked**; 48% hand-rolled polls; 73% on bare 2m default; one session burned 2.5h re-polling SFN 15× | Recovers but wastes hours |
| 3 | **Silent poller/subagent death** (529 Overloaded, crash, Ctrl+C) discovered hours later via empty evidence dirs | ~7.3% of subagents end abnormally (3% interrupt, 3% crash, 1% dangling); 3 dead pollers in a single session | Often no |
| 4 | **Monitor timeout disarms silently** ("re-arm if needed") and nobody re-arms | 4× in one Buildkite-watch session | No |
| 5 | Buildkite poll pinned to a build number that gets **canceled/superseded** by a newer commit | 13 deploy-wait failures | Yes (~20s) |
| 6 | Dev gateway startup **exit 126** — volta/Node-20 interpreter mismatch, retried identically | 26 dev-server failures | Yes, wastes cycles |
| 7 | Truly orphaned/lost work | **1 / 1,075 launches (0.09%)** | n/a — rare |

Key insight: the pain is **stalls + wasted wall-clock + late discovery**, not lost
tasks. Manual polling discipline (TaskStop after manual verify) keeps real
work-loss near zero; what's missing is automatic recovery and immediate death
visibility.

Raw evidence: `analysis/data/` (deduped failure/kill lists, timeout events,
orphan results, user-frustration quotes). Extraction scripts: `analysis/scripts/`.

## The fixes and how each one helps

### Layer 1 — env (settings.json `env` block)

| Var | Change | Targets |
|---|---|---|
| `BASH_DEFAULT_TIMEOUT_MS` | 2m → **5m** (300000) | 74/102 timeouts hit the forgotten 2m default on legit-slow work (CloudWatch scans, renders). Most now finish; no retry turn, no duplicate run. Cost: a true hang blocks 5m not 2m — acceptable (hangs 25 vs slow-legit 75 in data). |
| `BASH_MAX_TIMEOUT_MS` | 10m → **30m** (1800000) | SFN runs take ~13min; the model literally could not set an adequate timeout (10m cap) and re-issued doomed polls 15×. Ceiling now above real job durations. |

### Layer 2 — watchdog hooks (`hooks/`, deployed to `~/.claude/hooks/`)

| Hook | Event | Mechanism |
|---|---|---|
| `bg-watchdog-pretool.sh` | PreToolUse[Bash] | **Blocks** foreground `while/until/for … sleep ≥15s` poll loops (exit 2 + stderr guidance) before they run — the only point where the 2–10min burn is preventable. Redirects to `run_in_background` or Monitor. Short local waits (`sleep 1`) pass. |
| `bg-watchdog-postfail.sh` | PostToolUse + PostToolUseFailure [Bash] | On "Command timed out": injects `additionalContext` decision rule — background it / re-run ONCE with sized timeout / zero output = hang → `pkill`, don't extend. Kills the observed re-run-identical-command reflex. |
| `bg-watchdog-subagent-stop.sh` | SubagentStop | If `last_assistant_message` looks like a death (session limit / API Error / 529 / rate limit): append to `~/.claude/logs/subagent-deaths.jsonl` + emit `systemMessage`. Death detection latency: hours → seconds. Ledger doubles as the rewake hook's work-list. |
| `bg-watchdog-rewake.sh` | Stop (`async` + `asyncRewake`) | Fixes rank-1. Parses "resets 5pm"-style time (or 529) from the last assistant message; sleeps until reset+2min (cap 6h; 3min for 529); exits 2 → **session wakes itself** with instruction to check the death ledger + TaskList and resume dead agents via SendMessage (resume keeps context; respawn loses it). Removes the human as the retry mechanism. |

### Layer 3 — behavior rules (`rules/background-work.md` → `~/.claude/rules/`)

Judgment rules hooks can't mechanically enforce, auto-loaded every session:
never foreground-wait on async work; size foreground timeouts explicitly;
no fire-and-forget pollers; Monitor filters must match **failure** states
(silence ≠ success); re-arm timed-out Monitors; follow superseded Buildkite
builds (poll branch/PR state, not a build number); exit 126 = fix interpreter,
don't retry; dead agents get **resumed, not restarted**.

## Coverage map

```
stall-until-human ──── rewake hook + death ledger      (rank 1)
wasted blocking ────── pretool block + env timeouts    (rank 2)
wasted retries ─────── postfail coaching               (rank 2)
silent death ───────── ledger + Monitor rules          (ranks 3–4)
brittle polls ──────── rules: successor builds, filters(ranks 5–6)
```

## Verification status

- All 4 hooks unit-tested against sample stdin payloads (block/pass/parse/silent
  cases green; "resets 5pm" from 14:15 computed a 2h47m sleep correctly).
- `settings.json` validated as JSON post-edit.
- **Unverified doc gaps** (first suspects if the rewake never fires live):
  `asyncRewake` support on Stop hooks; `additionalContext` acceptance from
  PostToolUseFailure; whether an async hook's `timeout` (set to 25200s) kills
  the sleeping rewake early. Docs: https://code.claude.com/docs/en/hooks.md,
  https://code.claude.com/docs/en/env-vars.md.

## Deliberately NOT set (candidate tunables)

- `CLAUDE_AUTO_BACKGROUND_TASKS=1` — auto-backgrounds subagents after ~2min
  (and long MCP calls in non-interactive mode, v2.1.212+). Behavior change;
  enable if foreground Agent blocking becomes a pain.
- `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS` — default 10m stall-abort for background
  subagents (progress-resettable). No audit evidence it was a top killer; raise
  to 30m only if stall-aborts show up in the death ledger.

## Install / rollback

```sh
./install.sh          # copies hooks + rules into ~/.claude, prints settings diff hints
```

Rollback: each piece is independent — delete the hook entry from
`~/.claude/settings.json` and/or remove `~/.claude/hooks/bg-watchdog-*.sh`,
`~/.claude/rules/background-work.md`. Env vars revert by deleting the `env`
block entries. `settings-fragment.json` in this repo records the exact wiring.

## Success criteria (re-audit in ~3 weeks)

1. "Command timed out after 2m 0s" events ≈ 0 (default now 5m; loops blocked).
2. Session-limit deaths auto-resume — no more manual "cont" (grep transcripts
   for the rewakeSummary "limit-reset watchdog").
3. `subagent-deaths.jsonl` entries correlate with prompt resumes, not
   hours-later discoveries.
4. Foreground-blocked time from timeouts well under the 6.2h baseline.
   Re-run: `analysis/scripts/extract2.py` (timeouts), `analyze.py` (failures),
   `orphan_analysis.py` (orphans).
