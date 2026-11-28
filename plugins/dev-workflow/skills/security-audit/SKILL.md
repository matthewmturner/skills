---
name: security-audit
description: |
  Perform a threat-model-driven security audit of a pull request or an entire
  repository. First establishes a threat model for the application's domain
  (assets, actors, trust boundaries, attack surface), then investigates the
  code guided by that model rather than a generic checklist. Outputs a
  prioritized findings report tied back to the threats that motivated each
  check. Use when asked to security-audit a PR, branch, diff, or repo, or to
  threat-model an application.
---

# Security Audit

Audit a pull request or a whole repository for security risks. This is not a
grep-for-known-bad-patterns scan: the audit is driven by a threat model built
first, so effort goes where the application's actual risk is. A payment
service and a static-site generator do not deserve the same checklist.

The audit is read-only with respect to the target: never "test" a suspected
vulnerability against a live system, and never commit fixes as part of the
audit. Findings are reported, not exploited or patched.

## Workflow

### 0. Resolve the target

Determine whether the target is a **PR** or the **whole repo**:

- If the user provides a PR number or URL, audit that PR.
- If the user says "this repo", "the codebase", or gives no PR, audit the
  repository at HEAD.
- If ambiguous (e.g., on a feature branch with an open PR), check
  `git branch --show-current` and `gh pr list --head <branch> --json number`;
  if a PR exists, ask which scope the user wants — the PR delta or the full
  repo.

For PR targets, fetch with `gh` (do not rely on web fetching):

```bash
gh pr view <number-or-url> --json title,body,files,author,baseRefName
gh pr diff <number-or-url>
```

**Scope rule for PRs:** the *findings* are scoped to the change, but the
*threat model* is always built from the whole application. A three-line diff
in an auth middleware can only be judged against what the middleware
protects.

### 1. Establish the threat model

This step is mandatory and comes before reading any diff in detail. Survey
the repository broadly — README, docs, entry points, route/handler
registrations, schema/migrations, dependency manifests, CI and deploy
config — and answer, in writing:

**a. Domain and deployment context.** What does this application actually
do, and where does it run? A CLI tool run by its own user, an internet-facing
multi-tenant SaaS, an internal admin service, a library consumed by other
projects, and an embedded/on-device agent all have different threat
landscapes. State which it is and what that implies. If the domain is
regulated or inherently sensitive (payments, health, auth/identity, secrets
management, messaging), say so — it raises the bar everywhere.

**b. Assets worth attacking.** What would an attacker want here? Be
concrete: user credentials and sessions, PII, payment data, API keys held on
behalf of users, proprietary data, compute (cryptomining, relay), the
application's own trust (its signing keys, its update channel, its position
in a supply chain). Rank them — the top asset shapes the whole audit.

**c. Actors and privilege levels.** Enumerate who interacts with the system
and with what privilege: anonymous internet traffic, authenticated users,
tenant admins, operators/SREs, CI systems, third-party services and webhooks,
and the code's own dependencies. For each pair of adjacent privilege levels,
the boundary between them is a place to look.

**d. Trust boundaries and attack surface.** Map where untrusted or
less-trusted data enters and where privilege changes: network endpoints,
message/queue consumers, file uploads and parsers, deserialization points,
webhook receivers, CLI/env/config inputs, database reads of user-supplied
content (stored XSS and second-order injection), template rendering, LLM
prompt assembly if applicable, and inter-service calls. This map is the
investigation's itinerary.

**e. Top threats.** Combine the above into a short ranked list (typically
4–8) of the threats that matter most *for this domain*. Use STRIDE
(spoofing, tampering, repudiation, information disclosure, denial of
service, elevation of privilege) as a completeness prompt, not as the output
format — the output is domain-specific statements like "a tenant reads
another tenant's invoices via an unscoped query" or "a malicious lease
document injects instructions into the LLM summarization step", not "T:
tampering".

Write the threat model down before proceeding — it appears verbatim in the
final report, and every finding must trace back to it. If the survey leaves
the domain genuinely unclear (e.g., an internal service with no docs), state
the assumptions made and flag them as such.

### 2. Investigate, guided by the threat model

Take the ranked threats from step 1 and, for each, identify the code that
would have to be correct for that threat to be contained — then read it.

**For PR targets:**

- Read the full diff, then read the complete source of every security-
  relevant file the diff touches. Diffs hide context; a removed check is
  only visible as absence.
- For each changed file, ask: does this change sit on any trust boundary or
  guard any asset from the threat model? If yes, audit it deeply. If no,
  skim it for the baseline checks below and move on.
- Look specifically for **regressions**: checks that were weakened, removed,
  reordered, or made bypassable; error paths that now fail open; validation
  moved to a place attackers can skip (e.g., client-side only, or after a
  side effect already happened).
- Check what the PR *should* have changed but didn't: a new endpoint added
  without the authz middleware its siblings use, a new query parameter that
  skips the sanitization its siblings get. Compare against existing patterns
  in neighboring code.

**For repo targets:**

- Work through the trust-boundary map from step 1d, highest-ranked threat
  first. For each boundary, trace the untrusted data from entry to every
  sink it reaches.
