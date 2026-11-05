#!/usr/bin/env bash
# Walk one piece of work through the lifecycle, pausing so you can watch the
# project board between steps.
#
# Usage: scripts/demo.sh ["Issue title"] [feat|fix]
set -euo pipefail

title="${1:-Add a greeting}"
type="${2:-feat}"   # feat -> minor bump, fix -> patch bump
pause() { read -rp $'\n'"$1 — press Enter to continue..."; }

git switch main >/dev/null && git pull --quiet

echo "==> 1. Opening an issue"
issue_url=$(gh issue create --title "$title" --body "Demo work item.")
num="${issue_url##*/}"
echo "    $issue_url"
pause "Issue #$num should appear in Todo"

echo "==> 2. Opening a PR that closes #$num"
branch="demo/issue-$num"
git switch -c "$branch"
echo "- $title (#$num)" >> FEATURES.md
git commit -am "$type: $title"
git push -u origin "$branch"
gh pr create --base main --title "$type: $title" --body "Closes #$num"
pause "Issue #$num should move to In Progress"

echo "==> 3. Merging the PR"
gh pr merge "$branch" --squash --delete-branch
git switch main && git pull --quiet
pause "Issue #$num should be in Done, and a Release PR should be open (or updated)"

echo "Release PR(s):"
gh pr list --label "autorelease: pending"
cat <<EOF

Run this script again to add more work to the same release, or ship it:

  gh pr merge <release-pr-number> --squash

After the release is published, every issue in it gets a
"released in vX.Y.Z" label and moves to Released.
EOF
