# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

All-in-one Nix mono-repo managing fully declarative environments across **macOS/nix-darwin (`nixcon`, aarch64-darwin; `nixtel`, x86_64-darwin — Apple Intel)**, **NixOS VM (`nixarm`, aarch64-linux — UTM/QEMU `virt`)**, **NixOS x86_64 host (`nixamd`, x86_64-linux — config-only / CI-eval)**, **NixOS Raspberry Pi 4 (`nixrpi`, aarch64-linux)**, and **Devcontainers**. Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## Build / Test / Lint

```bash
git add -A                                   # MANDATORY before any eval — flakes ignore untracked files
nix flake check                              # Evaluate every output + formatting/lint/pre-commit checks (the test suite)
nix flake show                               # List exported darwinConfigurations + nixosConfigurations + packages
nix fmt                                       # Format + lint-fix all .nix via treefmt (nixfmt + statix + deadnix)
nix develop                                   # Enter dev shell (nixd LSP, treefmt, home-manager); installs pre-commit hooks
nix build .#checks.<system>.formatting        # CI formatting/lint gate (fails on unformatted/lintable files)
nixos-rebuild switch --flake .#nixarm         # Activate the NixOS VM config (aarch64 UTM/QEMU)
nixos-rebuild switch --flake .#nixamd         # Activate the NixOS x86_64 host config
nixos-rebuild switch --flake .#nixrpi         # Activate the Raspberry Pi config
darwin-rebuild switch --flake .#nixcon       # Activate the macOS (nix-darwin) config (Apple Silicon)
darwin-rebuild switch --flake .#nixtel       # Activate the Intel macOS config (Apple Intel)
nix eval .#nixosConfigurations.nixarm.config.system.build.toplevel   # Evaluate a SINGLE config (fast single-target check)
nix build .#nixarm-image                  # Build UTM-importable nixarm qcow2 → ./result/ (requires aarch64-linux builder)
nix run .#nixarm-vm                       # Boot nixarm in QEMU + HVF on macOS — no UTM needed (set NIXARM_DISK= or copy qcow2 first)
```

## Architecture

