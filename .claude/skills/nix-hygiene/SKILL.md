---
name: nix-hygiene
description: >
  Audit and fix this nix-config mono-repo for LEAN/DRY/modular/atomic quality:
  abandoned surface, doc drift, host-scope mistakes, anti-patterns, comment
  rot. Use when asked to "hygiene", "cleanup the repo", "LEAN/DRY pass",
  "audit modularity", "remove bloat", "align with CLAUDE.md", or keep
  nix-darwin/home-manager patterns clean. Composes git-purity, nix fmt,
  flake check, and optional domain doctors — not a substitute for /eval alone.
---

# nix-hygiene

**Floor (already automated):** `nix fmt` / treefmt (nixfmt + statix + deadnix),
Stop gate + `/eval` (`git add` → `nix flake check`), CI `nix-ci.yml`.

**This skill:** judgmental hygiene — architecture, host scope, docs↔code,
abandoned experiments, comment rot — then **fix** and **re-gate**.

Canonical architecture/conventions: root [`CLAUDE.md`](../../../CLAUDE.md).
Do not restate the whole fleet map; open CLAUDE.md when unsure.

## When to use

| Trigger | Mode |
|---|---|
| "hygiene" / "LEAN DRY" / "cleanup" | Full or scoped pass |
| After a large feature (e.g. macvm) | Scoped to touched paths |
| Before a big PR merge | Full pass + a manual diff review |
| Docs feel wrong | Docs-surface only |

**Not for:** pure "does it evaluate?" → `/eval`. Pure PR review without fix → a manual diff review (no dedicated command exists in this repo — see §H).

## Modes

Parse the user request:

1. **`audit`** — findings only (no edits). Triggered when they say "audit" / "report".
2. **`fix`** — audit → apply safe fixes → format → eval. **The overall default** when neither `audit` nor a scope-only request is given.
3. **`scope <path|host|area>`** — limit to that surface (e.g. `macvm`, `packages/`, `docs/`).

Never expand into new features. Prefer delete/simplify over new abstraction.

## Path → responsibility map

| Path | Owns | Typical flake output |
|---|---|---|
| `flake.nix` / `flake.lock` | pins, `mkDarwin`/`mkNixos`, apps | all |
| `hosts/<name>.nix` | host-only deltas | `darwinConfigurations` / `nixosConfigurations` |
| `modules/shared/` | cross-host HM + shared options | both |
| `modules/darwin/` | macOS system | `darwinConfigurations` |
| `modules/nixos/` | NixOS system | `nixosConfigurations` |
| `packages/` | flake apps/packages | `packages` / `apps` |
| `docs/` | runbooks | — |
| `.claude/` | agent skills/commands/hooks | — |
| `infra/` | terranix | `apps` (cf-*, hf-*) |
| `secrets/` | agenix recipients + ciphertext | — |

**Platform branching:** `lib.mkIf` in `modules/`, not copy-paste across hosts.
**Host gates:** `networking.hostName` / `osConfig` where macos ≠ macvm.

## Checklist (run in order)

### A. Surface inventory

- [ ] `git status` — no surprise WIP; stage only intentional hygiene.
- [ ] Touched/scope files still match CLAUDE.md story (no orphan modules).
- [ ] Flake apps in `flake.nix` have matching `packages/*` and runbook mentions if user-facing.
- [ ] Reverse: runbooks mention only apps/paths that still exist.

### B. LEAN / abandoned

- [ ] Experimental dual paths (e.g. old and new sshd) collapsed to one.
- [ ] Commented-out blocks with no near-term intent removed or ticketed in `memory/` (gitignored).
- [ ] Dead options, unused `let` bindings (deadnix/statix will catch some — don't rely only on them).
- [ ] Vendor copies justified (e.g. `hm-launchd`) with a one-line "why not upstream" comment.

### C. DRY / modular / atomic

- [ ] One path for one fact (e.g. Screengrab path shape shared conceptually host/guest).
- [ ] No host-specific lists in shared modules without `mkIf` / hostName / `isMacosHost`.
- [ ] Launchd BTM basenames: `nix-<activity>` via `mkNixAgent` / `hm-launchd` (never bare `sh`/`open`).
- [ ] Secrets: never plaintext in `.nix`; agenix vault vs Keychain rules unchanged.

### D. Comments & docs

- [ ] Comments explain **why**, not restate the code.
- [ ] Remove "we tried X then Y" experiment narratives unless they prevent a known footgun (one sentence max).
- [ ] `docs/*-runbook.md` and skill frontmatter match current commands.
- [ ] CLAUDE.md skill/command lists include this skill after add.

### E. Community patterns

- [ ] Prefer upstream nix-darwin / HM options over custom shell when equivalent.
- [ ] `writeShellApplication` for scripts; shellcheck via that path.
- [ ] No new `environment.etc` hacks for things nix-darwin models.
- [ ] Determinate Nix: no `nix.enable = true` / no hand-written `nix.custom.conf`.

### F. Mechanical gate (mandatory after fixes)

```bash
git add -A
nix fmt
git add -A   # fmt may rewrite
git status --porcelain '*.nix'   # clean of ?? 
nix flake check                  # or scoped nix eval of affected toplevels
```

If `nix` unavailable: `nix-instantiate --parse` on changed `.nix` + state CI-deferred.

### G. Domain doctors (only if scope touched)

| Scope | Command |
|---|---|
| macvm / Tart / Screengrab share | `nix run .#macvm-tart-doctor` |
| nixpi flash/provision | skill `nixpi-firmware-provision` |
| Vast templates | skill / docs as needed |

### H. Optional second opinions

- Structural harshness: global **code-review** skill on the diff.
- Behavior check after fix: manually drive the change end-to-end (no dedicated command).
- PR findings only: a manual diff review (no dedicated command).

## Fix policy

| Do | Don't |
|---|---|
| Delete dead code and experiment comments | Drive-by renames across the monorepo |
| Gate host-only agents with `hostName` | Add options "for later" |
| Update runbook + skill together | Leave CLAUDE.md lists stale |
| One logical commit (or session PR per rules) | Silent behavior change without note |

**Breaking host behavior** (e.g. removing an agent): say so in the report; prefer `mkIf` off over surprise removal.

## Report format (always end with this)

```markdown
## Hygiene report
- **Mode:** audit | fix
- **Scope:** …
- **Findings:** (bullet: path — issue — action taken or deferred)
- **Gates:** fmt ✅/❌ · flake check ✅/❌ · doctors …
- **Verdict:** CLEAN | FIXED | BLOCKED (why)
```

## Anti-patterns specific to this fleet

1. **macvm inheriting macos login openers / RAG / MCP gateway** — must stay lean.
2. **Guest file-rotation on shared Screengrab** — host-only.
3. **Dual SSH stacks on macvm** — one path (Apple's sshd + bootstrap).
4. **Putting `.utm` / IPSW / disk images in the flake.**
5. **Hand-editing `flake.lock`.**
6. **HM launchd without `hm-launchd` / `nix-*` basename** — BTM phantoms return.

## Compose with existing automation

```
/hygiene [scope]     → this skill (audit+fix+gate)
/eval                → eval only
code-review skill    → structural/PR-diff review (no dedicated /review or /verify command exists)
```
