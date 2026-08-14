#!/usr/bin/env bash
# Shared assertions for the bg-watchdog hook tests.
# Each tests/*.test.sh sources this, then calls assert_* helpers and ends with
# `finish`. Tests are runnable standalone (`bash tests/foo.test.sh`) or via
# tests/run.sh.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
HOOKS_DIR="$REPO_DIR/hooks"
FIXTURES_DIR="$TESTS_DIR/fixtures"

PASS=0
FAIL=0
CURRENT=""

# Sandbox HOME so hooks that write ~/.claude/logs never touch the real install.
SANDBOX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/bgwd-home.XXXXXX")"
export HOME="$SANDBOX_HOME"
mkdir -p "$HOME/.claude/logs"
trap 'rm -rf "$SANDBOX_HOME"' EXIT

# fixture <name.json> -> path, with __FIXTURES__ expanded to the fixtures dir.
# Returns a path to a materialised copy under the sandbox.
fixture() {
  local name="$1" src="$FIXTURES_DIR/$1" dst
  dst="$SANDBOX_HOME/$(echo "$name" | tr '/' '_')"
  sed "s|__FIXTURES__|$FIXTURES_DIR|g" "$src" > "$dst"
  printf '%s' "$dst"
}

# run_hook <hook.sh> <stdin-file-or-json>  -> sets RC, OUT, ERR
run_hook() {
  local hook="$HOOKS_DIR/$1" input="$2" tmpout tmperr
  tmpout="$(mktemp)"; tmperr="$(mktemp)"
  if [ -f "$input" ]; then
    "$hook" <"$input" >"$tmpout" 2>"$tmperr"
  else
    printf '%s' "$input" | "$hook" >"$tmpout" 2>"$tmperr"
  fi
  RC=$?
  OUT="$(cat "$tmpout")"
  ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# with_timeout <secs> <cmd...> — macOS has no coreutils `timeout`; perl's alarm
# is always present. Guards tests against a hook that really sleeps.
with_timeout() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

_ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

it() { CURRENT="$1"; }

assert_rc() {
  local want="$1" msg="${2:-$CURRENT}"
  [ "$RC" = "$want" ] && _ok "$msg (rc=$want)" || _bad "$msg" "expected rc=$want, got rc=$RC; stderr=${ERR:0:160}"
}

assert_stdout_empty() {
  local msg="${1:-$CURRENT}"
  [ -z "$OUT" ] && _ok "$msg (no stdout)" || _bad "$msg" "expected empty stdout, got: ${OUT:0:200}"
}

assert_stdout_contains() {
  local needle="$1" msg="${2:-$CURRENT}"
  case "$OUT" in *"$needle"*) _ok "$msg (stdout has '$needle')" ;;
    *) _bad "$msg" "stdout missing '$needle'; got: ${OUT:0:200}" ;; esac
}

assert_stderr_contains() {
  local needle="$1" msg="${2:-$CURRENT}"
  case "$ERR" in *"$needle"*) _ok "$msg (stderr has '$needle')" ;;
    *) _bad "$msg" "stderr missing '$needle'; got: ${ERR:0:200}" ;; esac
}

assert_stderr_empty() {
  local msg="${1:-$CURRENT}"
  [ -z "$ERR" ] && _ok "$msg (no stderr)" || _bad "$msg" "expected empty stderr, got: ${ERR:0:200}"
}

assert_eq() {
  local got="$1" want="$2" msg="${3:-$CURRENT}"
  [ "$got" = "$want" ] && _ok "$msg ($want)" || _bad "$msg" "expected '$want', got '$got'"
}

# assert_json_field <jq-filter> <expected>
assert_json_field() {
  local filter="$1" want="$2" msg="${3:-$CURRENT}" got
  got="$(printf '%s' "$OUT" | jq -r "$filter" 2>/dev/null)"
  [ "$got" = "$want" ] && _ok "$msg ($filter = $want)" || _bad "$msg" "$filter: expected '$want', got '$got'"
}

ledger() { printf '%s' "$HOME/.claude/logs/subagent-deaths.jsonl"; }
ledger_lines() { [ -f "$(ledger)" ] && wc -l < "$(ledger)" | tr -d ' ' || echo 0; }
reset_ledger() { rm -f "$(ledger)"; }

finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
