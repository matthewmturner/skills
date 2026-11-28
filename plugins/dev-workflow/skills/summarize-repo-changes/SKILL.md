---
name: summarize-repo-changes
description: Analyze commits to a repository's default branch (main or master) within a given time interval and produce a structured summary of changes. Focuses on new or deprecated features, API changes, configuration changes, and Kubernetes/Helm resource changes. Use when the user wants to understand what changed in a repo over a recent period.
---

# Summarize Repo Changes

Analyze all commits on a repository's default branch within a specified time interval and produce a structured markdown summary of meaningful changes.

## Prerequisites

- `git` installed and available
- `gh` CLI installed and authenticated (`gh auth status`) — required for GitHub repos
- Access to the target repository (clone permissions for GitHub repos, filesystem access for local repos)

## Usage

The user provides:

| Parameter | Required | Description |
|-----------|----------|-------------|
| `repo` | Yes | `owner/repo` for GitHub repos, or a local filesystem path to a git repo |
| `interval` | Yes | Time window string (e.g., "8 hours", "1 week", "3 days", "since Monday") |
| `branch` | No | Override the default branch detection (e.g., "develop", "trunk") |

## Workflow

### Step 1: Resolve Repository

Determine whether the input is a GitHub repo or a local path.

**GitHub repo** (matches `owner/repo` pattern):

```bash
# Verify access and get repo metadata
gh repo view owner/repo --json defaultBranchRef,cloneUrl,description

# Clone to a temp directory if not already available
REPO_DIR=$(mktemp -d)
git clone --depth 50 --branch BRANCH CLONE_URL "$REPO_DIR"
cd "$REPO_DIR"
# Fetch full history for the branch to analyze all commits
git fetch origin BRANCH --depth=1000 2>/dev/null || true
```

**Local repo** (filesystem path):

```bash
# Validate it is a git repo
git -C /path/to/repo rev-parse --git-dir
cd /path/to/repo
```

If `gh repo view` fails with a 404 or permission error, report the error and ask the user to authenticate or provide a local path.

### Step 2: Determine Default Branch

```bash
# GitHub: use the default branch from gh repo view
# Extract defaultBranchRef.name from JSON output

# Local: try upstream HEAD, then fall back to main, then master
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'
git rev-parse --verify main  >/dev/null 2>&1 && echo "main" || echo "master"
```

Allow a user-provided `branch` parameter to override detection.

### Step 3: Compute Time Range

Map the natural language interval to a `date -d` expression:

| Interval Phrase | `date -d` Expression |
|-----------------|---------------------|
| "8 hours" / "8h" | `8 hours ago` |
| "1 day" / "24 hours" | `1 day ago` |
| "3 days" / "last 3 days" | `3 days ago` |
| "1 week" / "7 days" | `7 days ago` |
| "2 weeks" | `14 days ago` |
| "1 month" / "30 days" | `30 days ago` |
| "since Monday" | `this Monday` |
| "since yesterday" | `yesterday` |

```bash
# Compute the since timestamp
SINCE=$(date -d "EXPRESSION" --iso-8601=seconds)
NOW=$(date --iso-8601=seconds)
```

If the interval phrase cannot be mapped, ask the user to rephrase.

### Step 4: List Commits in Interval

```bash
# Get commit list: hash, date, subject
git log --oneline --since="$SINCE" --until="$NOW" --format="%H %ai %s" BRANCH
```

Capture all commit hashes, dates, and subject lines for analysis.

**High-volume handling:** If there are more than 50 commits, filter out likely trivial changes by excluding subjects matching:

```bash
# Patterns indicating trivial changes
grep -iEv '^\w+ +(typo|format|whitespace|lint|chore|bump dep|update lock|regen|revert of revert|merge branch)' 
```

Still count all commits in the report but focus detailed analysis on the remaining set.

### Step 5: Fetch Commit Details

For each meaningful commit, get the file-level change summary:

```bash
git show --stat --format="%H %an %ai %s" COMMIT
```

For the top ~20 most significant commits (judged by title keywords, number of files changed, or file paths touched), get the full diff:

```bash
git diff COMMIT~1 COMMIT -- . ':(exclude)node_modules/' ':(exclude)vendor/' ':(exclude)dist/' ':(exclude)build/'
```

For GitHub repos with merge commits, enrich with PR details:

```bash
gh pr view PR_NUMBER --repo owner/repo --json title,body,labels,mergedAt,reviewers,files
```

Extract the PR body and labels for richer context (breaking-change labels, feature labels, etc.).

### Step 6: Detect Kubernetes / Helm Usage

Check if the repository contains Kubernetes manifests or Helm charts:

```bash
# Helm detection
ls charts/ Chart.yaml values.yaml 2>/dev/null
find . -name "Chart.yaml" -o -name "values.yaml" -o -name "values-*.yaml" 2>/dev/null | head -20

# Kubernetes manifest detection (directories)
ls k8s/ deploy/ deployments/ manifests/ overlays/ base/ 2>/dev/null

# Kubernetes manifest detection (file content)
grep -rl "^apiVersion:.*" --include="*.yaml" --include="*.yml" . 2>/dev/null | \
  xargs grep -l "^kind:.*" 2>/dev/null | head -30
```

