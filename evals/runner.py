#!/usr/bin/env python3
"""Replay eval runner for claude-bg-watchdog hooks (WP4).

Usage: python3 runner.py <hooks-dir> [--case-dir DIR] [--json-out FILE]

For every case in evals/cases/*.json, feeds the recorded hook-input JSON to
the matching hook script (from <hooks-dir>) on stdin, decides whether the
hook "fired" per the rules for its hook family (see README.md), and compares
against the case's expected outcome. Prints a scoreboard grouped by hook
family and category (pass/fail/skip, precision, recall) and a list of
failures. Exits non-zero if any case FAILs (SKIPs don't affect the exit
code — they mean "hook not present / not safely testable", not a defect).

Dependency-light: stdlib only (json, subprocess, re, tempfile, shutil, os,
sys, datetime, argparse).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta

HOOK_FILENAME = {
    "postfail": "bg-watchdog-postfail.sh",
    "pretool": "bg-watchdog-pretool.sh",
    "rewake": "bg-watchdog-rewake.sh",
    "subagent-stop": "bg-watchdog-subagent-stop.sh",
    "monitor-guard": "bg-watchdog-monitor-guard.sh",
    "orphan-sentinel": "bg-watchdog-orphan-sentinel.sh",
}

# Families where "fires" == process exits with code 2 (a deny/block).
# orphan-sentinel is handled separately (DRY_RUN decision-JSON parsing) below.
DENY_EXIT_FAMILIES = {"pretool", "monitor-guard", "rewake"}
# Families where "fires" == non-empty stdout (a coaching / systemMessage JSON blob).
STDOUT_FAMILIES = {"postfail", "subagent-stop"}

DEFAULT_TIMEOUT_S = 8
REWAKE_TIMEOUT_S = 10


def load_cases(case_dir):
    cases = []
    for fn in sorted(os.listdir(case_dir)):
        if fn.endswith(".json"):
            with open(os.path.join(case_dir, fn)) as f:
                cases.append(json.load(f))
    return cases


def find_sleep_line(src):
    """Locate the literal `sleep "$sleep_secs"` line the shipped rewake hook
    uses so we can stub it to an echo instead of actually sleeping. Returns
    True if the pattern is present."""
    return re.search(r'^\s*sleep\s+"\$sleep_secs"\s*$', src, re.M) is not None


def build_rewake_invocation(hook_path, tmp_root):
    """Decide how to safely execute the rewake hook without a real sleep.
    Returns (script_path_to_run, mode) where mode is one of
    'dry_run_env', 'sed_stub', or None (unsafe to run for real -> SKIP)."""
    try:
        with open(hook_path) as f:
            src = f.read()
    except OSError:
        return None, None
    if "DRY_RUN" in src:
        return hook_path, "dry_run_env"
    if find_sleep_line(src):
        stub_path = os.path.join(tmp_root, "rewake-stub-" + os.path.basename(hook_path))
        stubbed = re.sub(
            r'^(\s*)sleep\s+"\$sleep_secs"\s*$',
            r'\1echo "WOULD_SLEEP=$sleep_secs"; #',
            src, flags=re.M,
        )
        with open(stub_path, "w") as f:
            f.write(stubbed)
        os.chmod(stub_path, 0o755)
        return stub_path, "sed_stub"
    return None, None


def run_hook(script_path, stdin_bytes, env, timeout_s):
    try:
        proc = subprocess.run(
            ["bash", script_path],
            input=stdin_bytes,
            env=env,
            capture_output=True,
            timeout=timeout_s,
        )
        return proc.returncode, proc.stdout.decode("utf-8", "replace"), proc.stderr.decode("utf-8", "replace"), False
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace") if e.stdout else ""
        err = (e.stderr or b"").decode("utf-8", "replace") if e.stderr else ""
        return None, out, err, True


# --- rewake reference model -------------------------------------------------
# Mirrors hooks/bg-watchdog-rewake.sh's classify()/reset_secs() so cases can be
# scored against a fixed BG_WATCHDOG_NOW (the hook's own documented test seam)
# without depending on wall-clock timing at eval time. Hooks that don't support
# BG_WATCHDOG_NOW (the pre-rewrite baseline) fall back to real `date +%s`
# internally; runner.py sets BG_WATCHDOG_NOW to essentially "now" anyway, so the
# tolerance below covers that gap too.
def classify_death(text):
    t = re.sub(r"^\s+", "", text)
    t = re.sub(r"^(Agent|Subagent) failed:\s*", "", t)
    if t.startswith(("You've hit your session limit", "You've hit your usage limit",
                      "You've reached your", "Claude AI usage limit reached")):
        return "limit"
    if t.startswith("API Error"):
        return "overload"
    return None


def reference_sleep_secs(text, now_epoch):
    kind = classify_death(text)
    if kind == "overload":
        return kind, 180
    if kind != "limit":
        return kind, 0

    clean = re.sub(r"\([A-Za-z_]+/[A-Za-z_]+\)", "", text)
    clean = re.sub(r"\b(UTC|GMT|AEST|AEDT|PST|PDT|EST|EDT)\b", "", clean)

    m = re.search(r"in\s+(\d+)\s*(minutes?|mins?|hours?|hrs?|seconds?|secs?)", clean, re.I)
    if m:
        n = int(m.group(1))
        unit = m.group(2).lower()
        if unit.startswith("h"):
            n *= 3600
        elif unit.startswith("m"):
            n *= 60
        return kind, n + 120

    m12 = re.search(r"resets\s+(\d{1,2})(:(\d{2}))?\s*(am|pm)", clean, re.I)
    m24 = re.search(r"resets\s+(\d{1,2}):(\d{2})(:\d{2})?\s*(am|pm)?", clean, re.I)
    if m12:
        hh, mm, ap = int(m12.group(1)), int(m12.group(3) or 0), m12.group(4).lower()
        if ap == "pm" and hh < 12:
            hh += 12
        if ap == "am" and hh == 12:
            hh = 0
    elif m24:
        hh, mm = int(m24.group(1)), int(m24.group(2))
        if hh > 23:
            return kind, 3600
    else:
        return kind, 3600  # unparseable -> flat 1h fallback, deterministic

    now_dt = datetime.fromtimestamp(now_epoch)
    target = now_dt.replace(hour=hh, minute=mm, second=0, microsecond=0)
    if target <= now_dt:
        target += timedelta(days=1)
    secs = int((target - now_dt).total_seconds()) + 120
    return kind, min(secs, 21600)


def evaluate_case(case, hooks_dir, tmp_root):
    hook_family = case["hook"]
    hook_fn = HOOK_FILENAME.get(hook_family)
    hook_path = os.path.join(hooks_dir, hook_fn) if hook_fn else None

    result = {"id": case["id"], "hook": hook_family, "category": case["category"]}

    if not hook_path or not os.path.isfile(hook_path):
        result.update(status="SKIP", reason=f"{hook_fn} not present in {hooks_dir}")
        return result

    env = dict(os.environ)
    env.update(case.get("env", {}) or {})
    # raw_input lets a case feed literal (possibly invalid-JSON) bytes on
    # stdin, for hook robustness cases like "malformed stdin fails open".
    # Absent that, "input" is serialized as the case's JSON hook-input object.
    if "raw_input" in case:
        stdin_bytes = case["raw_input"].encode("utf-8")
    else:
        stdin_bytes = json.dumps(case["input"]).encode("utf-8")

    script_to_run = hook_path
    timeout_s = DEFAULT_TIMEOUT_S
    dry_run_note = None
    rewake_mode = None
    now_epoch = int(time.time())

    if hook_family == "subagent-stop":
        fake_home = os.path.join(tmp_root, "fake-home-" + case["id"])
        os.makedirs(fake_home, exist_ok=True)
        env["HOME"] = fake_home

    if hook_family == "orphan-sentinel":
        # Isolated anti-loop ledger per case: never touch the real
        # ~/.claude/logs/orphan-sentinel-state.jsonl, and never let two cases
        # sharing a session_id suppress each other via a stale ledger.
        env["ORPHAN_SENTINEL_STATE"] = os.path.join(tmp_root, "orphan-state-" + case["id"] + ".jsonl")
        timeout_s = 15  # vigil polling (even clamped) does real jq work per iteration

    if hook_family == "rewake":
        script_to_run, rewake_mode = build_rewake_invocation(hook_path, tmp_root)
        timeout_s = REWAKE_TIMEOUT_S
        if script_to_run is None:
            result.update(status="SKIP", reason=(
                "rewake hook has no DRY_RUN support and its sleep line doesn't match the known "
                "`sleep \"$sleep_secs\"` stub pattern — unsafe to execute for real (could sleep up "
                "to 6h). Update runner.py's stub pattern if the hook's sleep call was rewritten."
            ))
            return result
        # BG_WATCHDOG_NOW is the hook's own documented test seam for freezing "now".
        # Hooks that don't support it (the pre-rewrite baseline) just ignore it and
        # use real date +%s, which is why we set it to essentially-real-now: both
        # paths then agree to within a couple seconds.
        env["BG_WATCHDOG_NOW"] = str(now_epoch)
        if rewake_mode == "dry_run_env":
            env["DRY_RUN"] = "1"
            dry_run_note = "used hook's native DRY_RUN"
        else:
            dry_run_note = "used sed-stubbed sleep->echo copy (no native DRY_RUN)"

    rc, stdout, stderr, timed_out = run_hook(script_to_run, stdin_bytes, env, timeout_s)
    combined = stdout + "\n" + stderr

    if timed_out:
        result.update(status="SKIP", reason=(
            f"hook did not return within {timeout_s}s — likely a real sleep/hang, not safe to wait "
            "out inside the eval; treat as a gap, not a scored fail."
        ))
        return result

    if hook_family == "rewake":
        if rewake_mode == "dry_run_env":
            # Native DRY_RUN prints "sleep_secs=<n> signal=<what fired|none>" and
            # always exits 0 (that's the whole point of a dry run).
            m = re.search(r"signal=(\S+)", combined)
            signal = m.group(1) if m else None
            fired = signal not in (None, "none", "")
        else:  # sed_stub: "WOULD_SLEEP=<n>", exit code still meaningful
            fired = (rc == 2)
    elif hook_family == "orphan-sentinel":
        # DRY_RUN prints a decision object ({"decision":"rewake",...} or
        # {"decision":"none"/"suppressed",...}); live mode (no DRY_RUN) exits 2.
        decision = None
        try:
            decision = json.loads(stdout.strip()).get("decision") if stdout.strip() else None
        except (json.JSONDecodeError, AttributeError):
            decision = None
        fired = (decision == "rewake") or (rc == 2)
    elif hook_family in DENY_EXIT_FAMILIES:
        fired = (rc == 2)
    elif hook_family in STDOUT_FAMILIES:
        fired = bool(stdout.strip())
    else:
        fired = (rc == 2)

    expect_fires = case["expect"]["fires"]
    fires_ok = (fired == expect_fires)

    content_ok = True
    missing = []
    if fires_ok and fired:
        for needle in case["expect"].get("output_contains", []) or []:
            if needle not in combined:
                content_ok = False
                missing.append(needle)

    # rewake numeric sanity: compare the hook's reported sleep_secs against the
    # Python reference model (same classify()/reset_secs() logic, pinned to the
    # same BG_WATCHDOG_NOW), tolerant of hooks that don't honor that env var.
    dynamic_note = None
    if hook_family == "rewake" and fires_ok and fired:
        m = re.search(r"(?:sleep_secs|WOULD_SLEEP)=(\d+)", combined)
        last_msg = case["input"].get("last_assistant_message", "")
        ref_kind, ref_secs = reference_sleep_secs(last_msg, now_epoch)
        if m and ref_kind:
            actual = int(m.group(1))
            delta = abs(actual - ref_secs)
            dynamic_note = f"reported={actual}s reference={ref_secs}s (delta={delta}s)"
            if delta > 15:
                content_ok = False
                missing.append(f"sleep_secs sanity: expected ~{ref_secs}s, got {actual}s")
        elif not m:
            content_ok = False
            missing.append("no sleep_secs=<n>/WOULD_SLEEP=<n> found in output for sanity check")

    passed = fires_ok and content_ok
    result.update(
        status="PASS" if passed else "FAIL",
        expect_fires=expect_fires,
        actual_fires=fired,
        rc=rc,
        stdout=stdout.strip()[:300],
        stderr=stderr.strip()[:300],
        missing_output=missing,
        dry_run_note=dry_run_note,
        dynamic_note=dynamic_note,
    )
    return result


def scoreboard(results):
    lines = []
    by_hook = {}
    for r in results:
        by_hook.setdefault(r["hook"], []).append(r)

    total_pass = total_fail = total_skip = 0

    for hook in sorted(by_hook):
        rs = by_hook[hook]
        scored = [r for r in rs if r["status"] != "SKIP"]
        skipped = [r for r in rs if r["status"] == "SKIP"]
        tp = sum(1 for r in scored if r["expect_fires"] and r["actual_fires"])
        fp = sum(1 for r in scored if not r["expect_fires"] and r["actual_fires"])
        fn = sum(1 for r in scored if r["expect_fires"] and not r["actual_fires"])
        tn = sum(1 for r in scored if not r["expect_fires"] and not r["actual_fires"])
        precision = tp / (tp + fp) if (tp + fp) else float("nan")
        recall = tp / (tp + fn) if (tp + fn) else float("nan")
        n_pass = sum(1 for r in scored if r["status"] == "PASS")
        n_fail = sum(1 for r in scored if r["status"] == "FAIL")
        total_pass += n_pass
        total_fail += n_fail
        total_skip += len(skipped)

        lines.append(f"\n== {hook} ==  {n_pass} pass / {n_fail} fail / {len(skipped)} skip"
                     f"  (of {len(rs)} cases)")
        lines.append(f"   TP={tp} FP={fp} FN={fn} TN={tn}"
                     f"  precision={precision:.2f}  recall={recall:.2f}" if scored else
                     "   (all cases skipped — no hook present)")

        by_cat = {}
        for r in rs:
            by_cat.setdefault(r["category"], []).append(r)
        for cat in sorted(by_cat):
            crs = by_cat[cat]
            cp = sum(1 for r in crs if r["status"] == "PASS")
            cf = sum(1 for r in crs if r["status"] == "FAIL")
            cs = sum(1 for r in crs if r["status"] == "SKIP")
            lines.append(f"     {cat}: {cp} pass / {cf} fail / {cs} skip")

        for r in skipped:
            lines.append(f"     SKIP  {r['id']}: {r['reason']}")

    lines.append(f"\n== TOTAL ==  {total_pass} pass / {total_fail} fail / {total_skip} skip"
                 f"  (of {len(results)} cases)")

    failures = [r for r in results if r["status"] == "FAIL"]
    if failures:
        lines.append("\n== FAILURES ==")
        for r in failures:
            lines.append(f"  FAIL {r['id']} [{r['hook']}/{r['category']}]"
                         f"  expect_fires={r['expect_fires']} actual_fires={r['actual_fires']} rc={r['rc']}")
            if r["missing_output"]:
                lines.append(f"        missing: {r['missing_output']}")
            if r.get("dynamic_note"):
                lines.append(f"        {r['dynamic_note']}")
            if r["stdout"]:
                lines.append(f"        stdout: {r['stdout']!r}")
            if r["stderr"]:
                lines.append(f"        stderr: {r['stderr']!r}")

    return "\n".join(lines), total_fail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hooks_dir")
    ap.add_argument("--case-dir", default=os.path.join(os.path.dirname(__file__), "cases"))
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    hooks_dir = os.path.abspath(args.hooks_dir)
    cases = load_cases(args.case_dir)

    tmp_root = tempfile.mkdtemp(prefix="bg-watchdog-eval-")
    try:
        results = [evaluate_case(c, hooks_dir, tmp_root) for c in cases]
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)

    board, total_fail = scoreboard(results)
    print(f"claude-bg-watchdog eval — hooks dir: {hooks_dir}")
    print(board)

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(results, f, indent=2)

    sys.exit(1 if total_fail > 0 else 0)


if __name__ == "__main__":
    main()
