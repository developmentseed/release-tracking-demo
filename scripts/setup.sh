#!/usr/bin/env bash
# Bootstrap the demo: repo, project board, credentials, baseline release.
# Safe to re-run: every step checks what already exists and skips it.
#
# Usage: scripts/setup.sh <owner> [--repo NAME] [--public] [--auth app|pat]
#
#   --repo    repo (and board) name; default: release-tracking-demo
#   --public  create a public repo (default: private). Only applies on creation.
#   --auth    app: create a GitHub App (owner must be an organization)
#             pat: paste a classic PAT with 'repo' + 'project' scopes
#             default: app for organizations, pat for personal accounts
set -euo pipefail

usage() { sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

owner="" repo="release-tracking-demo" visibility="--private" auth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   repo="${2:?--repo needs a value}"; shift 2 ;;
    --public) visibility="--public"; shift ;;
    --auth)   auth="${2:?--auth needs app or pat}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *)  [[ -z "$owner" ]] || { echo "Unexpected argument: $1"; usage; }; owner="$1"; shift ;;
  esac
done
[[ -n "$owner" ]] || usage
full="$owner/$repo"

for cmd in gh jq git; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }; done
if ! gh auth status 2>&1 | grep -q "'project'"; then
  echo "Your gh login needs the 'project' scope. Run: gh auth refresh -s project"; exit 1
fi

owner_type=$(gh api "users/$owner" --jq .type)
[[ -n "$auth" ]] || { [[ "$owner_type" == "Organization" ]] && auth=app || auth=pat; }
if [[ "$auth" == "app" && "$owner_type" != "Organization" ]]; then
  echo "GitHub Apps can't access Projects owned by a personal account ($owner)."
  echo "Use an organization as the owner, or run with --auth pat."; exit 1
fi
[[ "$auth" == "app" || "$auth" == "pat" ]] || usage

echo "==> Local git repo"
if [[ ! -d .git ]]; then
  git init -b main && git add -A && git commit -m "chore: initial commit"
elif [[ -n "$(git status --porcelain)" ]]; then
  git add -A && git commit -m "chore: update demo setup"
fi

echo "==> Repo $full"
if gh repo view "$full" >/dev/null 2>&1; then
  echo "    exists; reusing"
else
  gh repo create "$full" "$visibility"
fi
remote="https://github.com/$full.git"
[[ "$(gh config get git_protocol 2>/dev/null)" == "ssh" ]] && remote="git@github.com:$full.git"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$remote"
else
  git remote add origin "$remote"
fi

echo "==> Merge settings: squash only, commit title = PR title"
gh api -X PATCH "repos/$full" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true

echo "==> Project board"
project_url=$(gh variable get PROJECT_URL --repo "$full" 2>/dev/null || true)
if [[ -n "$project_url" ]]; then
  echo "    PROJECT_URL already set; reusing $project_url"
else
  project_json=$(gh project create --owner "$owner" --title "$repo" --format json)
  project_number=$(jq -r '.number' <<<"$project_json")
  project_url=$(jq -r '.url' <<<"$project_json")
  gh project link "$project_number" --owner "$owner" --repo "$full"
  gh variable set PROJECT_URL --repo "$full" --body "$project_url"
  echo "    $project_url"
fi

echo "==> Credentials ($auth)"
if [[ "$auth" == "app" ]]; then
  if gh variable get APP_ID --repo "$full" >/dev/null 2>&1; then
    echo "    APP_ID already set; reusing"
  else
    "$(dirname "$0")/create-app.sh" "$owner" "$repo"
    read -rp "    Press Enter once the App is installed on $full..."
  fi
else
  if gh secret list --repo "$full" --json name --jq '.[].name' | grep -qx AUTOMATION_TOKEN; then
    echo "    AUTOMATION_TOKEN already set; reusing"
  else
    echo "    Paste a classic PAT with 'repo' + 'project' scopes."
    gh secret set AUTOMATION_TOKEN --repo "$full"
  fi
fi

echo "==> Pushing main"
git push -u origin main

echo "==> Baseline release v0.1.0"
# release-commenter ignores a repo's first release, so the baseline must exist
# before the demo's first real release (v0.2.0).
if gh release view v0.1.0 --repo "$full" >/dev/null 2>&1; then
  echo "    exists; skipping"
else
  gh release create v0.1.0 --repo "$full" --target main --title "v0.1.0" --notes "Baseline release."
fi

cat <<EOF

Done. Two things the API can't do for you — finish them in the browser:

  1. Open $project_url
     Settings > Status field: add an option named "Released"
     (keep Todo / In Progress / Done).
  2. Switch the default view to Board layout (View menu > Layout > Board).

Then run:  scripts/demo.sh "Add a greeting"
EOF