If any patterns match, set a flag to include a dedicated **Kubernetes / Helm Changes** section in the summary.

### Step 7: Categorize Changes

Apply these heuristics to classify each commit:

**New Features**
- Commit prefixes: `feat:`, `feat(`
- Title keywords: add, new, introduce, implement, create
- New files added (check `git diff --diff-filter=A`)
- New directories or modules created

**Deprecated / Removed Features**
- Title keywords: deprecat, remove, drop, retire, eliminate, phase out
- Files deleted (check `git diff --diff-filter=D`)
- Removed exports, modules, or public APIs

**API Changes**
- Files changed: routes, handlers, controllers, `api/`, `grpc/`, `protobuf/`, `proto/`, `swagger*`, `openapi*`, `*.proto`
- Title keywords: API, endpoint, endpoint, breaking, BC break, backward incompatibl
- Body/footer markers: `BREAKING CHANGE:`, `BREAKING-CHANGE:`

**Configuration Changes**
- Files changed: `*.env*`, `config.*`, `settings.*`, `.env.*`, `application.*.yml`, `*.conf`, `Dockerfile`, `docker-compose*`, `*.toml`, `*.ini`
- New or changed `ENV` / `ARG` instructions in Dockerfiles
- New environment variable references in code (search diff for `process.env.`, `os.environ`, `os.Getenv`, `os.Getenv`, `config.`, `cfg.`)

**Kubernetes / Helm Changes** (only if K8s/Helm detected in Step 6)
- Files changed: `*.yaml` with `apiVersion:`/`kind:`, `Chart.yaml`, `values.yaml`, `values-*.yaml`, `*.tpl` in `templates/`
- Chart version bumps (compare old/new version in `Chart.yaml`)
- Changes to: Deployments, Services, Ingress, CRDs, RBAC (ClusterRole/Role/Binding), ConfigMaps, Secrets, HPA, NetworkPolicies
- Template logic changes in Helm `*.tpl` files
- Breaking manifest changes (e.g., removed resources, changed API versions, renamed selectors)

**Conventional Commits Shortcuts**
If the repo follows [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` → New Features
- `fix:` → Bug fixes (include in notable commits)
- `BREAKING CHANGE:` → call out prominently under API Changes
- `chore:`, `docs:`, `style:`, `test:` → typically skip unless file paths indicate config or infra changes
- `perf:`, `refactor:` → include if they affect public interfaces

### Step 8: Generate Summary

Produce the following markdown output:

```markdown
# Repository Changes: REPO

**Period:** SINCE → NOW (N commits analyzed)
**Branch:** BRANCH

## Summary

1-2 sentence high-level overview of what happened in this period.

## New Features

- Description of each new feature, linked to the commit or PR
- Note the scope and files affected

## Deprecated / Removed

- Description of deprecations or removals
- Note any migration guidance mentioned in commits

## API Changes

- Breaking changes (call out with **BREAKING** prefix)
- New endpoints or API surfaces
- Parameter or behavior changes

## Configuration Changes

- New or changed environment variables
- Config file changes and their impact
- Docker/container configuration changes

## Kubernetes / Helm Changes

_(This section only appears if K8s/Helm resources were detected.)_

- Chart version bumps (old → new)
- Manifest changes by resource type (Deployments, Services, CRDs, etc.)
- values.yaml default value changes
- Breaking manifest changes (**BREAKING** callout)
- Ingress or networking changes

## Notable Commits

| Commit | Author | Date | Message | Files |
|--------|--------|------|---------|-------|
| `abc1234` | @author | 2026-05-27 | feat: add new auth provider | 5 |
| `def5678` | @author | 2026-05-27 | fix: resolve race condition | 2 |
```

## Edge Cases

- **Private repos / no auth:** If `gh auth status` fails or `gh repo view` returns 404, tell the user to authenticate or provide a local path to the repo.
- **No commits in interval:** Output: "No commits found on BRANCH between SINCE and NOW."
- **Very large diffs (100+ commits):** Summarize at stat level for all commits; sample full diffs from at most 20 of the most significant commits. Note the sampling in the summary.
- **Local repos with no remote:** Skip all `gh` commands; use `git` only for analysis.
- **Merge commits:** Include the merge commit message (which typically contains the PR title). When `gh` is available, also fetch the PR body for context.
- **Interval parse failure:** Ask the user to rephrase the interval.
- **Shallow clone:** If `git log --since` fails due to shallow history, re-fetch with greater depth or do `git fetch --unshallow`.

## Tips

- For repos with a `CHANGELOG.md` or `CHANGELOG.md`, check if recent entries align with the interval and reference them as additional context:

  ```bash
  # Check if changelog exists and has recent entries
  head -100 CHANGELOG.md 2>/dev/null
  ```

- Cross-reference merge commits with `gh pr view` to pick up labels like `breaking-change`, `enhancement`, `bug` for accurate categorization.
- When `Chart.yaml` version changes, always call out the old version and new version explicitly.
- For Helm template changes (`*.tpl` files), note if conditional logic (`{{ if }}`, `{{ range }}`) changed since this can silently alter deployed resources.
- If the repo uses `kustomize` (look for `kustomization.yaml`), include kustomize overlay/base changes in the Kubernetes section.
- Keep the summary scannable — use bullet points and bold callouts for breaking changes.
