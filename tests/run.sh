#!/usr/bin/env bash
# Test runner: executes every tests/*.test.sh and reports pass/fail totals.
# Usage: tests/run.sh [name-substring ...]
set -u

cd "$(dirname "$0")" || exit 1

files=()
if [ "$#" -gt 0 ]; then
  for pat in "$@"; do
    for f in *.test.sh; do
      case "$f" in *"$pat"*) files+=("$f") ;; esac
    done
  done
else
  for f in *.test.sh; do [ -e "$f" ] && files+=("$f"); done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "no test files matched" >&2
  exit 1
fi

total_pass=0
total_fail=0
failed_files=()

for f in "${files[@]}"; do
  printf '\n=== %s ===\n' "$f"
  out="$(bash "$f" 2>&1)"
  printf '%s\n' "$out"
  line="$(printf '%s' "$out" | tail -1)"
  p="$(printf '%s' "$line" | sed -nE 's/.*: ([0-9]+) passed, ([0-9]+) failed/\1/p')"
  q="$(printf '%s' "$line" | sed -nE 's/.*: ([0-9]+) passed, ([0-9]+) failed/\2/p')"
  total_pass=$((total_pass + ${p:-0}))
  total_fail=$((total_fail + ${q:-0}))
  [ "${q:-1}" = "0" ] || failed_files+=("$f")
done

printf '\n----------------------------------------\n'
printf 'TOTAL: %d passed, %d failed (%d/%d assertions)\n' \
  "$total_pass" "$total_fail" "$total_pass" "$((total_pass + total_fail))"
if [ "${#failed_files[@]}" -gt 0 ]; then
  printf 'failing files: %s\n' "${failed_files[*]}"
  exit 1
fi
exit 0
