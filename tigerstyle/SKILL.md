---
name: tigerstyle
description: |
  Evaluate a pull request, branch, diff, or whole repository through the lens of
  TigerBeetle's TigerStyle: safety, performance, and developer experience, in
  that order. Checks assertion density, bounded loops and queues, static
  allocation, function length, explicit control flow, error handling, naming
  with units, off-by-one hazards, back-of-the-envelope performance, and
  dependency cost. Use when the user asks for a "TigerStyle review", asks to
  review code "like TigerBeetle", "NASA Power of Ten", "assertion density", or
  wants a safety-first style audit of a PR or repo in any language.
---

# TigerStyle Review

Evaluate code against [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
The design goals are **safety, performance, and developer experience, in that order**.
Every finding must state which goal it serves and why it matters.

TigerStyle was written for Zig and for a database. Translate each rule to the target
language and domain. Read `references/rules.md` for the full rule checklist. Read
`references/languages.md` for language translations and mechanical checks.

## Workflow

### 0. Resolve the target

- **PR number or URL:** use `gh pr view <n> --json title,body,files,additions,deletions,baseRefName,headRefName,commits` and `gh pr diff <n>`.
- **No target given, on a feature branch:** run `git branch --show-current`, then `gh pr list --head <branch> --json number`. If no PR exists, review `git diff $(git merge-base HEAD origin/HEAD)...HEAD`.
- **"the repo" or a path:** review the whole repository or that path. Do not use the diff workflow.
- If the target is ambiguous, ask the user.

### 1. Establish context

- Identify the language(s), the domain, and the criticality. A storage engine, a consensus
  layer, or a payment path gets the strict reading. A one-off script or a UI layer gets a
  proportional reading. State the reading you chose in the output.
- Identify the hot paths and the trust boundaries (network, disk, user input, FFI).
- Read the full source of each changed file in a PR. The diff alone hides context such as
  the existing assertion style, existing bounds, and caller contracts.

### 2. Run mechanical checks

Run the checks in `references/languages.md` for the language. They give numbers for:

- Lines over 100 columns.
- Functions over 70 lines.
- Assertion count per function (assertion density).
- Recursion candidates.
- Unbounded loops (`while true`, `loop {}`, `for {}`).
- Allocation sites outside initialization.
- New dependencies.

For a PR, report only the numbers for added or changed lines. Do not penalize a PR for
pre-existing debt in code it does not touch. You can note that debt in one line.

For a repo, report the totals and the five worst files or functions for each metric.

Numbers are evidence, not a verdict. A 72-line function with a flat `switch` can be fine.
A 40-line function with five nested branches can be worse.

### 3. Evaluate against the rules

Walk the rule groups in `references/rules.md` in order: Safety, Performance, Developer
Experience, Dependencies and Tooling. For each candidate finding:

1. Confirm it by reading the code. Do not report a pattern match without reading it.
2. Name the rule. Use the short IDs in `references/rules.md` (for example `S3 bounds`).
3. State the concrete failure: the input or state that causes the wrong result, the
   latency spike, the crash, or the reader confusion.
4. Give the TigerStyle fix as a code sketch in the target language when the fix is not
   obvious.

### 4. Apply judgment

- **Zero technical debt.** TigerStyle says "do it right the first time". Flag a showstopper
  (unbounded growth, exponential complexity, latency spike in a hot path, unhandled error)
  as blocking. Do not accept "we will fix it later" for those.
- **Simplicity is the hardest revision.** If the change is complex, ask if a simpler design
  solves all three goals. Propose it when you can see it.
- **Proportionality.** Do not demand static allocation in a CLI that parses one config file.
  Do demand bounds on a queue that a remote peer can fill. Say when a rule does not apply
  and why.
- **Do not invent findings.** If the code is already TigerStyle-sound in an area, say so.

## Severity

- **BLOCKING:** a safety defect. Examples: an unhandled error, an unbounded loop or queue fed
  by external input, recursion on untrusted depth, memory growth without a limit, a missing
  check at a trust boundary, a buffer bleed, a hot-path design with a known order-of-magnitude
  cost.
- **SHOULD FIX:** low assertion density on critical code, missing pair assertions on a
  disk or network boundary, functions over 70 lines with tangled control flow, compound
  conditions that hide cases, `index`/`count`/`size` confusion, reliance on library defaults
  where a default change is dangerous, missing "why" comments on non-obvious decisions.
- **NIT:** naming order (`latency_ms_max`), line length, comment punctuation, struct member
  order, abbreviations.

## Output Format

No preamble. Use this structure. Omit a section that has no items.

```
## TigerStyle Review

**Target:** <PR #n / branch / repo path> — <one-line summary>
**Reading:** <strict | proportional> — <one-line reason, such as "consensus code" or "internal CLI">
**Verdict:** <Meets TigerStyle | Meets with fixes | Does not meet> — <one sentence>

### Scorecard
| Goal | Rating | Key evidence |
|---|---|---|
| Safety | <Strong / Adequate / Weak> | <one line> |
| Performance | ... | ... |
| Developer experience | ... | ... |

### Metrics
| Metric | Value | Target |
|---|---|---|
| Functions > 70 lines | n | 0 |
| Lines > 100 columns | n | 0 |
| Assertions per function (avg, changed code) | x.x | >= 2 |
| Unbounded loops / queues | n | 0 (or asserted infinite) |
| Recursive functions | n | 0 |
| Allocations after init (hot path) | n | 0 |
| New dependencies | n | 0 |

### Blocking
- [S3 bounds] <file:line> — <failure> — <fix>

### Should Fix
- [S1 assert] <file:line> — <failure> — <fix>

### Nits
- [D2 units] <file:line> — <issue>

### Back-of-the-Envelope
<Only when the change touches a hot path or I/O. Sketch network, disk, memory, CPU cost
(bandwidth and latency) for the main operation. State if batching is present or missing.>

### What Is Already Good
- <TigerStyle strengths worth keeping, max 3>
```

Keep Blocking plus Should Fix to the top 8 items. Group repeated instances of one rule
into a single finding with a list of locations.

Use the file reference format the user's instructions require. If none is set, use
`path:line`.
