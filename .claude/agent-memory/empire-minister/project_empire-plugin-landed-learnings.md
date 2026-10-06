---
name: empire-plugin-landed-learnings
description: Harvested learnings land in kattakath/skills plugins/empire (agent .md files), and reach this fleet only after the kattakath-skills flake input is bumped here — two separate steps
metadata:
  type: project
---

Harvested agent-behaviour learnings are implemented in **`github:kattakath/skills` →
`plugins/empire/agents/*.md`**, not in nix-config. Landing a learning there does **not**
change this fleet until the `kattakath-skills` flake input is bumped in nix-config
(`/update-input kattakath-skills`). Those are deliberately two PRs in two repos.

**Why:** `plugins/` and `skills/` were externalized out of this repo on purpose
(`docs/agent-resource-externalization.md`). The marketplace auto-updates for installed
consumers — but this repo's *pin* is what `checks.*.mcp-launcher-parity` and
`page-lab-pick` read, so a merge there leaves this repo's pin stale and silently behind.

**How to apply:** after any `plugins/empire` merge, the follow-up here is a lock bump, and
it is the only nix-config change such work needs. Do not look for agent prompt text in this
tree — none of the four empire agent files exist here.

Conventions that differ from this repo and cost a wrong guess:

| | `kattakath/skills` | nix-config |
|---|---|---|
| PR/commit title | `<plugin>: <lowercase description>` — ONE plugin name, then prose | [[pr-title]] rule: comma-separated touched components |
| Release model | every commit on `main` IS a release; plugins carry **no** `version` | flake pins |
| Gate | `claude plugin validate` (CLI **pinned 2.1.268**, not `latest`) + `scripts/build-index.py --check` + per-plugin test suites in `.github/workflows/validate.yml` | `nix flake check` |
| Index | `INDEX.md` is **generated** — never hand-edit; `index/routes.json` routes by **plugin**, so an agent-file-only change needs no route and no rebuild | n/a |

**One trap worth keeping:** `skill-usage.py` counts a **backticked plugin name anywhere in
another plugin's markdown** as a dependency and silently reclassifies that sibling as
`exempt` from curation. So agent/README prose there must cite a count or a file path, never
a sibling's name in backticks. Verified 2026-10-06 (PR #67) by grepping the added lines for
backticked tokens before committing.
