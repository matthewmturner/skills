---
name: arch-audit
description: Run arch-audit on an Arch Linux system to check installed packages against known CVEs, then produce a structured summary of vulnerable packages grouped by severity with concrete remediation steps (update commands or mitigations for unpatched issues). Use when asked to audit a system for vulnerable packages, check for CVEs, or run a security/patch audit on Arch Linux.
---

# Arch Audit

Run `arch-audit` to find installed packages with known vulnerabilities, then turn the raw output into a prioritized, actionable report. This skill only reads system state — it never runs `pacman` upgrade/install commands itself. Remediation commands are recommendations for the user to run.

## Prerequisites

Check the tool is present before doing anything else:

```bash
command -v arch-audit
```

If missing, stop and tell the user to install it (do not install it yourself unless asked):

```bash
sudo pacman -S arch-audit
```

`arch-audit` fetches CVE data from `security.archlinux.org` on each run, so it needs network access. If a run fails or hangs, check connectivity, or use `--source <path>` with a locally cached copy of the tracker JSON for offline/air-gapped use.

## Workflow

### 1. Gather context

```bash
arch-audit --version
pacman -Q | wc -l            # total installed packages, for context in the report
```

### 2. Run the audit

Pull full structured data in one pass — JSON output, CVE ids included, and reverse-dependency info so downstream-affected packages surface too:

```bash
arch-audit --json --show-cve --recursive
```

- `--recursive` (single `-r`) adds packages that depend on a vulnerable package (`required_by` field) — treat these as lower-confidence, secondary findings, not equal to direct hits.
- If the command errors out (network failure, stale cache), retry once; if it still fails, report the failure to the user rather than guessing at findings.
- An empty JSON array (`[]`) means no known-vulnerable packages are installed — skip straight to the "no findings" report in the output format below.

### 3. Parse and classify each entry

Each JSON element has: `name` (AVG-#### advisory id), `packages`, `status`, `type`, `severity`, `fixed` (version that resolves it, or `null`), `issues` (CVE ids), and `required_by` (only present with `--recursive`).

For each entry, determine the remediation:

- **`fixed` is a version string** → fix is already published. Recommendation: `sudo pacman -Syu <package>` (or a full `sudo pacman -Syu` if several fixable packages are found — cheaper than per-package updates and avoids partial-upgrade issues). Mark as **Fixable now**.
- **`fixed` is `null`** → no upstream/repo fix yet. Mark as **No fix available**. Recommendation should be mitigation, not an update command:
  - Cross-reference `type` for mitigation hints (e.g. "denial of service" in a network-facing daemon → consider firewalling or disabling the service; "arbitrary code execution" in a rarely used package → consider removing it if not needed).
  - Point to the advisory for tracking: `https://security.archlinux.org/<name>` (e.g. `https://security.archlinux.org/AVG-2898`).
  - Note it should be re-checked on the next audit run.

### 4. Group and prioritize

Sort findings by severity: `Critical` > `High` > `Medium` > `Low` > `Unknown`. Within a severity tier, put **Fixable now** entries first (cheapest wins) — then **No fix available** entries.

De-duplicate by package where useful (a package can appear in multiple advisories); keep each advisory as its own row but consider a per-package rollup for the summary counts.

### 5. Build the JSON data file

Assemble the classified findings into a JSON object with this structure:

```json
{
  "scanned": 1234,
  "has_findings": true,
  "vulnerable_packages": 5,
  "advisories": 6,
  "summary": [
    { "severity": "Critical", "advisories": 1, "fixable": 1, "no_fix": 0 },
    { "severity": "High", "advisories": 3, "fixable": 2, "no_fix": 1 }
  ],
  "findings": [
    {
      "severity": "High",
      "package": "pam",
      "type": "arbitrary filesystem access",
      "cves": "CVE-2025-6020",
      "fixed_in": "—",
      "recommendation": "No fix yet — track https://security.archlinux.org/AVG-2901"
    },
    {
      "severity": "High",
      "package": "libxml2",
      "type": "denial of service",
      "cves": "CVE-2025-6170, CVE-2025-6171",
      "fixed_in": "2.13.9-1",
      "recommendation": "`sudo pacman -Syu libxml2`"
    }
  ],
  "no_fix_notes": [
    "pam: consider firewalling or disabling the service; track https://security.archlinux.org/AVG-2901"
  ],
  "reverse_deps": [
    { "package": "systemd", "depends_on": "pam" }
  ]
}
```

Field rules:

- `scanned`: total installed package count from `pacman -Q | wc -l`.
- `has_findings`: `false` when `arch-audit` returned an empty array; `true` otherwise. When `false`, only `scanned` is required — every other field may be omitted.
- `summary`: one row per severity tier that actually has findings, in severity order (`Critical` > `High` > `Medium` > `Low` > `Unknown`). `advisories` = count of advisories in that tier; `fixable` / `no_fix` = how many have a non-null / null `fixed` version.
- `findings`: one row per advisory, sorted by severity then **Fixable now** first. `cves` = the `issues` array joined with `", "`. `fixed_in` = the `fixed` version string, or `"—"` when null. `recommendation` = the update command or mitigation string per step 3.
- `no_fix_notes`: one short mitigation string per **No fix available** package (omit the array or leave it empty when there are none). Keep these scannable — the template renders them as sub-bullets under the "No fix available" remediation step.
- `reverse_deps`: one entry per reverse-dependency surfaced by `--recursive`, with `package` (the dependent) and `depends_on` (the vulnerable package). Omit or leave empty when `--recursive` produced nothing extra.

### 6. Render the report

Render the output using `minijinja-cli`:

```bash
minijinja-cli template.j2 /path/to/data.json
```

Read and present the rendered output. The template handles all formatting — header, summary and findings tables, remediation steps, reverse-dependency watch section, and the no-findings case. Do not construct the report markdown manually; always use the template renderer. If `minijinja-cli` is not available, install it with:

```bash
cargo install minijinja-cli
```

**Note:** the template lives at `template.j2` alongside this SKILL.md.

## Notes

- Never run `pacman -Syu`, `pacman -S`, or any other mutating package command as part of this skill — always present it as a recommended command for the user to run themselves, since a full system upgrade is a real, hard-to-reverse action on their machine.
- Keep the findings table complete but the remediation steps section short and scannable — the user should be able to act on it without cross-referencing the table.
- If `--show-testing` matters (user explicitly wants testing-repo packages included) or `--upgradable` is more convenient for a quick "what can I fix right now" pass, use them, but default to the full `--json --show-cve --recursive` scan for a complete report.
