#!/usr/bin/env bash
# One-time bootstrap: creates the GitHub repo + project, wires up the secret and
# variable the workflows need, pushes the code, and cuts the v0.1.0 baseline
# release. Run from the root of this folder.
#
# Usage: scripts/setup.sh <owner> [repo-name] [--public]
set -euo pipefail

owner="${1:?usage: scripts/setup.sh <owner> [repo-name] [--public]}"
repo="${2:-release-tracking-demo}"
visibility="--private"
[[ "${3:-}" == "--public" ]] && visibility="--public"
full="$owner/$repo"

command -v gh >/dev/null || { echo "Install the GitHub CLI: https://cli.github.com"; exit 1; }
command -v jq >/dev/null || { echo "Install jq"; exit 1; }

if ! gh auth status 2>&1 | grep -q "'project'"; then
  echo "Your gh login needs the 'project' scope. Run: gh auth refresh -s project"
  exit 1
fi

echo "==> Creating local git repo"
if [[ ! -d .git ]]; then
  git init -b main
  git add -A
  git commit -m "chore: initial commit"
fi

echo "==> Creating $full ($visibility)"
gh repo create "$full" "$visibility" --source=. --remote=origin

echo "==> Merge settings: squash only, commit title = PR title"
gh api -X PATCH "repos/$full" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true

echo "==> Creating project board"
project_json=$(gh project create --owner "$owner" --title "$repo" --format json)
project_number=$(jq -r '.number' <<<"$project_json")
project_url=$(jq -r '.url' <<<"$project_json")
gh project link "$project_number" --owner "$owner" --repo "$full"
gh variable set PROJECT_URL --repo "$full" --body "$project_url"
echo "    $project_url"

echo "==> Setting AUTOMATION_TOKEN secret"
echo "    Paste a token with access to this repo AND the project"
echo "    (classic PAT with 'repo' + 'project' scopes for a personal account)."
gh secret set AUTOMATION_TOKEN --repo "$full"

echo "==> Pushing main"
git push -u origin main

echo "==> Creating baseline release v0.1.0"
# release-commenter ignores a repo's first release, so the baseline must exist
# before the demo's first real release (v0.2.0).
gh release create v0.1.0 --repo "$full" --target main --title "v0.1.0" --notes "Baseline release."

cat <<EOF

Done. Two things the API can't do for you — finish them in the browser:

  1. Open $project_url
     Settings > Status field: add an option named "Released"
     (keep Todo / In Progress / Done).
  2. Switch the default view to Board layout (View menu > Layout > Board),
     columns = Status.

Optional: in the project's Workflows, turn off "Item closed" and
"Pull request merged" so only this repo's workflows move cards.

Then run:  scripts/demo.sh "Add a greeting"
EOF
