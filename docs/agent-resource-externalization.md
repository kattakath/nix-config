# Agent-resource externalization (2026-09-12)

> **Update, 2026-09-23 — delivered as a git marketplace, not the pin.** The repo is now
> [`github:kattakath/skills`](https://github.com/kattakath/skills) (renamed from `kattakath/ai`).
> `home.nix` registers it as `https://github.com/kattakath/skills.git` with `autoUpdate = true`
> (`local.claudePlugins.marketplaces.<name>.autoUpdate`, which renders
> `extraKnownMarketplaces.<name>.autoUpdate`). Its plugins carry no `version`, so every commit on
> its `main` is a release, gated by that repo's own `validate.yml`. Its top-level `skills/` are
> published as marketplace-root plugins, so the `programs.claude-code.skills` cherry-picks are
> gone, and the Brain Signals kit moved there as the `brain-signals` plugin. The input survives
> as `kattakath-skills`, for the `page-lab-pick` PATH package, `mcp.nix`'s `mcpCatalog`, and
> `checks.<system>.page-lab` (`modules/parts/checks.nix`) — **four consumers, not the "two PATH
> packages" this document said until 2026-09-30**. A plugin's `bin/` reaches the Bash tool's
> PATH but **not** a hook's (measured), which is why `page-lab-pick` is still a package.
> **`superhook` is no longer one** — see § Round two's correction below: its "a wrapper cannot
> be a plugin hook" premise was measured false on 2026-09-30 and it now ships as a plugin hook.
>
> **The Brain Signals `/explain` family went too**, and § "What deliberately did NOT move" no
> longer lists it. `skills/{explain,compare,map,zoom,why,diagram}` — a top-level tree in this
> repo until 2026-09-23 — is now the `brain-signals` plugin (with the output style, the
> `cartographer` subagent and `/task`), so the "splitting them lets the two halves drift" reason
> for keeping it was answered by moving BOTH halves rather than neither. There is no top-level
> `skills/` directory in this repo any more; `modules/shared/claude-brain.nix` keeps only the
> style selection and the calibration rule.
>
> The rest of this document is the pinned-era record.

**Decision: the operator's own Claude Code resources — plugins, skills, userscripts —
leave this tree and come back as pinned `flake = false` inputs.** Nix keeps the pin, the
wiring, the gates and the service; the content is maintained in its own repo like any
community resource.

| Resource | Now lives in | Pinned as |
|---|---|---|
| `page-lab`, `llmstxt`, `superhook`, `claude-code-nix` plugins **and** `rag`, `nix-dev-toolkit`, `android-phone` skills | `github:kattakath/ai` | `kattakath-ai` — **one repo per owner since 2026-09-14** (`claude-plugins` renamed, `claude-skills` absorbed then archived) |
| public userscripts | `github:kattakath/userscripts` | ~~`kattakath-userscripts`~~ — **pin dropped 2026-09-14** |
| private userscripts | `gitlab:ismailkattakath/userscripts` | ~~pinned by **nix-personal**~~ — **pin dropped 2026-09-14** |
| `seargraph` agent | `ismailkattakath/SEARGraph` `.claude/agents/` | nothing — see § Deletions |

Lock nodes at the time: **56 → 59**.

> **Update, 2026-09-14 — the userscript half went one step further, out of Nix entirely.**
> Both userscript pins are gone (nix-config `535f1ef`, nix-personal `c013aa5`), along with every
> script declaration and **all three** lint gates (`checks.<system>.userscripts` here;
> `checks.userscripts-lint` + `checks.userscripts-meta` there). The scripts are **published to
> Greasy/Sleazy Fork** instead. The reason is the one thing extraction could not fix: this
> pipeline **banned** `@updateURL`, so a materialised `file://` copy could never self-update,
> while a fork-installed one does. `local.ungoogledChromium.userScripts` survives as an empty
> option. Lock nodes 59 → 58. Details: [`repo-map.md`](repo-map.md) § Userscripts.
> The plugin and skill rows above are unaffected — those pins are live.

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
`/plugin marketplace add kattakath/ai`; this fleet pins the input.

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
inputs: the linter from `kattakath-ai`, the scripts from
`kattakath-userscripts`. nix-personal did the same for its own pinned private repo, which was
the first time those four scripts had ever been gated.

**The rule held when the content left for good.** On 2026-09-14 the scripts moved out of Nix
altogether, to Greasy/Sleazy Fork — and all three gates were deleted in the same commits rather
than left green over nothing. The gate went where the content went; here that destination
enforces its own rules at upload, so the gate had no operand left to hold.

Same for `checks.<system>.page-lab`, and for `packages/page-lab-pick.nix`, whose
repo-relative `plugins/page-lab/scripts/pick-element.mjs` source literal was the one genuinely
eval-breaking reference in the move.

## Round two (same day): hooks

| Was | Now |
|---|---|
| `.claude/hooks/superhook.js`, `superhook-digest.js` | `superhook` plugin — as PATH packages at the time, **as real plugin hooks since 2026-09-30** (`packages/superhook.nix` deleted) |
| `.claude/hooks/autostage-nix.js`, `nix-home-path-lint.js` | `claude-code-nix` plugin, as real plugin hooks |
| `.claude/hooks/pretooluse-bash-guard.js`, `stop-gate.js` | **stay** — fleet policy, see below |

> ### ⚠ CORRECTED 2026-09-30 — read this before the two paragraphs below
>
> The reasoning that follows was **wrong on its central factual claim**, and it is kept
> because the shape of the error is the lesson: a constraint asserted from reading the
> harness's behaviour, never probed directly, then carried for weeks as the reason for a
> whole delivery mechanism.
>
> **What was measured (Claude Code 2.1.268).** Inside a plugin hook command, **both**
> `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PROJECT_DIR}` expand — as inline substitution into
> the command string **and** as exported process environment variables. Verbatim probe:
>
> ```
> EVENT=SessionStart INLINE_PLUGIN=[…/plugin] INLINE_PROJECT=[…/proj]
>                    ENV_PLUGIN=[…/plugin]    ENV_PROJECT=[…/proj]
> ```
>
> So a plugin hook CAN name the supervisor by absolute path and pass the inner command as
> arguments — which is what wrapping *is*. "A plugin can only ADD a hook, never wrap one"
> confused the hook-set merge (additive, true) with the command's own contents (arbitrary,
> and free to invoke a wrapper).
>
> **What is still true, and was a different measurement all along:** a plugin's `bin/`
> reaches the Bash tool's PATH but **not** a hook's (2026-09-23). That is why the plugin's
> commands use an absolute `${CLAUDE_PLUGIN_ROOT}` path rather than a bare command name —
> and why `page-lab-pick` remains a PATH package. The two findings were conflated.
>
> **The caveat that shaped the replacement.** `${CLAUDE_PROJECT_DIR}` is the session's LAUNCH
> CWD, **not** the git root: a session started in `<repo>/sub` gets
> `CLAUDE_PROJECT_DIR=<repo>/sub`. So each plugin command resolves the root itself with
> `git rev-parse --show-toplevel`, re-exports it, and **exits 0 silently when the
> conventional script is absent** — which doubles as what keeps the plugin inert in every
> unrelated repo. Expansion is **proven for `SessionStart` only**; `Stop` and `PreToolUse`
> are **inferred** (an isolated `CLAUDE_CONFIG_DIR` cannot authenticate, so those events
> never fired in the probe), and the existence test is the defensive answer to that gap.
>
> Net effect: `packages/superhook.nix` **deleted**, all three `superhook` entries **deleted**
> from `.claude/settings.json` (not repointed — both scopes firing means the gate runs
> twice), `.claude/commands/superhook-review.md` **deleted** as a byte-identical duplicate of
> the plugin's copy, and `"superhook"` added to the enabled plugin list.

