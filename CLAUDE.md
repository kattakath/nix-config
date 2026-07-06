# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

All-in-one Nix mono-repo managing a fully declarative, 3-host **aarch64-only** fleet: **macOS/nix-darwin (`macos`, aarch64-darwin — the sole client Mac, no remote/incoming traffic)**, **NixOS Raspberry Pi 4 (`nixpi`, aarch64-linux — the LIVE server: SSH over a Cloudflare Tunnel connector + Caddy serving the kattakath.com static landing page)**, and **NixOS UTM/QEMU sandbox VM (`nixvm`, aarch64-linux — minimal, no public ingress, GUI/remote-desktop deferred)**, plus a matching **Devcontainer** image. Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## Build / Test / Lint

```bash
git add -A                                   # MANDATORY before any eval — flakes ignore untracked files
nix flake check                              # Evaluate every output + formatting/lint/pre-commit checks (the test suite)
nix flake show                               # List exported darwinConfigurations + nixosConfigurations + packages
nix fmt                                       # Format + lint-fix all .nix via treefmt (nixfmt + statix + deadnix)
nix develop                                   # Enter dev shell (nixd LSP, treefmt, home-manager); installs pre-commit hooks
nix build .#checks.<system>.formatting        # CI formatting/lint gate (fails on unformatted/lintable files)
darwin-rebuild switch --flake .#macos        # Activate the macOS (nix-darwin) config (Apple Silicon)
nixos-rebuild switch --flake .#nixpi         # Activate the Raspberry Pi config (LIVE server)
nixos-rebuild switch --flake .#nixvm         # Activate the UTM/QEMU sandbox VM config
nix eval .#nixosConfigurations.nixpi.config.system.build.toplevel   # Evaluate a SINGLE config (fast single-target check)
nix build .#nixosConfigurations.nixpi.config.system.build.sdImage  # Build the flashable Pi SD image
nix build .#nixvm-image                       # Build UTM-importable nixvm qcow2 → ./result/
nix run .#nixvm                               # disko-install bootstrap for nixvm — run FROM the live installer ISO, not from macOS
```

## Architecture

