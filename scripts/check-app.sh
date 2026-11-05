#!/usr/bin/env bash
# Read-only check that an existing org GitHub App is ready for this demo:
#   1. Permissions: contents, issues, pull_requests, organization_projects = write
#   2. Installation: installed on the org, covering the repo
#   3. Credentials: org secrets DS_RELEASE_BOT_ID and DS_RELEASE_BOT_PRIVATE_KEY
#      are available to the repo; PROJECT_URL variable is set
#
# Usage: scripts/check-app.sh <org> <app-slug> <repo> [--key FILE]
#
#   --key FILE  a copy of the App's private key (.pem). Optional; lets the script sign in
#               as the App to confirm the key is valid and the installation
#               really covers <repo>.
#
# Example: scripts/check-app.sh developmentseed ds-release-bot release-tracking-demo
set -uo pipefail

org="" slug="" repo="" key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) key="${2:?--key needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [[ -z "$org" ]]; then org="$1"; elif [[ -z "$slug" ]]; then slug="$1"
       elif [[ -z "$repo" ]]; then repo="$1"; else echo "Unexpected argument: $1"; exit 2; fi; shift ;;
  esac
done
[[ -n "$repo" ]] || { echo "Usage: scripts/check-app.sh <org> <app-slug> <repo> [--key FILE]"; exit 2; }
full="$org/$repo"
key="${key/#\~/$HOME}"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
warn() { echo "  ? $*"; }

# ---------------------------------------------------------------------------
echo "1. Permissions of $slug"
if ! app_json=$(gh api "apps/$slug" 2>/dev/null); then
  fail "can't read App '$slug' (wrong slug, or you're not an owner of $org)"
  echo; echo "Stopping: nothing else can be checked without the App."; exit 1
fi
app_id=$(jq -r '.id' <<<"$app_json")
[[ "$(jq -r '.owner.login' <<<"$app_json")" == "$org" ]] || fail "owned by $(jq -r '.owner.login' <<<"$app_json"), not $org"
while IFS=$'\t' read -r perm have; do
  if [[ "$have" == "write" || "$have" == "admin" ]]; then
    pass "$perm: $have"
  else
    fail "$perm: $have (needs write) → https://github.com/organizations/$org/settings/apps/$slug/permissions"
  fi
done < <(jq -r '.permissions as $p
  | ["contents", "issues", "pull_requests", "organization_projects"][]
  | [., ($p[.] // "none")] | @tsv' <<<"$app_json")

# ---------------------------------------------------------------------------
echo "2. Installation on $org"
if install=$(gh api "orgs/$org/installations" --paginate \
    --jq ".installations[] | select(.app_slug == \"$slug\") | \"\(.id) \(.repository_selection) \(.suspended_at // \"\")\"" 2>/dev/null); then
  read -r install_id selection suspended <<<"$install"
  if [[ -z "$install_id" ]]; then
    fail "not installed → https://github.com/apps/$slug/installations/new"
  elif [[ -n "$suspended" ]]; then
    fail "installation is suspended → https://github.com/organizations/$org/settings/installations/$install_id"
  elif [[ "$selection" == "all" ]]; then
    pass "installed on all repositories (covers $repo)"
  else
    warn "installed on selected repositories; confirm $repo is included:"
    echo "      https://github.com/organizations/$org/settings/installations/$install_id"
    [[ -n "$key" ]] && echo "      (checked below with --key)"
  fi
else
  warn "couldn't list org installations (your gh login may lack admin:org scope)"
  [[ -z "$key" ]] && echo "      Re-run with --key FILE to check via the App itself."
fi

# ---------------------------------------------------------------------------
echo "3. Credentials in $full"
if org_secrets=$(gh api "repos/$full/actions/organization-secrets" --paginate --jq '.secrets[].name' 2>/dev/null); then
  for name in DS_RELEASE_BOT_ID DS_RELEASE_BOT_PRIVATE_KEY; do
    if grep -qx "$name" <<<"$org_secrets"; then
      pass "org secret $name is available to $repo (presence only; values can't be read)"
    else
      fail "org secret $name not available to $repo → https://github.com/organizations/$org/settings/secrets/actions/$name"
    fi
  done
else
  warn "couldn't list org secrets available to $full (needs admin on the repo)"
fi
project_url=$(gh variable get PROJECT_URL --repo "$full" 2>/dev/null || true)
if [[ -n "$project_url" ]]; then pass "PROJECT_URL = $project_url"; else fail "PROJECT_URL variable not set"; fi

# ---------------------------------------------------------------------------
if [[ -n "$key" ]]; then
  echo "4. Signing in as $slug with $key"
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  if [[ ! -f "$key" ]]; then
    fail "key file not found: $key"
  else
    now=$(date +%s)
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64url)
    if ! sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" 2>/dev/null | b64url) || [[ -z "$sig" ]]; then
      fail "couldn't sign with $key (not a valid RSA private key?)"
    else
      jwt="$header.$payload.$sig"
      api() { curl -s -o /tmp/check-app.$$ -w '%{http_code}' -H "Authorization: Bearer $jwt" \
                -H "Accept: application/vnd.github+json" "https://api.github.com$1"; }
      if [[ "$(api /app)" == "200" ]]; then
        pass "key is valid for $slug"
        code=$(api "/repos/$full/installation")
        if [[ "$code" == "200" ]]; then
          pass "installation covers $full"
        else
          fail "installation does NOT cover $full (HTTP $code)"
        fi
      else
        fail "key rejected by GitHub (wrong App, or the key was revoked)"
      fi
      rm -f /tmp/check-app.$$
    fi
  fi
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed."
fi
exit $(( failures > 0 ))
