# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

All-in-one Nix mono-repo managing fully declarative environments across **macOS/nix-darwin (`silicon`)**, **NixOS VM (`nixbox`, aarch64-linux — UTM/QEMU `virt`)**, **NixOS Raspberry Pi 4 (`nixrpi`, aarch64-linux)**, and **Devcontainers**. Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## Build / Test / Lint

```bash
git add -A                                   # MANDATORY before any eval — flakes ignore untracked files
nix flake check                              # Evaluate every output + formatting/lint/pre-commit checks (the test suite)
nix flake show                               # List exported darwinConfigurations + nixosConfigurations + packages
nix fmt                                       # Format + lint-fix all .nix via treefmt (nixfmt + statix + deadnix)
nix develop                                   # Enter dev shell (nixd LSP, treefmt, home-manager); installs pre-commit hooks
nix build .#checks.<system>.formatting        # CI formatting/lint gate (fails on unformatted/lintable files)
nixos-rebuild switch --flake .#nixbox         # Activate the NixOS VM config (aarch64 UTM/QEMU)
nixos-rebuild switch --flake .#nixrpi         # Activate the Raspberry Pi config
darwin-rebuild switch --flake .#silicon       # Activate the macOS (nix-darwin) config
nix eval .#nixosConfigurations.nixbox.config.system.build.toplevel   # Evaluate a SINGLE config (fast single-target check)
nix build .#nixbox-image                  # Build UTM-importable nixbox qcow2 → ./result/ (requires aarch64-linux builder)
nix run .#nixbox-vm                       # Boot nixbox in QEMU + HVF on macOS — no UTM needed (set NIXBOX_DISK= or copy qcow2 first)
```

## Architecture

- `flake.nix` — entry point: pins `nixpkgs` + `home-manager` + `nix-darwin` + `raspberry-pi-nix` + `agenix` + `treefmt-nix` + `git-hooks` inputs; exports `darwinConfigurations."silicon"` (aarch64-darwin), `nixosConfigurations."nixbox"` (aarch64-linux) and `"nixrpi"` (aarch64-linux), `apps.aarch64-darwin.nixbox-vm` (QEMU+HVF launcher, no UTM needed), plus `packages`/`devShells`/`checks`/`formatter` per system via a `forAllSystems` helper. Username is `izzy`, defined once as a `let` binding.
- `flake.lock` — pinned input revisions; commit every change, never hand-edit.
- `treefmt.nix` — single source of truth for formatting + lint-fix (nixfmt + statix + deadnix). Drives `nix fmt`, the `checks.formatting` CI gate, and the pre-commit hook — change a tool here and every entrypoint follows.
- The devShell is entered with `nix develop` (in the devcontainer or on a nix host). There is no `.envrc`/direnv auto-load — it was removed; run `nix develop` explicitly.
- `hosts/` — per-host entry profiles (`silicon.nix`, `nixbox.nix`, `nixrpi.nix`); composed by the flake's `darwinConfigurations`/`nixosConfigurations`.
- `modules/` — reusable modules split by platform: `modules/darwin/core.nix`, `modules/linux/nix-ld.nix`, `modules/shared/home.nix`, `modules/nixos/core.nix`, `modules/nixos/cloudflared.nix` (the `services.hostTunnel` module). Platform branching lives HERE behind `lib.mkIf`, not duplicated across hosts.
- `packages/docker-image.nix` — minimal runtime container image (`dockerTools`, baseless).
- `.claude/agents/platform-compiler.md` — subagent that validates evaluation across all three architectures.
- `.claude/agents/vm-provisioner.md` — subagent that drives the full macOS→UTM→NixOS provisioning pipeline (VM creation, NixOS install, agenix rekey, Cloudflare tunnel).
- `.claude/agents/nix-researcher.md` — read-only research/root-cause subagent (locate options, trace value flow across `flake.nix`/`hosts/`/`modules/`, diagnose failures, look up upstream option semantics).
- `.claude/agents/ci-release-driver.md` — subagent that owns the push→CI→iterate→merge loop against `flake-check.yml` (never merges without approval).
- `.claude/commands/` — `/eval`, `/update-input`, `/superhook-review` (triage the hook-supervisor log), `/remember-nix` (capture into project memory).
- `.claude/rules/git-purity.md` — always-applied rule: stage `.nix` files before eval.
- `.claude/hooks/` — `stop-gate.js` (Stop gate: blocks until configs evaluate clean) and `delegate-team.js` (UserPromptSubmit orchestration policy), both wrapped by `superhook.js` (crash-safety + loop-breaking + logging); plus `superhook-digest.js` and `memory-loader.js` (SessionStart context surfacing) and `autostage-nix.js` (PostToolUse git-purity net).
- `memory/` — **gitignored** project memory (decisions/findings/values/evolution): the candid "why" behind the repo, surfaced each session by `memory-loader.js`. Never `git add`.
- `.github/workflows/flake-check.yml` — CI matrix evaluating all three systems (aarch64-linux via QEMU) + lint; this is where the locally-deferred full `nix flake check` actually runs.

