#!/usr/bin/env bash
# Fork-only helper for fork-upstream-sync.yml; it is not part of any upstream pull request.
# Prints the upstream releases whose notes carry a Security heading, a "- Security:" bullet or a
# CVE id, and that <ref> does not contain yet, oldest first. Needs gh and the upstream tags fetched.
# Usage: fork-upstream-security-notes.sh <owner/repo> <ref>
set -euo pipefail
repo=$1
ref=$2

gh api "repos/${repo}/releases?per_page=100" \
  --jq '[.[] | select(.draft == false and .prerelease == false)]
        | sort_by(.published_at) | .[]
        | select((.body // "") | split("\n") | any(test("^#+ *Security|^- *Security:|CVE-[0-9]{4}-")))
        | .tag_name' |
  while read -r tag; do
    git rev-parse --verify --quiet "refs/tags/${tag}" < /dev/null > /dev/null || continue
    if git merge-base --is-ancestor "$tag" "$ref" < /dev/null; then
      continue
    fi
    echo "$tag"
  done
