#!/usr/bin/env bash
# Replay eval suite for claude-bg-watchdog hooks.
# Usage: ./run.sh [hooks-dir]   (default: ../hooks, i.e. the live in-repo hooks)
#        ./run.sh baseline-hooks   (the git-HEAD snapshot extracted by baseline.sh)
# hooks-dir may be run from any cwd: a relative path that doesn't exist as
# given is resolved against evals/ (where "baseline-hooks" and "../hooks"
# actually live) before falling back to the literal argument.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hooks_dir="${1:-$here/../hooks}"
if [ ! -d "$hooks_dir" ] && [ -d "$here/$hooks_dir" ]; then
  hooks_dir="$here/$hooks_dir"
fi
exec python3 "$here/runner.py" "$hooks_dir" "${@:2}"