- `flake.nix` — entry point: pins `nixpkgs` + `nix-darwin` + `home-manager` + `treefmt-nix` + `git-hooks` + `disko` + `raspberry-pi-nix` + `nix-vscode-extensions` + `nix-homebrew` inputs; exports `darwinConfigurations."macos"` (aarch64-darwin), `nixosConfigurations."nixpi"` / `"nixvm"` (aarch64-linux) plus `"nixpi-installer"` / `"nixvm-installer"`, and `packages`/`devShells`/`checks`/`formatter` per system via a `forAllSystems` helper. Exactly **two systems**: `aarch64-darwin` and `aarch64-linux` — no x86_64 anywhere, including the devcontainer. Identity (`userName = "ismail"`, `domainName = "kattakath.com"`, `fullName`, `handleName`) is defined once as `let` bindings and threaded through `specialArgs`/`extraSpecialArgs`.
- `flake.lock` — pinned input revisions; commit every change, never hand-edit.
- `treefmt.nix` — single source of truth for formatting + lint-fix (nixfmt + statix + deadnix). Drives `nix fmt`, the `checks.formatting` CI gate, and the pre-commit hook — change a tool here and every entrypoint follows.
- The devShell is entered with `nix develop` (in the devcontainer or on a nix host). There is no `.envrc`/direnv auto-load — run `nix develop` explicitly.
- `hosts/` — per-host entry profiles: `macos.nix` (darwin client), `nixpi.nix` (Pi 4, LIVE — boot fixes + cloudflared + caddy-proxy), `nixpi-installer.nix` (SD installer), `nixvm.nix` (UTM/QEMU sandbox — UEFI, VirtIO, disko, serial console, no GUI yet), `nixvm-installer.nix` (ISO installer).
- `modules/` — reusable modules split by platform:
  - `modules/shared/{home.nix,nix-cache.nix,nix-ld-libraries.nix}` — Home Manager profile loaded on every host (git/ssh-signing, zsh+starship, direnv, gh, bash, claude-code + nerd-fonts; darwin-only ssh/vscode blocks gated `lib.mkIf pkgs.stdenv.isDarwin`); the Cachix binary-cache option; the shared nix-ld library list.
  - `modules/darwin/{core.nix,homebrew.nix,nix-homebrew.nix,screengrab-rotate.nix}` — macOS system defaults (dock/finder/NSGlobalDomain, Touch ID for sudo, `stateVersion = 5`), declarative Homebrew (lean brew/cask list, `cleanup = "uninstall"`), Homebrew-itself install via `nix-homebrew`.
  - `modules/linux/nix-ld.nix` — Home-Manager nix-ld shim; inert on NixOS (which owns nix-ld natively via `modules/nixos/core.nix`), fires only for standalone HM on non-NixOS Linux.
  - `modules/nixos/core.nix` — shared NixOS baseline: the `ismail` user + authorized SSH key, keys-only sshd (no password, no root login), firewall (TCP 22, UDP 5353 for mDNS), avahi `<host>.local` publishing, native `programs.nix-ld`, zram swap, automatic GC.
  - `modules/nixos/cloudflared.nix` — opt-in `services.cloudflared-connector.enable` (default false); hardened `systemd.services.cloudflared-connector` running a **remotely-managed (token)** Cloudflare Tunnel — no `cloudflared tunnel login`, no cert.pem. Token read from `tokenFile` (default `/etc/secrets/cloudflared-token`), placed manually after provisioning, never in git; an activation script warns (doesn't abort) if absent. Only `nixpi` enables it.
  - `modules/nixos/caddy-proxy.nix` — opt-in `services.caddy-proxy`, a thin wrapper around upstream `services.caddy` with a declarative `virtualHosts` attrset (each entry is either `reverseProxyTo` an upstream URL or a static `root`). Sits **behind** the Cloudflare Tunnel (tunnel → Caddy → service), so no public IP/port-forward is needed. Only `nixpi` enables it, today serving just the static `kattakath.com` landing page (`packages/landing`).
  - Platform branching lives HERE behind `lib.mkIf`, not duplicated across hosts.
- `packages/` — `devcontainer-image.nix` (aarch64-only devcontainer OCI image, `dockerTools.streamLayeredImage`, published to GHCR), `nixvm.nix` (the `nix run .#nixvm` disko-install bootstrap script for the sandbox VM), `landing/index.html` (the static `kattakath.com` landing page served by `nixpi`'s Caddy).
- `.claude/agents/platform-compiler.md` — subagent that validates evaluation across both target systems.
- `.claude/agents/nix-researcher.md` — read-only research/root-cause subagent (locate options, trace value flow across `flake.nix`/`hosts/`/`modules/`, diagnose failures, look up upstream option semantics).
- `.claude/agents/ci-release-driver.md` — subagent that owns the push→CI→iterate→merge loop against the Nix CI workflow (never merges without approval).
- `.claude/commands/` — `/eval`, `/update-input`, `/superhook-review` (triage the hook-supervisor log), `/remember-nix` (capture into project memory).
- `.claude/rules/git-purity.md` — always-applied rule: stage `.nix` files before eval.
- `.claude/hooks/` — `stop-gate.js` (Stop gate: blocks until configs evaluate clean) and `delegate-team.js` (UserPromptSubmit orchestration policy), both wrapped by `superhook.js` (crash-safety + loop-breaking + logging); plus `superhook-digest.js` and `memory-loader.js` (SessionStart context surfacing) and `autostage-nix.js` (PostToolUse git-purity net).
- `.mcp.json` — project-scoped MCP servers for Claude Code in this repo (`context7`, `duckduckgo`, `fetch`, `sequentialthinking`, `memory`, `json-yaml-toml`, `mcp-jq`, `desktop-commander`, plus `cloudflare-docs` and `cloudflare`). Public URLs only; OAuth tokens cache per-machine in `~/.mcp-auth` (`cloudflare` needs a one-time browser login and fails gracefully headless).
- `.claude/skills/` — vendored/authored agent skills (`cloudflare-one`, `cloudflared-tunnel`, `nixos-flake-install`, `utm-vm-provision`, `nixvm-utm-prebuild-on-devcontainer`), pinned by `skills-lock.json` where vendored.
- `memory/` — **gitignored** project memory (decisions/findings/values/evolution): the candid "why" behind the repo, surfaced each session by `memory-loader.js`. Never `git add`.
- `.github/workflows/nix-ci.yml` — 2-leg Nix CI on GitHub Actions: one leg per target system on its native runner (`ubuntu-24.04-arm` for aarch64-linux — evaluates `nixpi`+`nixvm`+both installers; `macos-latest` for aarch64-darwin — evaluates `macos`). Each leg *builds* the lint/format `checks` with `nix-fast-build` (pushed to the `ismailkattakath` Cachix cache) and *evaluates* (no build) its host config toplevel(s). Building host toplevels is deferred to release time. Branch protection requires the aggregate `required-checks` job. (`.github/workflows/` also keeps `build-devcontainer.yml`, `build-installers.yml`, `claude*.yml`, and `gitleaks.yml`.)

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
- **Systems:** the two target systems are `aarch64-darwin` and `aarch64-linux`. Every new output must evaluate on both or be explicitly gated.
- **Inputs:** bump only via `nix flake update` (or `update-input <name>`); commit the resulting `flake.lock`.
- **No secrets in Nix:** the store is world-readable. System/service credentials (the Cloudflare tunnel token) live at `/etc/secrets/<name>` on `nixpi` — a plain, root-only, operator-placed file, placed manually after provisioning, **never committed to git**. There is no agenix, no sops, no encryption step in this repo (removed entirely) — `/etc/secrets/cloudflared-token` is the only such file today. The connector's activation script warns (doesn't abort) at switch time if it's absent; the unit itself retries on failure, so dropping the file in after first boot self-heals without a rebuild. **Personal tokens** live in the macOS login Keychain (exported by host-local `~/.zprofile`) or via one-time CLI logins (`gh`/`hf`/`docker`/`claude`). Never literals in `.nix`.
- **Binary cache (Cachix):** the public `ismailkattakath` cache is consumed by every host (`modules/shared/nix-cache.nix`, wired in via the flake's module lists) and the devcontainer. Read is public — only the substituter URL + public key, NO token on any consumer. The write credential `CACHIX_AUTH_TOKEN` is a **GitHub Actions secret only** (used by `cachix/cachix-action` in `nix-ci.yml`, `build-devcontainer.yml`, and `build-installers.yml` to push build closures); never in Nix, git, or any consumer.

## Important Notes

- **Flakes ignore untracked files.** A new `.nix` not yet `git add`ed is invisible to `nix flake check` and fails with confusing "file not found" / stale-eval errors. ALWAYS `git add` before evaluating — enforced by [git-purity](.claude/rules/git-purity.md) and the Stop hook.
- Nix is frequently absent on the host (configs are evaluated in their target environments / CI). If `nix` is unavailable, validate syntax with `nix-instantiate --parse` where possible and rely on the platform-compiler agent + CI for full eval. The SessionStart hook reports which mode you're in. Full two-system evaluation lands in GitHub Actions CI (`.github/workflows/nix-ci.yml`) — never report a config as passing on a system only CI evaluated.
- Prefer the `/eval` and `/update-input` commands over retyping the stage→check→evaluate sequence by hand.
- `home-manager switch` activates and is hard to reverse; prefer `build` to verify, and `switch` only when explicitly asked. List generations with `home-manager generations`; roll back with `home-manager rollback`.
- Run `nix flake check` (both systems) before declaring any change done — a config that evaluates on one system can still break the other.
- `nix run .#nixvm` is the **destructive disko-install bootstrap** for the sandbox VM (run from the live installer ISO on the VM itself) — it is not a way to launch or boot an already-built qcow2 image from macOS. This fleet has no bespoke QEMU+HVF launcher app; UTM is the supported way to run `nixvm` on macOS (see the **utm-vm-provision** skill).

## Documentation

- [`docs/tunnel-architecture-and-runbook.md`](docs/tunnel-architecture-and-runbook.md) — the loginless remotely-managed (token) Cloudflare Tunnel design for `nixpi` (the fleet's sole SSH target and only public-facing host): the connector unit, Caddy-behind-the-tunnel topology, the plain `/etc/secrets/cloudflared-token` model, the `<host>.local` (mDNS) + `nixpi.kattakath.com` two-name model, the runbook to bring `nixpi` online, and a note on where Cloudflare One is headed next (MCP tool aggregation — the reason the old LiteLLM proxy container path was dropped).
- [`docs/cloudflare-one-evaluation.md`](docs/cloudflare-one-evaluation.md) — evaluation of Cloudflare One Zero Trust Infrastructure Access (short-lived SSH certs) as an alternative to the current static-key SSH model, and the decision **not to adopt** at current solo/3-host scale (keep the loginless key model). Includes the "keys to reach my stuff vs tokens for other people's stuff" model, the resource plan + NixOS change if ever revisited, the revisit triggers, and open flags to verify live. This ZTIA-for-SSH decision is separate from the MCP-aggregation direction noted above.