**A wrapper cannot be a plugin hook, and this is the constraint worth remembering.**
`superhook` is named by the consumer's `settings.json` *in front of* an inner hook. A
plugin's `hooks/hooks.json` can only ADD a hook that runs alongside the others — it cannot
wrap one. And a project `settings.json` is a checked-in file: it can hold neither a
`/nix/store` path (machine-specific, stale on every bump) nor `${CLAUDE_PLUGIN_ROOT}`
(defined only inside a plugin's own hook context).

The resolution is the one this repo reaches for everywhere else — **let Nix be the
interface.** The scripts live in the pinned marketplace input; Nix wraps them as `superhook`
and `superhook-digest` binaries; `settings.json` calls a bare command name, which is stable
in git, survives a re-pin, and needs no interpolation. Hook commands run through a shell
with the user's environment — the SessionStart hook in the same file already resolves `nix`
and `git` by PATH lookup, which is the evidence that this works.

`claude-code-nix` had no such problem: both its hooks are ordinary `PostToolUse` entries, so
they ship in `hooks/hooks.json` against `${CLAUDE_PLUGIN_ROOT}` and need no wiring at all.
Their two `settings.json` entries were **deleted rather than repointed** — keeping both
would fire each hook twice. Enabling the plugin globally is safe because both are no-ops in
a repo with no `.nix` files.

~~`superhook` the PLUGIN is deliberately **not** in this fleet's enabled list even though the
same marketplace ships it: the fleet consumes the PATH packages, and enabling the plugin too
would load a second `/superhook-review` beside the project's own.~~ **Reversed 2026-09-30**
(see the correction above): the plugin IS enabled, and the duplicate-`/superhook-review`
objection was resolved the same way `claude-code-nix`'s was — by **deleting** the in-repo
copy, which was byte-identical, rather than declining the plugin to protect it.

### What stayed, and why it is not a failure

`pretooluse-bash-guard.js` (27 KB) is the **fleet-policy** half — Cloudflare API scoping, the
`deploy` / `darwin-rebuild` live-fleet traps, a desktop-commander nudge. None of it means
anything outside this repo. That the generic half could be lifted out cleanly *is* the
factoring working: `superhook` supervises, the guard decides.

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
| `claude/` (CLAUDE.md + the Brain Signals calibration rule) | operator identity and an accessibility calibration, not a community resource; `context` must also be a single path, and plugins carry no rules or CLAUDE.md context |
| `.claude/` | project-scoped by definition; it must live in the repo it governs |
| `.claude/skills/userscript-author` | it is about how a script reaches *this Mac* — the fleet's delivery reality, not the portable authoring method (it stopped being about a Nix declaration or gate on 2026-09-14, when both ceased to exist) |
| nix-personal's `activation` plugin | documents a CLI only that flake ships |

## Adding to an extracted repo

1. Commit in that repo and push.
2. `nix flake update <input>` here, commit the `flake.lock`.
3. For a plugin, add its bare name to `local.claudePlugins.marketplaces.kattakath.plugins`;
   for a skill, add a `programs.claude-code.skills.<name>` entry. (There is no userscript step
   any more — a script is **published**, not declared; see the 2026-09-14 update above.)

The global `harvest` skill walks these steps (and decides first whether the thing is worth
keeping at all).

During development, skip the push/update loop with
`nix flake check --override-input kattakath-skills path:../skills` — the input is
`kattakath-skills` (`flake.nix`), and the repo was renamed from `kattakath/ai` to
`kattakath/skills` on 2026-09-23, so both halves of the old command were wrong.

**That override only covers what the PIN feeds** — the `superhook` / `page-lab-pick`
PATH packages and `mcp.nix`'s `mcpCatalog`. Plugin and skill **content** does not go
through the pin at all any more (the marketplace is an https git source), so an
override cannot test a plugin edit. Test that by **pushing to `kattakath/skills`
`main` and starting a new session** — the background refresh is the delivery path.
