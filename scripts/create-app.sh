#!/usr/bin/env bash
# Create an org-owned GitHub App for the release-tracking workflows using the
# GitHub App Manifest flow, then store its ID and private key in the repo.
#
# Two browser clicks are unavoidable (GitHub has no API for them):
#   1. "Create GitHub App" on the pre-filled page this script opens
#   2. "Install" on the repo(s) the App should act on
#
# Usage: scripts/create-app.sh <org> <repo> [app-name]
# Needs: gh (logged in as an org owner or GitHub App manager), jq, python3
set -euo pipefail

org="${1:?usage: scripts/create-app.sh <org> <repo> [app-name]}"
repo="${2:?usage: scripts/create-app.sh <org> <repo> [app-name]}"
name="${3:-$repo-automation}"
port="${PORT:-8765}"
state=$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')

manifest=$(jq -n \
  --arg name "$name" \
  --arg url "https://github.com/$org/$repo" \
  --arg redirect "http://localhost:$port/" '
  {
    name: $name,
    url: $url,
    redirect_url: $redirect,
    public: false,
    hook_attributes: { url: $url, active: false },
    default_events: [],
    default_permissions: {
      contents: "write",
      issues: "write",
      pull_requests: "write",
      organization_projects: "write",
      metadata: "read"
    }
  }')

# An auto-submitting form, because GitHub only accepts the manifest via POST.
page=$(mktemp -t create-app-XXXXXX).html
cat > "$page" <<EOF
<!doctype html>
<form id="f" method="post" action="https://github.com/organizations/$org/settings/apps/new?state=$state">
  <input type="hidden" name="manifest" value="$(jq -rn --arg m "$manifest" '$m | @html')">
  <noscript><button>Continue to GitHub</button></noscript>
</form>
<script>document.getElementById("f").submit()</script>
EOF

open_url() { (command -v open >/dev/null && open "$1") || (command -v xdg-open >/dev/null && xdg-open "$1") || echo "Open this in your browser: $1"; }

echo "==> Opening GitHub. Review the App and click 'Create GitHub App'."
open_url "$page"

echo "==> Waiting for GitHub to redirect back to http://localhost:$port/ ..."
code=$(STATE="$state" PORT="$port" python3 - <<'EOF'
import http.server, os, sys, urllib.parse

expected = os.environ["STATE"]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code, state = q.get("code", [""])[0], q.get("state", [""])[0]
        ok = bool(code) and state == expected
        self.send_response(200 if ok else 400)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"App created. You can close this tab." if ok else b"Unexpected request.")
        if ok:
            self.server.code = code
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", int(os.environ["PORT"])), Handler)
server.code = None
while not server.code:
    server.handle_request()
print(server.code)
EOF
)
rm -f "$page"

echo "==> Exchanging the code for the App's credentials"
app=$(gh api -X POST "/app-manifests/$code/conversions")
app_id=$(jq -r '.id' <<<"$app")
slug=$(jq -r '.slug' <<<"$app")

gh variable set APP_ID --repo "$org/$repo" --body "$app_id"
jq -r '.pem' <<<"$app" | gh secret set APP_PRIVATE_KEY --repo "$org/$repo"
unset app

echo "    Created $slug (ID $app_id); stored APP_ID and APP_PRIVATE_KEY in $org/$repo"

echo "==> Opening the install page. Choose 'Only select repositories' and pick $repo."
open_url "https://github.com/apps/$slug/installations/new"
