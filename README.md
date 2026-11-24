# skills

Agent Skills, published as a Claude Code plugin marketplace (`mturner-skills`).

## Plugins

| Plugin | Skills |
|---|---|
| `dev-workflow` | pr-review, security-audit, perf-optimization, tigerstyle, summarize-repo-changes, search-repos |
| `arch-linux` | arch-audit, check-pacman-updates |
| `embeddings` | embeddings-ingest, embeddings-query |
| `personal` | lease-hackr, search-flights, socratic-tutor |

The marketplace manifest is `.claude-plugin/marketplace.json`. Each plugin lists its skill directories with `"strict": false`, so the skills stay at the repository root.

## Install

```
/plugin marketplace add matthewmturner/skills
/plugin install dev-workflow@mturner-skills
/plugin install arch-linux@mturner-skills
/plugin install embeddings@mturner-skills
/plugin install personal@mturner-skills
```

For an automatic setup on each machine, run `install-claude-plugins.sh` from the `configs` repository.

Plugin skills have a namespace. For example, use `/dev-workflow:pr-review`.

## Update

Claude Code uses a cached copy of each plugin. To get new changes:

```
/plugin marketplace update mturner-skills
```

## Add or change a skill

1. Add the skill directory with a `SKILL.md` at the repository root.
2. Add the directory path to the `skills` list of one plugin in `.claude-plugin/marketplace.json`.
3. Increase the `version` of that plugin. Use a minor version for a new skill, a patch version for a fix, and a major version for a removed or renamed skill.
4. Run `claude plugin validate .`.
