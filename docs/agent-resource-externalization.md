# Agent-resource externalization (2026-09-12)

**Decision: the operator's own Claude Code resources — plugins, skills, userscripts —
leave this tree and come back as pinned `flake = false` inputs.** Nix keeps the pin, the
wiring, the gates and the service; the content is maintained in its own repo like any
community resource.

| Resource | Now lives in | Pinned as |
|---|---|---|
| `page-lab`, `llmstxt` plugins | `github:kattakath/claude-plugins` | `kattakath-claude-plugins` |
| `rag`, `nix-dev-toolkit`, `android-phone` skills | `github:kattakath/claude-skills` | `kattakath-claude-skills` |
| public userscripts | `github:kattakath/userscripts` | `kattakath-userscripts` |
| private userscripts | `gitlab:ismailkattakath/userscripts` | pinned by **nix-personal** |
| `seargraph` agent | `ismailkattakath/SEARGraph` `.claude/agents/` | nothing — see § Deletions |

Lock nodes: **56 → 59**.

## Why this is not ADR-002 in reverse

[ADR-002](monoflake-capsule-adr.md) absorbed seven satellite **flakes** back in-tree and
archived their repos. This does the opposite to a different class of artifact, and the
distinction is the whole argument:

| | ADR-002 capsules | Agent resources |
|---|---|---|
| Consumed by | Nix, at eval | **Claude Code, at runtime** |
| Consumers | this fleet only | **anyone with Claude Code** |
| Boundary | had to be *invented* (`capsule-must-not-reach-out` + a registry check) | **already exists** — `${CLAUDE_PLUGIN_ROOT}`, and a skill is a directory with a `SKILL.md` |
| Cost of the split | a cross-flake seam per capsule, 8 lock nodes for one library | one lock node each, no seam |
| Useful to strangers | no | **yes — that is the point** |

A capsule out-of-tree was a boundary this repo had to police. A plugin out-of-tree is a
boundary Claude Code already enforces. Opposite artifact, opposite answer.

## Why the Nix rail, not the Claude-native one

Both rails express `<provider>:<owner>/<repo>`. Both were verified against the official
docs; both are real.

| | Claude-native | **Nix-native (chosen)** |
|---|---|---|
| Syntax | `marketplace.json` → `{"source":"github","repo":"o/r","ref","sha"}` | `inputs.x = { url = "github:o/r"; flake = false; }` |
| Pin lives in | hand-edited JSON, per plugin | **`flake.lock`, one place** |
| Bumped by | a manual sha edit | `nix flake update` + `update-flake-lock.yml` |
| Integrity | git sha | **NAR hash, Cachix-substitutable** |
| Fetched by | Claude Code, at activation, **over the network** | Nix, cached, offline after first fetch |
| Seen by `drv-snapshot.sh` | no | **yes** |

There is no separate nix-darwin/home-manager convention to adopt for this: **the flake URL
scheme *is* the standard** (`github:`, `gitlab:`, `sourcehut:~user/`, `git+ssh://`).

Both rails are live, because they serve different people: strangers run
`/plugin marketplace add kattakath/claude-plugins`; this fleet pins the input.

## Why one marketplace repo and not one repo per plugin

Measured across every public marketplace found on GitHub, 2026-09-12:

| Repo | ★ | Plugins | `./relative` | external | sha-pinned |
|---|---|---|---|---|---|
| trailofbits/skills-curated | 499 | 29 | **29** | 0 | 0 |
| Piebald-AI/claude-code-lsps | 517 | 38 | **38** | 0 | 0 |
| fivetaku/gptaku_plugins | 1134 | 19 | **19** | 0 | 0 |
| MadAppGang/claude-code | 280 | 9 | **9** | 0 | 0 |
| obra/superpowers-marketplace | 1256 | 10 | 0 | 10 `url` | 0 |
| danielrosehill/Claude-Code-Plugins | 30 | 170 | 0 | 170 `github` | 0 |
| anthropics/claude-plugins-official | — | 295 | 52 | 89 subdir + 154 url | **243** |

The split is about **ownership, not scale**: everyone who owns their plugins ships them
in one repo with `./plugins/<name>` sources — Trail of Bits included, at 29 plugins.
External `{source:github,…}` with a `sha` is what **catalogs** need, because they list
plugins they do not own. Anthropic pins 243/295; the hobbyist aggregators pin zero.

This operator owns two plugins, so: one repo, relative sources. The marketplace repo's own
revision pins its plugins transitively, which is why nobody in that table needed per-plugin
shas.

## The rule this migration turned on

> **A gate must move with the content it gates.**

`checks.<system>.userscripts` read `${self}/userscripts` — this repo's tree only — while
this repo owned the `userScripts.scripts` *option* for both layers. Owning an option does
not gate its consumers, and the build still went green. Measured 2026-08-31: nix-personal's
`civitai-declutter` shipped with **no `@license`** and the check never saw it.

Extracting the tree and leaving that check alone would have been strictly worse than the
original hole — a green build over an **empty directory**. So both operands moved to the
inputs: the linter from `kattakath-claude-plugins`, the scripts from
`kattakath-userscripts`. nix-personal does the same for its own pinned private repo, which
is the first time those four scripts have ever been gated.

Same for `checks.<system>.page-lab`, and for `packages/page-lab-pick.nix`, whose
repo-relative `plugins/page-lab/scripts/pick-element.mjs` source literal was the one genuinely
eval-breaking reference in the move.

## Deletions

- **`plugins/seargraph`** — 2 files (one agent `.md` + a manifest), no README, no skills,
  no commands, for a **private** repo last pushed 2026-08-22. Its stated justification was
  *scoping*: `programs.claude-code.agents` installs globally, a plugin is per-project. The
  reasoning was right and the mechanism was wrong — **a project's own `.claude/agents/` is
  the canonical way to scope an agent**, and needs no plugin, no marketplace entry and no
  Nix wiring. The file now lives at `SEARGraph/.claude/agents/seargraph-langgraph.md`. Net:
  one fewer plugin, one fewer agent in the global list, one fewer thing to pin.

## One footgun this closes for free

A **directory path literal copies the worktree**; a **flake input copies the git tree**. A
stray `.DS_Store` under `plugins/` became a closure input once and moved the `macos` drv
(nix-personal's `.claude/rules/store-copied-trees.md` is the record). That failure mode is
now structurally impossible for every extracted tree — gitignore and the store copy finally
agree, because git is doing the copying.

## What deliberately did NOT move

| Tree | Why it stays |
|---|---|
| `claude/` (CLAUDE.md, Brain Signals kit) | operator identity and an accessibility calibration, not a community resource; `context` must also be a single path |
| `skills/{explain,compare,map,zoom,why,tldr,diagram}` | one kit with the output style in `modules/shared/claude-brain.nix` — splitting them lets the two halves drift |
| `.claude/` | project-scoped by definition; it must live in the repo it governs |
| `.claude/skills/userscript-author` | it is about *this repo's* Nix declaration and gate, not about userscripts |
| nix-personal's `activation` plugin | documents a CLI only that flake ships |

## Adding to an extracted repo

1. Commit in that repo and push.
2. `nix flake update <input>` here, commit the `flake.lock`.
3. For a plugin, add its bare name to `local.claudePlugins.marketplaces.kattakath.plugins`;
   for a skill, add a `programs.claude-code.skills.<name>` entry; for a userscript, add a
   `programs.ungoogledChromium.userScripts.scripts.<name>` entry.

During development, skip the push/update loop with
`nix flake check --override-input kattakath-claude-plugins path:../claude-plugins`.
