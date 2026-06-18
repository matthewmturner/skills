---
name: search-repos
description: Search GitHub repositories for issues and pull requests matching user-provided keywords using the GitHub CLI. Summarize relevant findings and highlight recent activity. Use when the user wants to search across repos for specific topics, bugs, features, or discussions.
---

# Search Repos

Search GitHub repository issues and pull requests using the `gh` CLI, summarize relevant results, and highlight recent activity.

## Prerequisites

- `gh` CLI installed and authenticated (`gh auth status`)
- Access to the target repositories

## Usage

The user provides:
1. **One or more repositories** in `owner/repo` format (e.g., `owner/repo-a`, `owner/repo-b`)
2. **A search query** — keywords, phrases, or topics to match

## Workflow

### Step 1: Search Issues

For each repository, run:

```bash
gh search issues "QUERY" --repo owner/repo --limit 30 --json title,body,author,comments,url,updatedAt,createdAt,stateReason,reactions
```

- Use the user's query as-is. For multi-word phrases, quote the entire phrase.
- If the query is short and common, add qualifiers like `type:issue` to narrow results.
- Adjust `--limit` up to 100 if initial results are sparse.

### Step 2: Search Pull Requests

For each repository, run:

```bash
gh search prs "QUERY" --repo owner/repo --limit 30 --json title,body,author,comments,url,updatedAt,createdAt,mergedAt,mergedBy,reviewers,reactions
```

### Step 3: Fetch Details for Top Matches

From the search results, identify the top 5-10 most relevant items per repo (by title/body match and recency). For each, fetch the full detail to include comment context:

```bash
# For issues
gh issue view ISSUE_NUMBER --repo owner/repo --json title,body,comments,updatedAt,author,reactions

# For PRs
gh pr view PR_NUMBER --repo owner/repo --json title,body,comments,updatedAt,author,reactions,mergedAt,reviewers
```

Extract comment snippets that add context (e.g., resolution, discussion of alternatives).

### Step 4: Determine Recency

For each result, compute recency from `updatedAt`:

- **Active** — updated within the last 7 days
- **Recent** — updated within the last 30 days
- **Stale** — updated older than 30 days

Use `date` or relative date parsing to determine this. A quick shell check:

```bash
# Returns seconds ago (0 means today, negative means future)
echo $(( $(date +%s) - $(date -d "UPDATE_AT_TIMESTAMP" +%s) ))
```

Or compare with these thresholds:
- 7 days = 604800 seconds
- 30 days = 2592000 seconds

### Step 5: Summarize

Produce a structured summary grouped by repository. For each relevant issue or PR, include:

- **Always include hyperlinks** to each issue and PR using markdown link syntax `[Title](url)` so the user can navigate directly to the item.

```markdown
## owner/repo

### Issues

#### [Title](url)
- **Status:** Open / Closed / Merged
- **Recency:** Active (updated 2 days ago) / Recent (updated 3 weeks ago) / Stale
- **Summary:** One to two sentences capturing the core ask, bug, or discussion.
- **Activity:** N comments, N reactions
- **Key context:** Brief note from comments if relevant (e.g., "resolved by #123", "waiting on maintainer response")

### Pull Requests

#### [Title](url)
- **Status:** Open / Merged / Closed
- **Recency:** Active (updated 1 day ago) / Recent / Stale
- **Summary:** What the PR changes and its scope.
- **Activity:** N comments, N reactions, merged by @user
- **Key context:** Review feedback, merge status, linked issues
```

### Recency Highlighting

Use bold callouts for active items at the top of each repo section:

```markdown
> **Active:** 2 items updated in the last 7 days
```

If a repo has no active or recent items, note it as stale.

## Tips

- If the user does not specify repos but mentions a known organization, ask which repos to search.
- If a repo is private, `gh` will return an error — report this to the user.
- For large codebases with thousands of issues, add `state:open` to the query unless the user asks for closed items too.
- When the query is a single word, wrap it in quotes or add `in:title` to avoid noise: `"keyword" in:title`.
- Limit total summaries to the top 15-20 most relevant items across all repos unless the user asks for more.
