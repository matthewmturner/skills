---
name: check-pacman-updates
description: Check for available official-repo package updates on Arch Linux (and derivatives) via checkupdates, without installing anything. Lists outdated packages with old→new versions, and best-effort short changelog summaries. Use when the user wants to know what updates are pending before deciding whether to upgrade.
---

# Check Pacman Updates

Report which packages have official-repo updates available, with a short changelog summary per package where one can be found. **Never install, upgrade, or modify any package** — this skill is read-only/reporting only.

AUR updates (via `yay` or other AUR helpers) are out of scope for now — official repos only.

## Hard rule: no upgrades

Do not run `pacman -Syu`, `pacman -S <pkg>`, or anything with `--noconfirm` on an install/upgrade operation. Only run the query/check commands below. If the user asks you to actually apply the updates after seeing the report, confirm with them explicitly before running any install command.

## Step 1: Detect available tools

```bash
command -v pacman >/dev/null || echo "pacman not found — not an Arch-based system"
command -v checkupdates >/dev/null || echo "checkupdates not found — needs pacman-contrib"
```

- If `pacman` is missing, stop and tell the user this isn't an Arch-based system.
- `checkupdates` (from the `pacman-contrib` package) is the **only** mechanism this skill uses to check updates: it syncs a **temporary copy** of the package database instead of the real one, so it can't cause a [partial upgrade](https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported). Do not fall back to `pacman -Sy` / `pacman -Qu` — if `checkupdates` isn't installed, tell the user to install `pacman-contrib` (`sudo pacman -S pacman-contrib`, which they must run themselves) and stop there.

## Step 2: List pending updates

```bash
checkupdates
```

Output is lines like `pkgname oldver -> newver`. Exit code 2 / no output means no updates.

## Step 3: Best-effort changelog per package

For each outdated package, also grab the one-line package description from the sync db so the report can show what each package is:

```bash
pacman -Si <pkgname> 2>/dev/null | grep -i '^Description'
```

Keep the description to a single sentence (trim trailing punctuation/whitespace as needed). If `pacman -Si` returns no Description line, fall back to the installed package's info:

```bash
pacman -Qi <pkgname> 2>/dev/null | grep -i '^Description'
```

If neither yields a description, use "-" in the report.

Then, for the changelog, try these in order and use the first that yields something useful. Keep the summary to 2-4 bullet points per package — don't dump full changelogs.

1. **Installed changelog file** (rarely populated for modern packages, but free to check):
   ```bash
   pacman -Qc <pkgname>
   ```
   If it returns `ERROR: no changelog available for '<pkgname>'`, move on.

2. **Upstream project changelog/release notes** — get the project URL, then fetch it:
   ```bash
   pacman -Si <pkgname> 2>/dev/null | grep -i '^URL'
   ```
   If the URL points at GitHub/GitLab, use WebFetch on that repo's releases or tags page (e.g. `https://github.com/<owner>/<repo>/releases`) and summarize what changed between the old and new version tags. If it's a project with its own changelog page/file, fetch that instead.

If neither yields anything, report the package with old→new version and note "no changelog found" rather than guessing.

**Scale the effort to the number of updates.** If there are only a handful of packages, fetch changelogs for all of them. If there are dozens (common after not updating for a while), fetch changelogs only for the packages the user is likely to care about (e.g. major/core packages: kernel, drivers, desktop environment, browsers) and note how many minor/library packages were skipped, offering to fetch more on request.

## Step 4: Report

Present a single markdown report. Always include both an "update all" command and a per-package update command list at the end — the user asked for these recommendations to be part of every report. **Do not run these commands yourself**; present them for the user to run (see the hard rule in the intro and the edge case below).

```markdown
# Pending Updates

## Official repos (N)

| Package | Description | Current | New | Notes |
|---|---|---|---|---|
| linux | The Linux kernel and modules | 6.9.1-1 | 6.9.2-1 | - Fixes X driver regression\n- Security patch for Y |
| curl | Command line tool and library for transferring data with URLs | 8.7.0-1 | 8.8.0-1 | no changelog found |

## Summary

Total: N updates pending. No packages were installed or upgraded.

## Recommended update command

Update all pending packages at once:

    sudo pacman -Syu
```

If there are zero updates, state that plainly instead of showing an empty table (and omit the commands section).

## Edge cases

- **`checkupdates` unavailable:** report that update checking requires the `pacman-contrib` package and stop there — do not fall back to `pacman -Sy`/`pacman -Qu`.
- **No network access:** `checkupdates` will fail to reach mirrors — report the failure, don't fall back to stale local data as if it were current.
- **Rate limiting / fetch failures on changelog lookups:** skip that package's changelog and note "changelog fetch failed", don't retry indefinitely.
- **User asks to proceed with the upgrade after seeing the report:** the report already lists the recommended command (`sudo pacman -Syu`). Confirm explicitly before running any `-Syu` command yourself; by default present the command and let the user run it.
