# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Standalone Nix flake + Home-Manager mono-repo managing one declarative environment across **macOS (aarch64-darwin)**, **standard Ubuntu (x86_64-linux)**, and **Devcontainers (aarch64-linux / x86_64-linux)**. Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## Build / Test / Lint

```bash
git add -A                                   # MANDATORY before any eval — flakes ignore untracked files
nix flake check                              # Evaluate every output + formatting/lint/pre-commit checks (the test suite)
nix flake show                               # List exported homeConfigurations + packages
nix fmt                                       # Format + lint-fix all .nix via treefmt (nixfmt + statix + deadnix)
nix develop                                   # Enter dev shell (nixd LSP, treefmt, home-manager); installs pre-commit hooks
nix build .#checks.<system>.formatting        # CI formatting/lint gate (fails on unformatted/lintable files)
home-manager build --flake .#user@ubuntu-vm   # Build a Linux config without activating (also: user@raspberrypi)
home-manager switch --flake .#user@ubuntu-vm  # Activate a Linux generation
darwin-rebuild switch --flake .#macbook       # Activate the macOS (nix-darwin) config
nix flake check .#homeConfigurations."user@ubuntu-vm"   # Evaluate a SINGLE config (fast single-target check)
```

## Architecture

- `flake.nix` — entry point: pins `nixpkgs` + `home-manager` + `nix-darwin` + `treefmt-nix` + `git-hooks` inputs; exports `darwinConfigurations."macbook"` (aarch64-darwin), `homeConfigurations."user@ubuntu-vm"` (x86_64-linux) and `"user@raspberrypi"` (aarch64-linux), plus `packages`/`devShells`/`checks`/`formatter` per system via a `forAllSystems` helper.
- `flake.lock` — pinned input revisions; commit every change, never hand-edit.
- `treefmt.nix` — single source of truth for formatting + lint-fix (nixfmt + statix + deadnix). Drives `nix fmt`, the `checks.formatting` CI gate, and the pre-commit hook — change a tool here and every entrypoint follows.
- `.envrc` — direnv `use flake`; auto-loads the devShell (nixd, treefmt, hooks) in shell + editor. Run `direnv allow` once.
- `hosts/` — per-host entry profiles (`macbook.nix`); composed by the flake's `darwinConfigurations`/`homeConfigurations`.
- `modules/` — reusable modules split by platform: `modules/darwin/core.nix`, `modules/linux/nix-ld.nix`, `modules/shared/home.nix`. Platform branching lives HERE behind `lib.mkIf`, not duplicated across hosts.
- `packages/docker-image.nix` — minimal runtime container image (`dockerTools`, baseless).
- `.claude/agents/platform-compiler.md` — subagent that validates evaluation across all three architectures.
- `.claude/commands/` — `/eval`, `/update-input`, `/superhook-review` (triage the hook-supervisor log), `/remember-nix` (capture into project memory).
- `.claude/rules/git-purity.md` — always-applied rule: stage `.nix` files before eval.
- `.claude/hooks/` — `stop-gate.js` (Stop gate: blocks until configs evaluate clean) and `delegate-team.js` (UserPromptSubmit orchestration policy), both wrapped by `superhook.js` (crash-safety + loop-breaking + logging); plus `superhook-digest.js` and `memory-loader.js` (SessionStart context surfacing) and `autostage-nix.js` (PostToolUse git-purity net).
- `memory/` — **gitignored** project memory (decisions/findings/values/evolution): the candid "why" behind the repo, surfaced each session by `memory-loader.js`. Never `git add`.
- `.github/workflows/flake-check.yml` — CI matrix evaluating all three systems (aarch64-linux via QEMU) + lint; this is where the locally-deferred full `nix flake check` actually runs.

## Conventions

- **Naming:** kebab-case files; `lowerCamelCase` Nix bindings; modules named by the platform/concern they own.
- **Platform branching:** isolate in `modules/` via `lib.mkIf` on `stdenv.hostPlatform`/`isDarwin`/`isLinux` — host profiles stay declarative and platform-agnostic.
- **Systems:** the canonical triple is `aarch64-darwin`, `x86_64-linux`, `aarch64-linux`. Every new output must evaluate on all three or be explicitly gated.
- **Inputs:** bump only via `nix flake update` (or `update-input <name>`); commit the resulting `flake.lock`.
- **No secrets in Nix:** the store is world-readable. Secrets via `sops-nix`/`agenix` or runtime env — never literals in `.nix`.

## Important Notes

- **Flakes ignore untracked files.** A new `.nix` not yet `git add`ed is invisible to `nix flake check` and fails with confusing "file not found" / stale-eval errors. ALWAYS `git add` before evaluating — enforced by [git-purity](.claude/rules/git-purity.md) and the Stop hook.
- Nix is frequently absent on the host (configs are evaluated in their target environments / CI). If `nix` is unavailable, validate syntax with `nix-instantiate --parse` where possible and rely on the platform-compiler agent + CI for full eval. The SessionStart hook reports which mode you're in. Full multi-system evaluation lands in `.github/workflows/flake-check.yml` — never report a config as passing on a system only CI evaluated.
- Prefer the `/eval` and `/update-input` commands over retyping the stage→check→evaluate sequence by hand.
- `home-manager switch` activates and is hard to reverse; prefer `build` to verify, and `switch` only when explicitly asked. List generations with `home-manager generations`; roll back with `home-manager rollback`.
- Run `nix flake check` (all systems) before declaring any change done — a config that evaluates on darwin can still break `aarch64-linux`.
