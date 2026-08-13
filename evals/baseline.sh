#!/usr/bin/env bash
# Extract the git-HEAD (committed, pre-rewrite) hook scripts into
# evals/baseline-hooks/, so the eval suite can score a fixed historical
# snapshot independent of whatever sibling agents are mid-rewriting on disk.
# Re-run any time to refresh; safe no-op if HEAD hasn't moved.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
out="$here/baseline-hooks"
mkdir -p "$out"

cd "$repo"
for path in $(git ls-tree -r HEAD --name-only | grep '^hooks/'); do
  name=$(basename "$path")
  git show "HEAD:$path" > "$out/$name"
  chmod +x "$out/$name"
  echo "extracted $path -> evals/baseline-hooks/$name"
done
echo "(monitor-guard / orphan-sentinel not in HEAD yet -> absent from baseline-hooks/, eval will SKIP them)"
