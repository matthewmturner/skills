---
name: pr-review
description: |
  Review GitHub pull requests for correctness, feature/config bloat, and
  performance. Outputs a concise summary of breaking changes and risks.
  Recommends splitting oversized PRs. Use when asked to review a PR, branch,
  or diff.
---

# PR Review

Review a pull request, branch, or diff. Use `gh` CLI to fetch PR details and diffs. Do not rely on web fetching for PR content.

## Workflow

0. **Resolve the PR target.** If the user provides a PR number or URL, use it directly. If not, resolve it from the current branch:
   - Run `git branch --show-current` to get the branch name.
   - Run `gh pr list --head <branch> --json number` to find the associated PR.
   - If multiple PRs or no PR is found, ask the user to clarify.
   - Use the resolved PR number for all subsequent steps.

1. **Fetch the PR.** Run `gh pr view <number-or-url> --json title,body,files,state,mergeable,reviewDecision,additions,deletions,changedFiles` to get metadata, then `gh pr diff <number-or-url>` for the full diff. Read the PR description (body) carefully.
2. **Verify description vs. changes.** Compare what the PR description claims against the actual diff:
   - Every feature/fix mentioned in the description must have corresponding code changes.
   - Every non-trivial code change (new files, new public APIs, removed logic) must be mentioned or implied in the description.
   - Flag missing details: e.g., the body says "fix auth bug" but the diff also adds a new config flag and changes the database schema.
   - Flag misleading claims: e.g., the body describes a small refactor but the diff adds an entirely new module.
3. **Inspect key files.** For non-trivial changes, read the full source of affected files to understand context the diff alone hides.
4. **Evaluate against criteria** (see below).
5. **Output the summary** (see format below).

## Criteria

### Correctness

- Logic errors, off-by-one, null/undefined paths, race conditions, error handling gaps
- Type safety: missing type constraints, `any` abuse, broken generics
- Regression risk: does the change break existing callers, public APIs, or documented contracts?
- Test coverage: are new code paths tested? Are existing tests still relevant?

### Description Alignment

- The PR description must accurately reflect all changes in the diff.
- If the description omits significant changes (new endpoints, schema changes, dependency upgrades, breaking API changes), flag them.
- If the description claims changes that are not present in the diff, flag the mismatch.
- If the description is vague ("misc fixes", "updates") while the diff is substantial, call it out.

### Feature and Config Bloat

- **Scope creep:** does the PR mix unrelated changes, or add features beyond the stated goal?
- **Unnecessary abstractions:** premature generalization, layers with no current consumer
- **Config sprawl:** new flags, settings, or knobs that solve a single case instead of simplifying the default
- **Dead code:** imports, branches, or parameters that exist only for a hypothetical future use
- **One more rule of thumb:** if a change could be a separate PR without coordination cost, flag it

### Performance

- Complexity changes: new O(n²) patterns, unnecessary allocations, synchronous blocking in async paths
- Network and I/O: extra roundtrips, missing batching, unbounded reads, missing caching
- Startup and memory: eager initialization, unbounded growth, missing cleanup

## PR Size Gate

Before deep review, assess scope. The goal is reviewability, not hitting a number. Use judgment:

- **Around 1500 changed lines** is a rough guideline, not a hard cutoff. A 1200-line PR touching core architecture may need splitting; a 1800-line PR of straightforward renames and formatting does not.
- **Touches more than 3 subsystems or domains** without a single unifying change: recommend splitting
- **Mixes refactoring with new features or bug fixes:** recommend splitting
- **Has no clear single-purpose description:** recommend splitting
- **Complexity matters more than line count.** If the logic is dense, interdependent, or hard to follow, recommend splitting even under the guideline. Conversely, large but mechanical changes (migrations, renames, formatting) are fine above it.

When a PR should be split, say so upfront. Suggest concrete split boundaries (e.g., "extract the logging refactor into its own PR") rather than just saying "this is too big."

## Output Format

Produce a short summary. No preamble, no filler. Use this structure:

```
## PR Review

**Scope:** <one-line summary of what the PR does>

### Breaking Changes
- <list breaking changes, or "None">

### Risks
- <list risks with severity: HIGH / MEDIUM / LOW>

### Findings
- <correctness issues, with file and line references>
- <bloat or scope concerns>
- <performance concerns>

### Description Alignment
- <describe mismatches between the PR body and the actual diff, or "PR description accurately reflects changes">

### Split Recommendation
- <recommend splitting with concrete boundaries, or "Not needed — PR is appropriately scoped">
```

Keep findings to the top 5–8 items. If the PR is clean, say so explicitly. Omit entire sections that have no items rather than writing "None" for everything.