### Orchestration model

This repo operates **orchestrator-first**. The main agent is a decision-maker, not the worker:

- **Delegate substantive work.** Any multi-step task, cross-file change, research, or root-cause investigation is decomposed and handed to background expert subagents (`Agent` tool, `run_in_background: true`), picking the fitting `subagent_type` per piece and launching independent pieces concurrently in one message. Only trivial replies and one-line edits are done inline.
- **Delegation is recursive.** Subagents may form their own sub-hierarchies — a delegated agent whose slice is itself substantive spawns its own background sub-team.
- **Never idle-wait.** If the main agent is waiting on a background agent, that is the signal it should have delegated the next piece; it stays free to accept work and react to agent interrupts/completions (`SendMessage` to continue a specific agent).
- **Watchdog duty.** Auto-notification is the primary channel but is not guaranteed, so every agent with children (including the main one) runs a backup periodic health-check — a long fallback heartbeat (~1200–1800s wakeup or a `Monitor` until-loop), not tight polling. Each check lets healthy children run, reaps any that finished silently, and stops/kills (`TaskStop`) any hung, stuck, or looping child; reschedule while children remain active, stop once all are done.
- **Enforced by the hook.** `.claude/hooks/delegate-team.js` (UserPromptSubmit, wrapped by `superhook.js`) injects this policy every turn — it is the source of truth for the operating mode. Reusable expert agents live in `.claude/agents/`.

## Conventions

- **Naming:** kebab-case files; `lowerCamelCase` Nix bindings; modules named by the platform/concern they own.
- **Platform branching:** isolate in `modules/` via `lib.mkIf` on `stdenv.hostPlatform`/`isDarwin`/`isLinux` — host profiles stay declarative and platform-agnostic.
- **Systems:** the canonical triple is `aarch64-darwin`, `x86_64-linux`, `aarch64-linux`. Every new output must evaluate on all three or be explicitly gated.
- **Inputs:** bump only via `nix flake update` (or `update-input <name>`); commit the resulting `flake.lock`.
- **No secrets in Nix:** the store is world-readable. Secrets split by consumer: **system/service** creds (e.g. the cloudflared tunnel cred) use **agenix**, host-key scoped, decrypted at boot; **personal tokens** are NOT in Nix or git — they live in the macOS login Keychain (exported by host-local `~/.zprofile`) or via one-time CLI logins (`gh`/`hf`/`docker`). agenix was dropped for personal secrets to avoid version-control churn on rotation. Never literals in `.nix`. See `secrets/README`.
- **Binary cache (Cachix):** the public `ismailkattakath` cache is consumed by every host (`modules/shared/nix-cache.nix`, wired in via the flake's module lists) and the devcontainer (`CACHIX_CACHE` build arg). Read is public — only the substituter URL + public key, NO token on any consumer. The write credential `CACHIX_AUTH_TOKEN` is a **GitHub Actions secret only** (used by `cachix/cachix-action` in `flake-check.yml` to push the per-system devShell closures); never in Nix, git, or any consumer.

## Important Notes

- **Flakes ignore untracked files.** A new `.nix` not yet `git add`ed is invisible to `nix flake check` and fails with confusing "file not found" / stale-eval errors. ALWAYS `git add` before evaluating — enforced by [git-purity](.claude/rules/git-purity.md) and the Stop hook.
- Nix is frequently absent on the host (configs are evaluated in their target environments / CI). If `nix` is unavailable, validate syntax with `nix-instantiate --parse` where possible and rely on the platform-compiler agent + CI for full eval. The SessionStart hook reports which mode you're in. Full multi-system evaluation lands in `.github/workflows/flake-check.yml` — never report a config as passing on a system only CI evaluated.
- Prefer the `/eval` and `/update-input` commands over retyping the stage→check→evaluate sequence by hand.
- `home-manager switch` activates and is hard to reverse; prefer `build` to verify, and `switch` only when explicitly asked. List generations with `home-manager generations`; roll back with `home-manager rollback`.
- Run `nix flake check` (all systems) before declaring any change done — a config that evaluates on darwin can still break `aarch64-linux`.