- Depth over breadth: fully trace the top threats rather than shallowly
  skimming everything. Note explicitly in the report which areas were not
  examined.

**Baseline checks** (apply regardless of the threat model, cheap to verify):

- **Injection sinks:** SQL/NoSQL built by string interpolation, shell
  commands from user input (`exec`, `system`, subprocess with
  `shell=True`), path traversal in file operations, template injection,
  header/log injection (CRLF), unsafe deserialization (pickle, YAML load,
  Java native, `eval`-family anything).
- **AuthN/AuthZ:** endpoints missing authentication where siblings have it;
  object-level authorization (can user A pass user B's id?); privilege
  checks done client-side or in the UI only; JWT/session pitfalls (alg
  confusion, missing expiry/audience checks, tokens in URLs or logs).
- **Secrets:** hardcoded credentials, keys, or connection strings; secrets
  in logs, error messages, or test fixtures; secrets visible in *removed*
  diff lines (still in history); `.gitignore` gaps for `.env`, `*.pem`, etc.
- **Crypto misuse:** homemade crypto, ECB mode, static IVs/nonces, MD5/SHA1
  for passwords, missing constant-time comparison for MACs/tokens,
  `math/rand`-class RNGs used for security material.
- **SSRF and unsafe fetch:** user-influenced URLs fetched server-side
  without allowlisting; redirects followed into internal address space.
- **Dependency and supply chain:** newly added dependencies (who publishes
  them, are they typosquat-shaped, do they run install scripts); lockfile
  changes that don't match the manifest; CI workflows that run untrusted PR
  code with secrets in scope (`pull_request_target` and friends); curl-pipe-
  to-shell in build scripts.
- **Data exposure:** verbose errors/stack traces to clients, debug endpoints
  or flags reachable in production config, overly broad CORS, missing rate
  limits on auth and enumeration-prone endpoints, PII in logs.

Verify before reporting: for each candidate finding, read enough surrounding
code to confirm the vulnerable path is actually reachable with
attacker-controlled input. A parameterized query that merely *looks* like
interpolation, or an "unauthenticated" endpoint behind a gateway that
enforces auth, is not a finding — but if containment relies on something
outside the repo (that gateway, a WAF), note the assumption.

### 3. Rate and prioritize findings

For each confirmed finding assign:

- **Severity** — CRITICAL / HIGH / MEDIUM / LOW / INFO, judged by impact on
  the threat model's assets combined with exploitability. A textbook
  vulnerability in code that never sees untrusted input is LOW/INFO; a small
  logic slip on the primary trust boundary can be CRITICAL. Severity comes
  from *this* application's threat model, not from a CWE's generic rating.
- **Threat traceability** — which step-1 threat it realizes. A finding that
  maps to no modeled threat means either the finding is noise or the model
  missed something; if the latter, update the model (and say so).
- **Confidence** — confirmed (traced a full attacker-controlled path),
  probable (path likely but a step is unverified), or needs-verification
  (suspicious pattern, could not confirm statically).

Include an attack scenario for every CRITICAL/HIGH finding: who the attacker
is (from step 1c), what they send or do, and what they get. If a concrete
scenario cannot be written, the severity is probably lower than it feels.

### 4. Output the report

No preamble, no filler. Structure:

```
## Security Audit: <PR title / repo name>

**Target:** <PR #N (delta vs base) | full repository at <commit>>
**Verdict:** <one line: e.g. "2 high-severity issues to fix before merge" or "no significant findings within audited scope">

### Threat Model
**Domain & context:** <what the app does, where it runs, sensitivity>
**Key assets:** <ranked>
**Actors:** <privilege levels, external systems>
**Trust boundaries:** <where untrusted data enters / privilege changes>
**Top threats:**
1. <domain-specific threat statement>
2. ...

### Findings
#### [SEVERITY] <short title> — <file:line>
- **Threat:** <which top threat this realizes>
- **Confidence:** confirmed | probable | needs-verification
- **Detail:** <what the code does and why it's exploitable, with the data path>
- **Attack scenario:** <actor → action → outcome; required for CRITICAL/HIGH>
- **Recommendation:** <concrete fix, referencing existing patterns in the codebase where they exist>

### Assumptions and Unaudited Areas
- <external controls assumed present (gateway auth, WAF, network policy)>
- <areas not examined and why>

### Hardening Suggestions
- <non-findings worth doing: missing rate limits, defense-in-depth gaps — optional, max 3–5>
```

Order findings by severity. If there are no findings, say so explicitly and
still include the threat model and the unaudited-areas section — a clean
audit is only meaningful relative to what was checked. Omit the Hardening
section rather than padding it.

## Notes

- Do not pad the report with theoretical issues to look thorough; five
  traced, confidence-rated findings beat twenty pattern-match guesses.
- If the diff or repo is too large to audit meaningfully in one pass, say so
  and propose a scope split (e.g., "auth and payment paths this pass") rather
  than silently skimming.
- Secrets found in the diff or history are always at least HIGH and should
  be called out for rotation, not just removal — deleting the line does not
  unleak the key.
