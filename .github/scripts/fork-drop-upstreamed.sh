#!/usr/bin/env bash
# Fork-only helper for fork-rebase-onto.sh; it is not part of any upstream pull request.
# Runs as GIT_SEQUENCE_EDITOR: turns `pick` into `drop` for each fork commit listed in UPSTREAMED_LIST
# whose upstream commit TARGET already contains, and appends "<sha> <subject>" to DROP_REPORT.
# Usage: UPSTREAMED_LIST=<tsv> TARGET=<ref> DROP_REPORT=<file> fork-drop-upstreamed.sh <rebase todo>
set -euo pipefail
todo=$1
subjects=$(mktemp)
edited=$(mktemp)
trap 'rm -f "$subjects" "$edited"' EXIT

while IFS=$'\t' read -r upstream subject _; do
  case "$upstream" in '' | '#'*) continue ;; esac
  if git cat-file -e "${upstream}^{commit}" 2> /dev/null &&
    git merge-base --is-ancestor "$upstream" "$TARGET"; then
    printf '%s\n' "$subject" >> "$subjects"
  fi
done < "$UPSTREAMED_LIST"

while IFS= read -r line; do
  read -r command sha _ <<< "$line" || true
  if [[ "$command" == pick ]]; then
    subject=$(git log -1 --format=%s "$sha")
    if grep -Fxq -- "$subject" "$subjects"; then
      printf 'drop %s\n' "${line#pick }" >> "$edited"
      printf '%s %s\n' "$sha" "$subject" >> "$DROP_REPORT"
      continue
    fi
  fi
  printf '%s\n' "$line" >> "$edited"
done < "$todo"

mv "$edited" "$todo"
