#!/usr/bin/env bash
# Fork-only helper for fork-upstream-sync.yml; it is not part of any upstream pull request.
# Replays the fork commits <base>..HEAD onto <target> and leaves HEAD on the result.
# - Localizable .strings files merge with union: the fork and upstream both append strings at the end.
# - Fork commits listed in fork-upstreamed.tsv are dropped once <target> contains their upstream commit.
# - Conflicts resolved before are replayed from rerere-cache/. After resolving a new conflict by hand
#   in a clone with rerere enabled, copy its .git/rr-cache entries there so the next run reuses them.
# Prints a Markdown report on stdout. Exit 0: every commit applied. Exit 1: a conflict is left, the
# rebase was aborted, and HEAD is back where it started.
# Usage: fork-rebase-onto.sh <base> <target>
set -euo pipefail
base=$1
target=$2
here=$(cd "$(dirname "$0")" && pwd)
common_dir=$(git rev-parse --git-common-dir)
dropped=$(mktemp)
log=$(mktemp)
trap 'rm -f "$dropped" "$log"' EXIT

mkdir -p "$common_dir/info" "$common_dir/rr-cache"
printf '%s\n' '*.strings merge=union' >> "$common_dir/info/attributes"
if [[ -d "$here/rerere-cache" ]]; then
  cp -R "$here/rerere-cache/." "$common_dir/rr-cache/"
fi
git config rerere.enabled true
git config rerere.autoUpdate true

export UPSTREAMED_LIST="$here/fork-upstreamed.tsv" DROP_REPORT="$dropped" TARGET="$target"
export GIT_SEQUENCE_EDITOR="$here/fork-drop-upstreamed.sh" GIT_EDITOR=true
status=0
git rebase --interactive --empty=drop --onto "$target" "$base" >> "$log" 2>&1 || status=$?
# A stop that rerere resolved completely leaves no unmerged path; continue until done or stuck.
while ((status != 0)) && [[ -d "$(git rev-parse --git-path rebase-merge)" ]] &&
  [[ -z "$(git diff --name-only --diff-filter=U)" ]]; do
  status=0
  git rebase --continue >> "$log" 2>&1 || status=$?
done

echo "### Dropped because upstream already has them (fork-upstreamed.tsv)"
echo '```'
if [[ -s "$dropped" ]]; then cat "$dropped"; else echo "(none)"; fi
echo '```'
echo "### Conflicts resolved from rerere-cache"
echo '```'
# rerere prints "Staged" when rerere.autoUpdate stages the resolution, "Resolved" otherwise.
grep -E "^(Staged|Resolved) '.*' using previous resolution" "$log" || echo "(none)"
echo '```'
if ((status != 0)); then
  echo "### Rebase stopped with conflicts"
  echo '```'
  grep -E '^Could not apply' "$log" || true
  git status --short | grep -E '^(UU|AA|DD|AU|UA|DU|UD) ' || true
  echo '```'
  git rebase --abort || true
  exit 1
fi
