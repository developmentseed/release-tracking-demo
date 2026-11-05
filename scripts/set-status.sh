#!/usr/bin/env bash
# shellcheck disable=SC2016  # GraphQL $variables are intentionally literal
# Set the "Status" field of an issue's item on the project at $PROJECT_URL.
# Works for both user- and organization-owned projects.
#
# Usage: set-status.sh <issue-node-id> <status option name>
# Env:   GH_TOKEN (token with project + repo access), PROJECT_URL
set -euo pipefail

content_id="${1:?usage: set-status.sh <issue-node-id> <status>}"
status="${2:?usage: set-status.sh <issue-node-id> <status>}"
: "${PROJECT_URL:?PROJECT_URL must be set (repo variable)}"
project_url="${PROJECT_URL%/}"

item_json=$(gh api graphql -f id="$content_id" -f query='
  query($id: ID!) {
    node(id: $id) {
      ... on Issue {
        number
        projectItems(first: 50) {
          nodes {
            id
            project {
              id
              url
              field(name: "Status") {
                ... on ProjectV2SingleSelectField { id options { id name } }
              }
            }
          }
        }
      }
    }
  }')

item=$(jq -c --arg url "$project_url" \
  '.data.node.projectItems.nodes[] | select(.project.url == $url)' <<<"$item_json" | head -n1)

if [[ -z "$item" ]]; then
  echo "::warning::Issue is not on project $project_url; skipping."
  exit 0
fi

project_id=$(jq -r '.project.id' <<<"$item")
item_id=$(jq -r '.id' <<<"$item")
field_id=$(jq -r '.project.field.id' <<<"$item")
option_id=$(jq -r --arg s "$status" \
  '.project.field.options[] | select((.name | ascii_downcase) == ($s | ascii_downcase)) | .id' <<<"$item")

if [[ -z "$option_id" ]]; then
  echo "::error::Status option '$status' not found. Available: $(jq -r '[.project.field.options[].name] | join(", ")' <<<"$item")"
  exit 1
fi

gh api graphql --silent \
  -f project="$project_id" -f item="$item_id" -f field="$field_id" -f option="$option_id" \
  -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $project, itemId: $item, fieldId: $field,
        value: { singleSelectOptionId: $option }
      }) { projectV2Item { id } }
    }'

echo "Issue #$(jq -r '.data.node.number' <<<"$item_json") -> $status"