- `flake.nix` — entry point: pins `nixpkgs` + `home-manager` + `nix-darwin` + `raspberry-pi-nix` + `agenix` + `treefmt-nix` + `git-hooks` inputs; exports `darwinConfigurations."nixcon"` (aarch64-darwin) + `"nixtel"` (x86_64-darwin), `nixosConfigurations."nixarm"` (aarch64-linux), `"nixamd"` (x86_64-linux) and `"nixrpi"` (aarch64-linux), `apps.aarch64-darwin.nixarm-vm` (QEMU+HVF launcher, no UTM needed), plus `packages`/`devShells`/`checks`/`formatter` per system via a `forAllSystems` helper. Username is `izzy`, defined once as a `let` binding.
- `flake.lock` — pinned input revisions; commit every change, never hand-edit.
- `treefmt.nix` — single source of truth for formatting + lint-fix (nixfmt + statix + deadnix). Drives `nix fmt`, the `checks.formatting` CI gate, and the pre-commit hook — change a tool here and every entrypoint follows.
- The devShell is entered with `nix develop` (in the devcontainer or on a nix host). There is no `.envrc`/direnv auto-load — it was removed; run `nix develop` explicitly.
- `hosts/` — per-host entry profiles (`nixcon.nix`, `nixtel.nix`, `nixarm.nix`, `nixamd.nix`, `nixrpi.nix`); composed by the flake's `darwinConfigurations`/`nixosConfigurations`.
- `modules/` — reusable modules split by platform: `modules/darwin/core.nix`, `modules/darwin/cloudflared.nix` (macOS boot-time loginless Cloudflare TOKEN connector via `launchd`; token read from a `0600 root:wheel` file, imported by `hosts/nixcon.nix`/`hosts/nixtel.nix`), `modules/linux/nix-ld.nix`, `modules/shared/home.nix`, `modules/nixos/core.nix`, `modules/nixos/cloudflared.nix` (NixOS boot-time loginless Cloudflare TOKEN connector as a hardened `systemd.services.cloudflared-connector`; token via agenix `EnvironmentFile`, NOT `services.cloudflared` upstream which has no token support; a no-op on hosts that don't declare `age.secrets."<host>-tunnel-token"`). Per-host tunnels/ingress/DNS live in the Cloudflare account, provisioned by `scripts/cf-one-provision.sh`. Platform branching lives HERE behind `lib.mkIf`, not duplicated across hosts.
- `packages/` — `docker-image.nix` (minimal baseless runtime image, `dockerTools`), `devcontainer-image.nix` (multi-arch devcontainer image, Linux-only, published to GHCR), `nixarm-vm.nix` (QEMU+HVF launcher). The `nixarm-image` qcow2 is derived inline in `flake.nix`, not a file here.
- `.claude/agents/platform-compiler.md` — subagent that validates evaluation across all four target systems.
- `.claude/agents/vm-provisioner.md` — subagent that drives the full macOS→UTM→NixOS provisioning pipeline (VM creation, NixOS install, agenix rekey, Cloudflare tunnel).
- `.claude/agents/nix-researcher.md` — read-only research/root-cause subagent (locate options, trace value flow across `flake.nix`/`hosts/`/`modules/`, diagnose failures, look up upstream option semantics).
- `.claude/agents/ci-release-driver.md` — subagent that owns the push→CI→iterate→merge loop against the Nix CI workflow (never merges without approval).
- `.claude/commands/` — `/eval`, `/update-input`, `/superhook-review` (triage the hook-supervisor log), `/remember-nix` (capture into project memory).
- `.claude/rules/git-purity.md` — always-applied rule: stage `.nix` files before eval.
- `.claude/hooks/` — `stop-gate.js` (Stop gate: blocks until configs evaluate clean) and `delegate-team.js` (UserPromptSubmit orchestration policy), both wrapped by `superhook.js` (crash-safety + loop-breaking + logging); plus `superhook-digest.js` and `memory-loader.js` (SessionStart context surfacing) and `autostage-nix.js` (PostToolUse git-purity net).
- `.mcp.json` — project-scoped MCP servers for Claude Code in this repo (`context7`, `duckduckgo`, `fetch`, `sequentialthinking`, `memory`, `json-yaml-toml`, `mcp-jq`, `desktop-commander`, plus `cloudflare-docs` and `cloudflare`). Public URLs only; OAuth tokens cache per-machine in `~/.mcp-auth` (`cloudflare` needs a one-time browser login and fails gracefully headless).
- `.claude/skills/` — vendored agent skills (e.g. `cloudflare-one`), pinned by `skills-lock.json`.
- `memory/` — **gitignored** project memory (decisions/findings/values/evolution): the candid "why" behind the repo, surfaced each session by `memory-loader.js`. Never `git add`.
- `.github/workflows/nix-ci.yml` — multi-system Nix CI on GitHub Actions: a native per-host matrix (`ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-15-intel`, `macos-latest`) that *builds* the lint/format `checks` with `nix-fast-build` (pushed to the `ismailkattakath` Cachix cache) and *evaluates* (no build) each host config's toplevel; this is where the locally-deferred full multi-system evaluation actually runs. Building the host toplevels is deferred to release time. Branch protection requires the aggregate `required-checks` job. (`.github/workflows/` also keeps `build-devcontainer.yml`, `claude*.yml`, and `gitleaks.yml`.)

### Orchestration model

This repo operates **orchestrator-first**. The main agent is a decision-maker, not the worker:

- **Delegate substantive work.** Any multi-step task, cross-file change, research, or root-cause investigation is decomposed and handed to background expert subagents (`Agent` tool, `run_in_background: true`), picking the fitting `subagent_type` per piece and launching independent pieces concurrently in one message. Only trivial replies and one-line edits are done inline.
- **Delegation is recursive.** Subagents may form their own sub-hierarchies — a delegated agent whose slice is itself substantive spawns its own background sub-team.
- **Never idle-wait.** If the main agent is waiting on a background agent, that is the signal it should have delegated the next piece; it stays free to accept work and react to agent interrupts/completions (`SendMessage` to continue a specific agent).
- **Watchdog duty.** Auto-notification is the primary channel but is not guaranteed, so every agent with children (including the main one) runs a backup periodic health-check — a long fallback heartbeat (~1200–1800s wakeup or a `Monitor` until-loop), not tight polling. Each check lets healthy children run, reaps any that finished silently, and stops/kills (`TaskStop`) any hung, stuck, or looping child; reschedule while children remain active, stop once all are done. Reason about a child's *actual* current state, not its last-known/stale self-report — a dormant-completed child can re-emit stale notifications.
- **Reap before exit.** Never finish with a live child: reap it (wait and process, or `TaskStop` if moot) or hand off — never orphan. Grandchildren report to their immediate parent, not the top orchestrator, so the parent owns their full lifecycle; a parent that exits with a live child leaves an unsupervisable orphan nobody can reap. If a child genuinely can't be reaped, surface its id/label in the final report.
- **Enforced by the hook.** `.claude/hooks/delegate-team.js` (UserPromptSubmit, wrapped by `superhook.js`) injects this policy every turn — it is the source of truth for the operating mode. Reusable expert agents live in `.claude/agents/`.

## Conventions

- **Naming:** kebab-case files; `lowerCamelCase` Nix bindings; modules named by the platform/concern they own.
- **Platform branching:** isolate in `modules/` via `lib.mkIf` on `stdenv.hostPlatform`/`isDarwin`/`isLinux` — host profiles stay declarative and platform-agnostic.
- **Systems:** the four target systems are `aarch64-darwin`, `x86_64-darwin`, `x86_64-linux`, `aarch64-linux`. Every new output must evaluate on all four or be explicitly gated.
- **Inputs:** bump only via `nix flake update` (or `update-input <name>`); commit the resulting `flake.lock`.
- **No secrets in Nix:** the store is world-readable. Secrets split by consumer: **system/service** creds (e.g. the per-host cloudflared connector token `<host>-tunnel-token.age`, one line `TUNNEL_TOKEN=…`) use **agenix**, host-key scoped, decrypted at boot and fed to `cloudflared` via `EnvironmentFile` (never argv/store); on macOS there is no agenix, so the token is a `0600 root:wheel` file read by the launchd wrapper. **personal tokens** are NOT in Nix or git — they live in the macOS login Keychain (exported by host-local `~/.zprofile`) or via one-time CLI logins (`gh`/`hf`/`docker`). agenix was dropped for personal secrets to avoid version-control churn on rotation. Never literals in `.nix`. See `secrets/README`.
- **Binary cache (Cachix):** the public `ismailkattakath` cache is consumed by every host (`modules/shared/nix-cache.nix`, wired in via the flake's module lists) and the devcontainer (`CACHIX_CACHE` build arg). Read is public — only the substituter URL + public key, NO token on any consumer. The write credential `CACHIX_AUTH_TOKEN` is a **GitHub Actions secret only** (used by `cachix/cachix-action` in `nix-ci.yml` and `build-devcontainer.yml` to push build closures); never in Nix, git, or any consumer.

## Important Notes

- **Flakes ignore untracked files.** A new `.nix` not yet `git add`ed is invisible to `nix flake check` and fails with confusing "file not found" / stale-eval errors. ALWAYS `git add` before evaluating — enforced by [git-purity](.claude/rules/git-purity.md) and the Stop hook.
- Nix is frequently absent on the host (configs are evaluated in their target environments / CI). If `nix` is unavailable, validate syntax with `nix-instantiate --parse` where possible and rely on the platform-compiler agent + CI for full eval. The SessionStart hook reports which mode you're in. Full multi-system evaluation lands in GitHub Actions CI (`.github/workflows/nix-ci.yml`) — never report a config as passing on a system only CI evaluated.
- Prefer the `/eval` and `/update-input` commands over retyping the stage→check→evaluate sequence by hand.
- `home-manager switch` activates and is hard to reverse; prefer `build` to verify, and `switch` only when explicitly asked. List generations with `home-manager generations`; roll back with `home-manager rollback`.
- Run `nix flake check` (all systems) before declaring any change done — a config that evaluates on one system can still break another.
