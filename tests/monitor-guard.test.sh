#!/usr/bin/env bash
# Tests for hooks/bg-watchdog-monitor-guard.sh.
# Self-contained: run directly (./tests/monitor-guard.test.sh) or via tests/run.sh.
# Feeds hook-input JSON on stdin, asserts exit code and stderr content.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook="$here/../hooks/bg-watchdog-monitor-guard.sh"
fixtures="$here/fixtures"

pass=0
fail=0

# run <fixture> <guard-enabled 0|1> -> sets $code and $err
run() {
  local fx="$fixtures/$1" enabled="$2"
  err=$(BG_WATCHDOG_MONITOR_GUARD="$enabled" bash "$hook" <"$fx" 2>&1 >/dev/null)
  code=$?
}

ok() { pass=$((pass + 1)); echo "  ok   - $1"; }
no() { fail=$((fail + 1)); echo "  FAIL - $1"; echo "         $2"; }

expect_allow() { # <label> <fixture> <enabled>
  run "$2" "$3"
  if [ "$code" -eq 0 ]; then ok "$1"; else no "$1" "expected exit 0, got $code (stderr: $err)"; fi
}

expect_deny() { # <label> <fixture> <enabled>
  run "$2" "$3"
  if [ "$code" -ne 2 ]; then
    no "$1" "expected exit 2, got $code"
  elif ! grep -q 'subagent sidechain' <<<"$err"; then
    no "$1" "deny message missing the sidechain explanation: $err"
  elif ! grep -q 'run_in_background' <<<"$err"; then
    no "$1" "deny message missing the actionable alternative: $err"
  elif ! grep -q 'MONITOR_GUARD_OVERRIDE' <<<"$err"; then
    no "$1" "deny message does not document the override token: $err"
  else
    ok "$1"
  fi
}

echo "monitor-guard.test.sh"

# Shipped default is dormant: verified on CLI 2.1.228 (2026-08-12) that Monitor
# notifications DO reach subagent sidechains, so the guard must not block.
expect_allow "dormant by default: subagent arm passes when guard unset"   monitor-guard-subagent.json 0
expect_allow "dormant by default: top-level arm passes when guard unset"  monitor-guard-toplevel.json 0

# With the guard enabled (delivery regressed), only sidechain arms are denied.
expect_allow "enabled: top-level arm still allowed"                       monitor-guard-toplevel.json 1
expect_deny  "enabled: subagent arm denied with guidance"                 monitor-guard-subagent.json 1

# Detection signals work independently of one another.
expect_deny  "enabled: detected via transcript_path alone"                monitor-guard-subagent-pathonly.json 1
expect_deny  "enabled: detected via agent_id when path is absent"         monitor-guard-subagent-idonly.json 1

# Escape hatch and defensive routing.
expect_allow "enabled: MONITOR_GUARD_OVERRIDE token bypasses the deny"    monitor-guard-override.json 1
expect_allow "enabled: non-Monitor tool input is passed through"          monitor-guard-nonmonitor.json 1

# Malformed input must never wedge a session.
err=$(BG_WATCHDOG_MONITOR_GUARD=1 bash "$hook" <<<'not json at all' 2>&1 >/dev/null); code=$?
if [ "$code" -eq 0 ]; then ok "enabled: malformed stdin fails open"; else no "enabled: malformed stdin fails open" "expected exit 0, got $code"; fi

echo "monitor-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
