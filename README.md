# skills

Agent Skills published for Claude Code, Pi, and Codex from one repository (`mturner-skills`).

## Plugins

| Plugin | Skills |
|---|---|
| `dev-workflow` | pr-review, security-audit, perf-optimization, tigerstyle, summarize-repo-changes, search-repos |
| `arch-linux` | arch-audit, check-pacman-updates |
| `embeddings` | embeddings-ingest, embeddings-query |
| `personal` | lease-hackr, search-flights, socratic-tutor |

Skills live under `plugins/<plugin>/skills/<skill>/`. Three manifests expose the same directories:

- Claude Code: `.claude-plugin/marketplace.json`
- Codex: `.agents/plugins/marketplace.json` and `plugins/<plugin>/.codex-plugin/plugin.json`
- Pi: `package.json` (`pi.skills`)

## Install

### Claude Code

```text
/plugin marketplace add matthewmturner/skills
/plugin install dev-workflow@mturner-skills
/plugin install arch-linux@mturner-skills
/plugin install embeddings@mturner-skills
/plugin install personal@mturner-skills
```

For an automatic setup on each machine, run `install-claude-plugins.sh` from the `configs` repository.

Plugin skills have a namespace. For example, use `/dev-workflow:pr-review`.

### Codex

```bash
codex plugin marketplace add matthewmturner/skills
codex plugin add dev-workflow@mturner-skills
codex plugin add arch-linux@mturner-skills
codex plugin add embeddings@mturner-skills
codex plugin add personal@mturner-skills
```

### Pi

```bash
pi install git:github.com/matthewmturner/skills
```

Run `pi config` to enable or disable individual skills.

## Update

### Claude Code

```text
/plugin marketplace update mturner-skills
```

### Codex

```bash
codex plugin marketplace upgrade mturner-skills
```

### Pi

```bash
pi update --extensions
```

## Add or change a skill

1. Add or edit the skill directory under `plugins/<plugin>/skills/<skill>/` with a `SKILL.md` file.
2. For a new skill, add `"./skills/<skill>"` to the plugin entry in `.claude-plugin/marketplace.json`.
3. Increase the `version` of that plugin in `.claude-plugin/marketplace.json` and `plugins/<plugin>/.codex-plugin/plugin.json`.
   Use a minor version for a new skill, a patch version for a fix, and a major version for a removed or renamed skill.
4. Run `claude plugin validate .` to verify the Claude Code manifest.
