# Release tracking demo

Shows how a GitHub Projects board can tell you, at a glance, which issues are
**merged but not yet released**.

```mermaid
flowchart LR
  A[Issue opened] -->|project-status.yml| T[Todo]
  B[PR opened<br/>'Closes #N'] -->|project-status.yml| P[In Progress]
  C[PR merged → issue closed] -->|project-status.yml| D[Done]
  C -->|release-please.yml| R[Release PR updated]
  R -->|merge Release PR| V[GitHub Release vX.Y.Z]
  V -->|release-commenter.yml| L[Issue labeled<br/>'released in vX.Y.Z']
  L -->|project-status.yml| X[Released]
```

The **Done** column is the list of merged-but-unreleased work. The open
**Release PR** shows the same thing from the code side, with a draft changelog.

## What's in here

| File | Role |
| --- | --- |
| `.github/workflows/release-please.yml` | Keeps a Release PR open; merging it tags and publishes a release |
| `.github/workflows/release-commenter.yml` | On release, labels each shipped issue `released in vX.Y.Z` |
| `.github/workflows/project-status.yml` | Moves cards: Todo → In Progress → Done → Released |
| `scripts/set-status.sh` | Sets an issue's Status on the board (user or org projects) |
| `scripts/setup.sh` | Re-runnable bootstrap with the `gh` CLI |
| `scripts/create-app.sh` | Creates the GitHub App (org owners only) |
| `scripts/demo.sh` | Walks one issue through the lifecycle |
| `release-please-config.json`, `.release-please-manifest.json`, `version.txt`, `CHANGELOG.md` | Release Please state (`simple` release type) |

## Setup

You need the [GitHub CLI](https://cli.github.com), `jq`, and (for App auth) `python3`.

```bash
gh auth refresh -s project
scripts/setup.sh <owner> [--repo NAME] [--public] [--auth app|pat]
```

The script is safe to re-run: it reuses an existing repo, board, and credentials.

**Credentials.** The workflows can't use `GITHUB_TOKEN` (it can't touch
Projects, and events it creates don't trigger other workflows), so pick one:

- `--auth app` (default for organizations): `scripts/create-app.sh` creates a
  GitHub App from a manifest, stores `APP_ID` and `APP_PRIVATE_KEY` in the repo,
  and opens its install page. Requires an **organization**: GitHub Apps can't
  access Projects owned by a personal account.
- `--auth pat` (default for personal accounts): paste a classic PAT with `repo`
  and `project` scopes; stored as `AUTOMATION_TOKEN`.

Every workflow mints an App token when `APP_ID` is set and falls back to
`AUTOMATION_TOKEN` otherwise.

**Finish in the browser** (the API can't do these):
- Project settings → **Status** field → add an option named `Released`.
- Switch the view to **Board** layout.

## Run the demo

```bash
scripts/demo.sh "Add a greeting"          # feat → minor bump
scripts/demo.sh "Fix the greeting" fix     # fix  → patch bump, same release
gh pr merge <release-pr-number> --squash   # ship it
```

Watch the board after each pause. After the Release PR merges, give Actions
a minute: release → label → status is three workflow runs in a row.

## Why it's wired this way (gotchas)

- **Never `GITHUB_TOKEN`.** Events created with the default `GITHUB_TOKEN`
  don't trigger other workflows. If Release Please used it, the release
  wouldn't trigger `release-commenter.yml`. If the commenter used it, the label
  wouldn't trigger the `released` job.
- **Conventional commits matter.** Release Please only cuts a release for
  `feat:`, `fix:` and similar commit types. The repo is set to squash-merge
  with the PR title as the commit title, so the **PR title** must be
  conventional (`feat: …`). A `chore:`-only main produces no Release PR.
  Consider adding a PR-title lint check for real repos.
- **`Closes #N` goes in the PR description**, not a comment.
- **Baseline release.** `github-release-commenter` intentionally skips a
  repo's first release, which is why setup creates `v0.1.0` up front.
- **Single-package only.** The commenter compares against the previous
  release, which doesn't work well with Release Please monorepo per-component
  tags or out-of-order patch releases.
- **Forked PRs** don't get secrets, so the In Progress move won't run for
  them. Fine for a demo; for public repos consider a GitHub App and
  `pull_request_target` with care.
- **Built-in project workflows.** The project's own "Item closed" workflow also
  sets Done, which is harmless. Turn it off if you want this repo to be the
  only thing moving cards.
- **Pin actions.** Third-party actions are referenced by tag for readability;
  pin them to commit SHAs for production use.
