---
name: pr-review
description: |
  Review GitHub pull requests for correctness, feature/config bloat,
  performance, and leaked secrets or local environment information.
  Outputs a concise summary of breaking changes and risks.
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
4. **Independently verify the changes** when practical (see "Independent Verification" below).
5. **Evaluate against criteria** (see below).
6. **Output the summary** (see format below).

## Independent Verification

Don't take the PR's word for it — tests passing is evidence, not proof. Tests written in the same PR often encode the same misunderstanding as the code. When practical, verify the claimed behavior yourself:

- **Check out the PR branch** (`gh pr checkout <number>`) and exercise the changed behavior directly: run the CLI command, call the function in a REPL or scratch script, hit the endpoint, reproduce the bug the PR claims to fix and confirm it's gone.
- **Verify the bug existed before.** For bug fixes, confirm the broken behavior on the base branch first — otherwise you can't tell whether the fix does anything.
- **Probe edge cases the tests skip:** empty inputs, boundary values, error paths, the states flagged in the criteria below.
- **Read test assertions skeptically:** do they assert the actual desired outcome, or just that the code ran? Watch for tests that mock away the very thing the PR changes.

Only do this when it's practical. Skip independent verification when:

- The change has no runtime surface to exercise (docs, comments, formatting, pure renames).
- Setup cost is prohibitive: the change needs credentials, external services, production data, or infrastructure you don't have.
- The change is mechanical and low-risk (dependency bumps with no API changes, generated code).

When you skip it, don't pretend otherwise — note in the summary that the review was static-only and why. When you do verify, state what you ran and what you observed, not just "verified."

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

### State and Enum Modeling

- **One dimension per enum:** each enum/status field should represent a single axis of meaning. Flag cases where a state conflates two independent concerns (e.g., a `status` field mixing "is this approved" with "is this archived" — that's two booleans wearing one enum).
- **No overloaded members:** flag values that are reused to signal different things in different contexts (e.g., `null`/`"pending"`/`-1` each meaning something different depending on which code path reads them), or a single member standing in for multiple distinct real-world states (e.g., `"inactive"` meaning both "never activated" and "deactivated after use" when callers need to distinguish them).
- **Exhaustive and non-overlapping:** the set of values should cover every state the domain can actually be in, with no two values describing the same underlying condition. Watch for missing states that get bolted on later as a stringly-typed workaround (e.g., a `notes` or boolean flag added beside the enum instead of extending it).
- **Exhaustiveness at the call site:** switch/match statements over the enum should handle every member explicitly (or have a clearly-intentional default); a new enum value added without updating existing switches is a correctness risk, not just a style nit.
- **Derived vs. stored state:** if a "state" can be computed from other fields (e.g., `isExpired` from a timestamp), flag storing it redundantly as its own enum member — it can drift out of sync.
- **Naming clarity:** state names should describe what *is true now*, not a past action or transition (e.g., prefer `archived` over `deleted` if the record still exists and is just hidden).

### Implicit vs. Explicit Behavior

Explicit behavior should be preferred whenever possible. Call out places where behavior is implicit instead of explicit:

- **Hidden defaults:** behavior that depends on an unstated default (e.g., a function silently falling back to a default value, region, or config when an argument is omitted) instead of requiring the caller to state intent
- **Magic values and conventions:** behavior triggered by naming conventions, file locations, environment variables, or sentinel values (`null`, `-1`, empty string) rather than an explicit parameter or setting
- **Implicit type coercion and truthiness:** logic that relies on coercion or loose truthiness checks where an explicit comparison would state the intended condition
- **Side effects and action at a distance:** functions that mutate shared state, auto-register handlers, or change behavior elsewhere without the call site making that visible
- **Implicit ordering dependencies:** code that only works if callers invoke things in a particular order, without enforcing or documenting that order
- **Silent fallbacks:** catch-and-continue or default-on-error paths that mask failures instead of surfacing them explicitly

When flagging, suggest the explicit alternative (a required parameter, a named constant, an explicit check, a raised error).

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

### Documentation

- **Missing docs:** public API changes, new config flags, new commands, or behavioral changes should be reflected in documentation
- **Stale documentation:** existing docs that contradict the new behavior (e.g., outdated examples, removed flags still listed, changed defaults not noted)
- **README / usage updates:** if the PR changes how users interact with the project, the README or usage docs should be updated accordingly
- **Changelog:** significant changes should have a corresponding entry; a version bump **requires** a changelog entry describing what changed

### Leaked Secrets and Local Environment Information

- **Hardcoded secrets:** API keys, tokens, passwords, private keys, connection strings, certificates, signing keys, or any credential-like value committed directly in source code
- **Accidental leaks in diffs:** secrets visible in removed lines (even if added in a later commit), config files with real values, or dumped logs/stack traces containing sensitive data
- **Environment-specific paths:** absolute local filesystem paths (e.g., `/Users/...`, `C:\...`, `/home/...`), machine hostnames, internal IPs, or localhost URLs committed in config, logs, or tests
- **Machine-specific identifiers:** device IDs, serial numbers, internal service endpoints, or cloud account IDs
- **Unsafe patterns:** `gitignore` files that should exclude but don't (`.env`, `*.pem`, `secrets.json`, etc.), or config files that should be templated but contain real values

## PR Size Gate

Before deep review, assess scope. The goal is reviewability, not hitting a number. Use judgment:

- Count changed lines **excluding documentation files** (e.g., `*.md`, `*.rst`, `*.txt`, `docs/**`, `README*`, `CHANGELOG*`). Around 1500 changed lines (excluding docs) is a rough guideline, not a hard cutoff. A 1200-line PR touching core architecture may need splitting; a 1800-line PR of straightforward renames and formatting does not.
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

**Verification:** <what was independently exercised and observed, or "static review only" with the reason>

### Breaking Changes
- <list breaking changes, or "None">

### Risks
- <list risks with severity: HIGH / MEDIUM / LOW>

### Documentation
- <flag missing, stale, or outdated documentation, or "None">

### Secrets and Environment Leaks
- <flag any leaked secrets, credentials, or local environment information with file and line references, or "None">

### Findings
- <correctness issues, with file and line references>
- <implicit behavior that should be explicit, with the suggested explicit alternative>
- <bloat or scope concerns>
- <performance concerns>

### Description Alignment
- <describe mismatches between the PR body and the actual diff, or "PR description accurately reflects changes">

### Split Recommendation
- <recommend splitting with concrete boundaries, or "Not needed — PR is appropriately scoped">
```

Keep findings to the top 5–8 items. If the PR is clean, say so explicitly. Omit entire sections that have no items rather than writing "None" for everything.
