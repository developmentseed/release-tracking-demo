#!/usr/bin/env bash
# shellcheck disable=SC2016  # GraphQL $variables are intentionally literal
# Bootstrap the demo: repo, project board, credentials, baseline release.
# Idempotent: every step checks GitHub's current state, so re-run it freely
# (e.g. after an interruption) and it only does what's still missing.
#
# Usage: scripts/setup.sh <owner> [options]
#
#   --repo NAME         repo (and board) name; default: release-tracking-demo
#   --public|--private  repo visibility (applied to an existing repo too)
#   --app SLUG          reuse an existing org GitHub App, e.g. ds-release-bot,
#                       whose credentials are the org secrets DS_RELEASE_BOT_ID
#                       and DS_RELEASE_BOT_PRIVATE_KEY
#                       Without --app, you paste a classic PAT with 'repo' +
#                       'project' scopes instead (stored as AUTOMATION_TOKEN).
set -euo pipefail

usage() { sed -n '7,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
step() { echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
open_url() { (command -v open >/dev/null && open "$1") || (command -v xdg-open >/dev/null && xdg-open "$1") || true; }

owner="" repo="release-tracking-demo" visibility="" auth="pat" app_slug=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    repo="${2:?--repo needs a value}"; shift 2 ;;
    --public)  visibility="public"; shift ;;
    --private) visibility="private"; shift ;;
    --app)     app_slug="${2:?--app needs an App slug}"; auth="app"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *)  [[ -z "$owner" ]] || { echo "Unexpected argument: $1"; usage; }; owner="$1"; shift ;;
  esac
done
[[ -n "$owner" ]] || usage
full="$owner/$repo"

for cmd in gh jq git; do command -v "$cmd" >/dev/null || die "missing $cmd"; done
gh auth status 2>&1 | grep -q "'project'" || die "gh needs the 'project' scope: gh auth refresh -s project"

owner_type=$(gh api "users/$owner" --jq .type)
[[ "$auth" == "pat" || "$owner_type" == "Organization" ]] ||
  die "GitHub Apps can't access Projects owned by a personal account ($owner). Use an org, or drop --app to use a PAT."

# ---------------------------------------------------------------------------
step "Local git repo"
if [[ ! -d .git ]]; then
  git init -b main && git add -A && git commit -m "chore: initial commit"
elif [[ -n "$(git status --porcelain)" ]]; then
  git add -A && git commit -m "chore: update demo setup"
else
  info "clean"
fi

# ---------------------------------------------------------------------------
step "Repo $full"
if current=$(gh repo view "$full" --json visibility --jq '.visibility | ascii_downcase' 2>/dev/null); then
  info "exists ($current)"
  if [[ -n "$visibility" && "$visibility" != "$current" ]]; then
    gh repo edit "$full" --visibility "$visibility" --accept-visibility-change-consequences
    info "changed to $visibility"
  fi
else
  gh repo create "$full" "--${visibility:-private}"
fi
remote="https://github.com/$full.git"
[[ "$(gh config get git_protocol 2>/dev/null)" == "ssh" ]] && remote="git@github.com:$full.git"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$remote"
else
  git remote add origin "$remote"
fi

step "Merge settings: squash only, commit title = PR title"
gh api -X PATCH "repos/$full" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true

# ---------------------------------------------------------------------------
step "Project board"
project_url=$(gh variable get PROJECT_URL --repo "$full" 2>/dev/null || true)
if [[ -z "$project_url" ]]; then
  # A previous run may have created the board but died before saving the variable.
  project_url=$(gh project list --owner "$owner" --limit 1000 --format json |
    jq -r --arg t "$repo" '[.projects[] | select(.title == $t and (.closed | not))][0].url // empty')
  if [[ -n "$project_url" ]]; then
    info "found existing board titled '$repo'"
  else
    project_url=$(gh project create --owner "$owner" --title "$repo" --format json | jq -r .url)
    info "created"
  fi
  gh variable set PROJECT_URL --repo "$full" --body "$project_url"
fi
info "$project_url"
project_number="${project_url##*/}"

linked=$(gh api graphql -f owner="$owner" -f name="$repo" -f query='
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) { projectsV2(first: 100) { nodes { url } } }
  }' --jq '.data.repository.projectsV2.nodes[].url' | grep -cxF "$project_url" || true)
if [[ "$linked" -eq 0 ]]; then
  gh project link "$project_number" --owner "$owner" --repo "$full"
else
  info "linked to repo"
fi

# ---------------------------------------------------------------------------
step "Credentials ($auth${app_slug:+: $app_slug})"
has_secret() { gh secret list --repo "$full" --json name --jq '.[].name' | grep -qx "$1"; }

if [[ "$auth" == "pat" ]]; then
  if has_secret AUTOMATION_TOKEN; then
    info "AUTOMATION_TOKEN set"
  else
    info "Paste a classic PAT with 'repo' + 'project' scopes."
    gh secret set AUTOMATION_TOKEN --repo "$full"
  fi

else
  # Reuse an existing App.
  settings_url="https://github.com/organizations/$owner/settings/apps/$app_slug"
  app_json=$(gh api "apps/$app_slug" 2>/dev/null) ||
    die "can't read App '$app_slug'. Check the slug, and that you're an owner of $owner."
  [[ "$(jq -r '.owner.login' <<<"$app_json")" == "$owner" ]] || die "App '$app_slug' isn't owned by $owner"
  app_id=$(jq -r '.id' <<<"$app_json")

  missing=$(jq -r '.permissions as $p
    | {contents: "write", issues: "write", pull_requests: "write", organization_projects: "write"}
    | to_entries[] | ($p[.key] // "none") as $have
    | select($have != "write" and $have != "admin")
    | "\(.key) (has: \($have))"' <<<"$app_json")
  if [[ -n "$missing" ]]; then
    echo "    $app_slug is missing read/write permissions the workflows need:"
    while read -r line; do echo "      - $line"; done <<<"$missing"
    echo "    Add them at $settings_url/permissions"
    echo "    (then approve the change on its installation), and re-run this script."
    exit 1
  fi
  info "permissions OK (App ID $app_id)"

  # The workflows read the App's ID and key from these org-level secrets.
  org_secrets=$(gh api "repos/$full/actions/organization-secrets" --paginate --jq '.secrets[].name' 2>/dev/null || true)
  for name in DS_RELEASE_BOT_ID DS_RELEASE_BOT_PRIVATE_KEY; do
    if grep -qx "$name" <<<"$org_secrets"; then
      info "org secret $name visible to $repo"
    else
      echo "    Org secret $name isn't available to $repo. Under its 'Repository access', allow $repo:"
      echo "      https://github.com/organizations/$owner/settings/secrets/actions/$name"
      echo "    (A public repo can't see secrets limited to private repositories.)"
      open_url "https://github.com/organizations/$owner/settings/secrets/actions/$name"
      read -rp "    Press Enter once $repo has access..."
    fi
  done

  # Is the App installed with access to this repo?
  install=$(gh api "orgs/$owner/installations" --paginate \
    --jq ".installations[] | select(.app_slug == \"$app_slug\") | \"\(.id) \(.repository_selection)\"" \
    2>/dev/null || true)
  install_id="${install%% *}" selection="${install##* }"
  if [[ "$selection" == "all" ]]; then
    info "installed on all repositories"
  else
    if [[ -n "$install_id" ]]; then
      url="https://github.com/organizations/$owner/settings/installations/$install_id"
      echo "    $app_slug is installed on selected repos only; make sure $repo is one of them:"
    else
      url="https://github.com/apps/$app_slug/installations/new"
      echo "    Couldn't confirm $app_slug's installation; check that it includes $repo:"
    fi
    echo "      $url"
    open_url "$url"
    read -rp "    Press Enter once $repo is included..."
  fi
fi

# ---------------------------------------------------------------------------
step "Pushing main"
git push -u origin main

step "Baseline release v0.1.0"
# release-commenter ignores a repo's first release, so the baseline must exist
# before the demo's first real release (v0.2.0).
if gh release view v0.1.0 --repo "$full" >/dev/null 2>&1; then
  info "exists"
else
  gh release create v0.1.0 --repo "$full" --target main --title "v0.1.0" --notes "Baseline release."
fi

# ---------------------------------------------------------------------------
step "Board columns"
statuses=$(gh project field-list "$project_number" --owner "$owner" --format json |
  jq -r '.fields[] | select(.name == "Status") | [.options[].name] | join(", ")')
info "Status options: $statuses"
todo=()
grep -qi 'released' <<<"$statuses" || todo+=("Open $project_url → Settings → Status field: add an option named \"Released\".")
todo+=("If you haven't yet: switch the board's view to Board layout (View → Layout → Board).")

echo
echo "Almost done. In the browser (the API can't do these):"
for t in "${todo[@]}"; do echo "  - $t"; done
echo
echo "Then run:  scripts/demo.sh \"Add a greeting\""
