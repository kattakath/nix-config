This is `kattakath/nix-config` — the all-in-one, public Nix mono-repo that declaratively
manages Ismail's entire aarch64-only fleet: one client Mac, one live Raspberry Pi server, a
Tart macOS guest, a throwaway NixOS dev VM, and a devcontainer image. Everything below is
guidance for Claude Code (claude.ai/code) when working in this repository.

# CLAUDE.md

**This file is an index, not an encyclopedia.** It stays scannable and under the 40k-char
context lint limit; the full per-path detail lives in [`docs/repo-map.md`](docs/repo-map.md).
When you change repo shape, update the one-liner here **and** the section there.

## Overview

Fully declarative **aarch64-only** fleet, single source of truth, platform divergence in
`modules/` (never ad-hoc shell):

| Host | System | Role |
|---|---|---|
| `macos` | aarch64-darwin | The sole client Mac (nix-darwin). No incoming traffic; it is the SSH *client*, reaching `nixpi` via `cloudflared access ssh`. Builds `aarch64-linux` locally on Determinate's native Linux builder. |
| `nixpi` | aarch64-linux | **LIVE server** (NixOS on a Pi 4): static-key SSH over a Cloudflare Tunnel connector + Caddy. **Site-free in this public repo** — real sites + dontsell.ai's second connector come from the private nix-personal flake ([`docs/private-home-modules.md`](docs/private-home-modules.md)). |
| `macvm` | aarch64-darwin | Tart guest on Apple Virtualization; macos's stack minus the MCP gateway and desktop aesthetics, leaner Homebrew, activated *inside* the VM under the same operator identity. |
| `nixvm` | aarch64-linux | Throwaway XFCE build-vm, materialised **only** as `nix run .#nixvm`. No installed disk, no builder, no runner. |
| devcontainer | +`x86_64-linux` | The one exception to aarch64-only, so it runs on x86_64 Codespaces. |

Full map: [`docs/repo-map.md`](docs/repo-map.md).

## Build & Commands

```bash
git add -A                                   # MANDATORY before any eval — flakes ignore untracked files
nix flake check                              # Evaluate every output + formatting/lint/pre-commit checks (the test suite)
nix flake show                               # List exported darwin/nixosConfigurations + packages
nix fmt                                      # Format + lint-fix all .nix via treefmt (nixfmt + statix + deadnix)
nix develop                                  # Dev shell (nixd LSP, treefmt, home-manager); installs pre-commit hooks
nix build .#checks.<system>.formatting       # CI formatting/lint gate
nix build .#checks.<system>.ast-grep         # Structural-lint gate (report-only; rules in ast-grep/rules/)
ast-grep scan --no-ignore hidden .           # Same scan by hand (devShell); --no-ignore hidden or .claude/ is SKIPPED
ast-grep test --skip-snapshot-tests          # Prove each rule still fires (fixtures in ast-grep/rule-tests/)
# Agent hygiene (LEAN/DRY/docs drift → fix → fmt → check): /hygiene  or skill nix-hygiene

# Activation
darwin-rebuild switch --flake .#macos        # ⚠ NEVER run this from THIS repo for a real switch — it silently
                                             #   drops the private nix-personal layer. Use `activate`, or ask first.
nix run github:kattakath/nix-config#macos    # FIRST activation of macos straight from the flake (before darwin-rebuild is on PATH)
nixos-rebuild switch --flake .#nixpi         # Activate the Pi (LIVE server — must pass CI/Cachix first, never build heavy on the Pi)
deploy --targets .#nixpi                     # ⚠ Same trap as above: from THIS repo it deploys a SITE-FREE Pi. Deploy from
                                             #   nix-personal. deploy-rs w/ magicRollback: an unreachable Pi auto-reverts
                                             #   instead of needing a physical SD-card pull. ALWAYS --targets (bare `deploy`
                                             #   fans out over every node). --dry-activate to rehearse.
nix run .#nixvm                              # Build + boot the throwaway nixvm XFCE build-vm in a native QEMU window
nix eval .#nixosConfigurations.nixpi.config.system.build.toplevel   # Fast single-target eval

# Bootstrap a clean/reset Mac (no Nix yet): install Determinate Nix, then hand off to key-recover —
# restores from an iCloud kit if present, else FOUNDS a fresh operator identity.
# `| bash -s -- --check` for a dry run; `--fresh` skips the confirm. See docs/mac-key-recovery-runbook.md
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash

# nixpi SD card
nix build .#nixosConfigurations.nixpi.config.system.build.sdImage   # aarch64-linux; builds on the native Linux builder, or use --release
nix run .#nixpi-flash -- --disk /dev/diskN --release   # Download the CI-prebuilt image → verified dd → auto-plant token+wifi on FIRMWARE
nix run .#nixpi-provision                     # Plant/update token + Wi-Fi on a mounted card (--token / --wifi)
# Flashing: do a FULL verified write (confirm dd's ~5.6GB byte count) — see docs/nixpi-sd-flashing-runbook.md
# Companions: nixpi-wifi-creds (emit wpa_supplicant.conf from this Mac), nixpi-vault-token (re-encrypt a rotated token)

# Cloudflare tunnel (terranix)
CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-tunnel-apply     # Provision nixpi's tunnel + ingress + CNAME; PRINTS the connector token
CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-tunnel-destroy   # Tear the stack down

# Off-fleet GPU control plane (Vast.ai / RunPod) — full surface in docs/vastai-template-provisioning.md
nix run .#vast-rent -- --template-name NAME --dry-run   # Rents a live, BILLED instance — ALWAYS --dry-run first
# also: vast-account-vars-set, vast-ssh-key-set, vast-init-repo, vast-repo-check, vast-template-apply, runpod-template-apply
```

Prefer the `/eval` and `/update-input` commands over retyping the stage→check→evaluate sequence.

## Testing

`nix flake check` **is** the test suite (evaluation of every output + treefmt/statix/deadnix
and ast-grep structural-lint gates). Run it before declaring any change done — a config that
evaluates on one system can still break the other.

- Two-system coverage is mandatory: `aarch64-darwin` and `aarch64-linux`.
- CI (`.github/workflows/nix-ci.yml`) splits it across 2 GitHub-hosted legs and requires the
  aggregate `required-checks` job. Details: [`docs/repo-map.md`](docs/repo-map.md) § CI.
- **Never report a config as passing on a system only CI evaluated.** If `nix` is unavailable
  locally, validate syntax with `nix-instantiate --parse` and say the rest is CI-deferred. The
  SessionStart hook reports which mode you're in.

## Navigating the Codebase

One line per path; the *why* and the per-file specifics are in
[`docs/repo-map.md`](docs/repo-map.md).

| Path | What it owns |
|---|---|
| `flake.nix` | Inputs/pins, `forAllSystems`, `mkDarwin`/`mkNixos`, `identityArgs`, all exported configurations/packages/apps/checks, and `deploy.nodes.nixpi` (deploy-rs, magic rollback — read the ⚠ at its definition site). |
| `flake.lock` | Pinned revisions — bump only via `nix flake update` / `/update-input`, never hand-edit. Held at **60 nodes** by a deliberate `follows` diet; a `follows` edit is **shape-only** (`nix flake lock`, never a bare `nix flake update`) and `follows = ""` REBINDS to this flake rather than removing — see [`docs/repo-map.md`](docs/repo-map.md) § `flake.lock`. |
| `treefmt.nix` | Single source of truth for format + lint-fix (tools that REWRITE); drives `nix fmt`, the CI gate, and the pre-commit hook. |
| `sgconfig.yml` + `ast-grep/` | Report-only structural lint (ast-grep): `rules/` mechanises prose conventions, `rule-tests/` proves they fire. Gated by `checks.<system>.ast-grep`, **not** treefmt. |
| `hosts/` | Per-host entry profiles: `macos.nix`, `macvm.nix`, `nixpi.nix`, `nixvm.nix` (host-only deltas + per-host Homebrew lists). |
| `modules/shared/` | Home Manager profile on every host: `home.nix`, `mcp.nix`, `chromium.nix` (`programs.ungoogledChromium` — sideloaded CRXes, Apple's Passwords native host, *recommended*-level policy incl. the default search engine, and the LaunchServices default-browser claim, all for the Homebrew cask), `desktop-aesthetics.nix`, `media-queue.nix` (launchd work queue for the media Finder Services), `nix-cache.nix`, `nix-ld-libraries.nix`, `wireguard-configs.nix`, `claude-otel.nix`, `hm-launchd/`. |
| `modules/darwin/` | macOS system: `core.nix`, `homebrew.nix` (framework only), `nix-homebrew.nix`, `xcode-license.nix`, `github-runner.nix` (`services.macosGithubRunner` — LIVE on `macos`, see § Configuration). |
| `modules/nixos/` | `core.nix` (user + keys-only sshd + firewall + avahi + nix-ld + zram + GC), `desktop-vm.nix` (opt-in XFCE for `nixvm`). |
| `packages/` | Flake apps/packages: devcontainer image, `nixpi-*` provisioning, `macvm-tart`, `key-recovery`, `spotlight-launchers`, `tart-guest-agent`, plus single-purpose CLIs (`android-phone`, `vpn`, `jsonresume`, `mermaid-ascii`, `fidelity-enhance`, `media`/`photo-describe`, `claude-otel-doctor`, …). Root `bootstrap.sh` is the no-Nix stage 1. |
| `userscripts/` | The **public** Violentmonkey `.user.js` scripts, declared by name in `modules/shared/home.nix`; authored via skill `userscript-author` (`/userscript`), gated by `checks.<system>.userscripts`. Private ones merge in from nix-personal — keys must not collide. Mechanism + why Chromium allows nothing declarative: `modules/shared/chromium.nix`. |
| `infra/` | terranix (Nix → Terraform JSON): `cloudflare/nixpi-tunnel.nix`, `hyperframes/stack.nix`. Applied only via the `cf-*` / `hf-*` apps. |
| `secrets/` | agenix recipients (`secrets.nix`) + two ciphertexts: `cloudflared-token.age` (operator-only) and `gh-app-dontsell-ai-key.age` (host-decrypted on `macos`). |
| `skills/` | **Global** Claude Code skills vendored here (forks needing a patch + originals): `brag`, `brags-review`, `rag`, `android-phone`, `nix-dev-toolkit`. Most global skills instead come from pinned `flake = false` inputs. |
| `plugins/` | This repo's own Claude Code plugin marketplace (`kattakath-nix-config`); today `plugins/llmstxt` + `plugins/seargraph`. Reach for a plugin only when the unit is more than a skill (a command, hook, MCP server, or `agents/`). |
| `.claude/` | Project agent config — see the two tables below. |
| `.github/workflows/` | `nix-ci.yml` (2 hosted legs), `auto-merge.yml`, `build-devcontainer.yml`, `build-installers.yml`, `claude*.yml`, `gitleaks.yml`, `flakehub-publish.yml`. |
| `docs/` | Runbooks + this repo's design docs — indexed at the bottom of this file. |
| `memory/` | **Gitignored** project memory (the candid "why"), surfaced by `memory-loader.js`. Never `git add`. |

**Commands** (`.claude/commands/`): `/eval`, `/hygiene`, `/update-input`, `/superhook-review`,
`/pretooluse-review`, `/remember-nix`, `/vpn`, `/gmail-account`, `/routing-review`,
`/mcp-scout`, `/fleet-doctor`, `/userscript`.

**Project skills** (`.claude/skills/`): `nix-hygiene`, `nixpi-firmware-provision`,
`macvm-tart`, `vast-instance-log-tail`, `jsonresume-tailor`, `wireguard-vpn`,
`gmail-mcp-accounts`, `mcp-scout`, `fleet-doctor`, `userscript-author`.

**Always-applied rules** (`.claude/rules/`):
[`git-purity.md`](.claude/rules/git-purity.md) (stage `.nix` before eval),
[`pr-title.md`](.claude/rules/pr-title.md) (PR title = comma-separated touched components;
one PR per change, off `main`),
[`launchd-naming.md`](.claude/rules/launchd-naming.md) (every launchd unit this repo authors
exposes a `nix-<kebab>` `arg0` — never a bare `sh`/`python3`).

**Hooks** (`.claude/hooks/`): `stop-gate.js` + `pretooluse-bash-guard.js` (both wrapped by
`superhook.js`), the `*-digest.js` SessionStart nudges, `memory-loader.js`,
`autostage-nix.js`, `nix-home-path-lint.js`, `pretooluse-log.js`. What their messages mean:
[`docs/claude-hook-messages.md`](docs/claude-hook-messages.md).

**MCP servers**: one localhost `mcp-proxy` gateway (`modules/shared/mcp.nix`, darwin-only) on
`127.0.0.1:8096` hosting every server as HTTP; `desktop-commander` stays per-client stdio (RCE
surface). There is **no project `.mcp.json`**. Inventory + gotchas:
[`docs/mcp-gateway.md`](docs/mcp-gateway.md).

## Code Style & Conventions

- **Naming:** kebab-case files; `lowerCamelCase` Nix bindings; modules named by the
  platform/concern they own.
- **Platform branching:** isolate in `modules/` via `lib.mkIf` on
  `stdenv.hostPlatform`/`isDarwin`/`isLinux` — host profiles stay declarative and
  platform-agnostic.
- **Paths — two axes, never conflate them:** a Nix **source path literal**
  (`source = ../../claude/CLAUDE.md;`, `callPackage ../../packages/x.nix`,
  `"${../../skills/rag}"`) is resolved **relative to the `.nix` file at evaluation time**,
  content-hashed, and copied into `/nix/store` — it **must** be repo-relative (or a store
  path); `$HOME`/XDG is impossible here (`$HOME` is undefined at eval, and a runtime home path
  is neither reproducible nor store-addressable). A `../..` source literal is **correct and
  idiomatic — never "fix" it to a home path.** The `$HOME`/XDG rule applies only to the *other*
  axis: **runtime paths** — where a program reads/writes or files land at runtime (`home.file`
  TARGET keys are `$HOME`-relative by definition; env vars like
  `BRAG_DATA_DIR = "$HOME/Developer/…"`; data dirs). Those must be `$HOME`/XDG-relative,
  **never a hardcoded `/Users/<name>` or `/home/<name>`** (such a literal in a `.nix` *value* —
  not a comment — is the real anti-pattern to reject, and `nix-home-path-lint.js` flags it).
- **Systems:** every new output must evaluate on both `aarch64-darwin` and `aarch64-linux`, or
  be explicitly gated.
- **Inputs:** bump only via `nix flake update` (or `update-input <name>`); commit the resulting
  `flake.lock`.
- **Comments explain why, not what.** No "we tried X then Y" narratives unless they prevent a
  known footgun (one sentence max).

## Security

- **No plaintext secret in any `.nix`** — the store is world-readable.
- **agenix holds exactly two secrets, on two different models** — don't assume either one:
  - `secrets/cloudflared-token.age` (nixpi's tunnel token) is **operator-only**: encrypted to
    the operator's `~/.ssh/id_ed25519` alone, decrypted on the Mac and planted on the SD card's
    FIRMWARE partition. **`nixpi` never decrypts it** — a fresh SD flash rotates the host key.
  - `secrets/gh-app-dontsell-ai-key.age` (the runner's GitHub App RS256 key) is
    **host-decrypted on `macos` at activation** (recipients: operator **+** the `macos` host
    key) → `/run/agenix/…`. So "nothing is host-decrypted" is **false** — that path is live.
  - Edit either with `agenix -e secrets/<name>.age`; re-key with `-r` after changing recipients.
- **Personal tokens live in the macOS login Keychain**, managed with
  `secret <set|get|rm|ls|load>`; no secret *names* live in `.nix` either (the Keychain index is
  authoritative). Servers/CLIs read them at launch via `passwordCommand`-style wrappers, so no
  value ever reaches argv or the store.
- **Never display a secret value** — using one is fine, echoing/logging/committing it is not.
- Mechanism, history, and the two documented loader footguns:
  [`docs/secrets-and-keychain.md`](docs/secrets-and-keychain.md).

## Configuration

How a host gets composed — change these knobs, not the hosts' internals:

- **Identity once.** `loginName = "ismail"`, `domainName = "kattakath.com"`, `fullName`,
  `userEmail` are `let` bindings (`identityArgs`) in `flake.nix`, threaded through
  `specialArgs`/`extraSpecialArgs`. `mkDarwin` accepts a per-host `identity` override, but
  **nothing in the fleet uses it** — every host runs the same operator identity.
- **Per-host divergence is a gate, not a fork.** `networking.hostName`-gated `lib.mkIf` (or
  `osConfig`) inside `modules/`; never a second identity, never a copy-pasted host block.
- **Private layer plugs in, never leaks out.** `lib.mkDarwin { extraHomeModules }` /
  `mkNixos { hostedSites }` are the seams the private nix-personal flake fills
  ([`docs/private-home-modules.md`](docs/private-home-modules.md)); the public tree never
  references a private repo.
- **Binary cache:** the public `kattakath` Cachix cache is consumed tokenless by every host
  (`modules/shared/nix-cache.nix`); only CI and the operator's Keychain hold the write token.
- **`macos` runs self-hosted CI runners — for a *different* org.** `services.macosGithubRunner`
  (`modules/darwin/github-runner.nix`, enabled in `hosts/macos.nix`, `count = 2`) registers
  ephemeral org-level runners for **`dontsell-ai`**, authenticated by a GitHub App key minting
  ~1h tokens per registration. **This repo's own CI uses none of them** — `nix-ci.yml` is 100%
  GitHub-hosted. So "0 self-hosted runners" is true of *nix-config's CI*, not of the Mac.

## Using Subagents

Agent definitions live in `.claude/agents/` (project) — today just `terranix-infra-reviewer`.

| Situation | Use |
|---|---|
| Explain architecture / get the big picture | `cartographer` agent (read-only, ASCII diagrams) |
| Touching `infra/**.nix`, or **before any** `cf-tunnel-apply` / `hf-apply` | `terranix-infra-reviewer` agent — reviews + plans, never applies |
| "Does it evaluate?" | `/eval` (stage + `nix flake check`) — no agent needed |
| LEAN/DRY/doc-drift cleanup | `/hygiene` → skill `nix-hygiene` (audit → fix → gate) |
| Cross-repo fleet sweep | `/fleet-doctor` (repos listed in `.claude/skills/fleet-doctor/fleet-repos.txt`) |
| Adopt an MCP server | `/mcp-scout` → skill `mcp-scout` (declare in `mcp.nix`, never install imperatively) |

## Important Notes

- **Flakes ignore untracked files.** A new `.nix` not yet `git add`ed is invisible to
  `nix flake check` and fails with confusing "file not found" / stale-eval errors. ALWAYS
  `git add` before evaluating — enforced by [git-purity](.claude/rules/git-purity.md) and the
  Stop hook.
- **Never `darwin-rebuild switch --flake .#macos` from this public repo.** It silently drops
  the private nix-personal layer. Use `activate` (nix-personal) or ask first.
- **`nixpi` is LIVE.** Changes must pass CI (which pushes closures to Cachix) before
  activation; pull prebuilt paths, never build heavy on the Pi.
- **Never `deploy --targets .#nixpi` from this public repo.** `deploy.nodes.nixpi` here points
  at the **site-free** public `nixosConfigurations.nixpi`, so a *successful* deploy hands the
  live Pi a Caddy with **zero vhosts** and no dontsell.ai connector — every site goes dark
  while sshd stays up. **Magic rollback cannot save you from that**: it only reverts an
  activation that leaves the host **unreachable**, and a site-free Pi is perfectly reachable,
  so deploy-rs reports SUCCESS. Deploy from the private nix-personal flake, which reuses this
  node against *its* `nixosConfigurations.nixpi`. Also: bare `deploy` with no `--targets` fans
  out over **every** node — always name the target.
- **What magic rollback actually buys** (`deploy.nodes.nixpi.magicRollback = true`): the Pi
  activates behind a watchdog and reverts **itself** to the previous generation unless the
  deployer reconnects over a second ssh session and confirms. A change that kills sshd, the
  tunnel connector, or networking becomes a *failed deploy* instead of a trip to the shelf to
  pull the SD card and reflash (`docs/nixpi-sd-flashing-runbook.md`, ~40 min). `nixos-rebuild
  switch --target-host` has no such undo. `remoteBuild = false` keeps the build off the Pi.
- `home-manager switch` activates and is hard to reverse; prefer `build` to verify, and
  `switch` only when explicitly asked. `home-manager generations` lists,
  `home-manager rollback` reverts.
- **`nix run .#nixvm` is the only way `nixvm` is ever booted** — a `nixos-rebuild build-vm`
  runner exposed as a flake app (XFCE desktop, native QEMU/Cocoa window on macOS, no
  macOS-guest path, no VM config outside Nix) booting a throwaway overlay. There is no
  installed `nixvm` disk, no builder VM, and no runner on it. (The only self-hosted runners in
  the fleet are the two on `macos`, and they serve `dontsell-ai`, not this repo — see
  § Configuration.)
- **aarch64-linux builds on the Mac** go to Determinate's **native Linux builder** (Apple
  Virtualization; ephemeral ~1-CPU/8 GB VM, no provisioning). It is a FlakeHub/account feature
  enabled at https://dtr.mn/features, **not** settable from Nix (`external-builders` is
  rejected by `determinateNix.customSettings`), and nix-darwin's `nix.linux-builder` is
  unusable because it needs `nix.enable = true`, which Determinate disables (nix-darwin#1505).
  It also **cannot run `cp --no-preserve=mode` into `$out`** (EPERM "setting permissions"),
  which breaks nixpkgs' caddy `Caddyfile-formatted` and therefore every Mac-side build of a
  Caddy-serving `nixpi` generation — realise that toplevel **on the Pi** instead (text
  derivations only; see [`docs/repo-map.md`](docs/repo-map.md) § `hosts/`).
  **Account entitlement alone is not enough** — the local `determinate-nixd` must also be
  logged in to FlakeHub, or `native-linux-builder` silently vanishes and every aarch64-linux
  build fails with a `platform mismatch` that looks unrelated to auth. Manual, per-machine step:
  see "Manual steps Nix can't do" in
  [`docs/mac-key-recovery-runbook.md`](docs/mac-key-recovery-runbook.md). Heavy multi-core
  builds (e.g. the Pi SD image) still go to GitHub CI / Cachix.

## Documentation

- [`docs/repo-map.md`](docs/repo-map.md) — **the full fleet architecture**: every path, module,
  package, and flake output, with the reasoning. The long form of § Navigating the Codebase.
- [`docs/mcp-gateway.md`](docs/mcp-gateway.md) — the localhost MCP gateway: server inventory,
  credentials model, opt-ins, how to add one.
- [`docs/secrets-and-keychain.md`](docs/secrets-and-keychain.md) — agenix operator-only vault +
  login-Keychain loader and the `secret` CLI.
- [`docs/nixpi-sd-flashing-runbook.md`](docs/nixpi-sd-flashing-runbook.md) — flashing the
  `nixpi` SD card (full verified `dd` write).
- [`docs/mac-key-recovery-runbook.md`](docs/mac-key-recovery-runbook.md) — rebuilding `macos`
  from a wiped Mac + the iCloud key-recovery kit; also the manual steps Nix can't do.
- [`docs/flakehub-input-freshness.md`](docs/flakehub-input-freshness.md) — the automated weekly
  `flake.lock` bump flow.
- [`docs/macos-settings-surface.md`](docs/macos-settings-surface.md) — what macOS settings
  `macos` can configure declaratively, and the TCC/FileVault walls.
- [`docs/vastai-template-provisioning.md`](docs/vastai-template-provisioning.md) — the Vast.ai
  GPU-template provisioning subsystem end to end.
- [`docs/private-home-modules.md`](docs/private-home-modules.md) — composition contract for
  private modules: public engine, private plug-ins, no private references in this tree.
- [`docs/flake-architecture-strategy-adr.md`](docs/flake-architecture-strategy-adr.md) — ADR
  (2026-08-20): flake-parts for the small supporting flakes; nix-config's own core engine and
  the dendritic pattern stay out of scope.
- [`docs/macvm-tart-runbook.md`](docs/macvm-tart-runbook.md) — host-side Tart lifecycle, SSH,
  shared `~/Downloads` for `macvm` (+ the VirtioFS coherence/quarantine findings).
- [`docs/wireguard-vpn.md`](docs/wireguard-vpn.md) — the `vpn` CLI is **macvm-only**; `macos`
  uses the `WireGuard.app` GUI exclusively (no tunnel can be raised from a shell).
- [`docs/gmail-mcp-multi-account-runbook.md`](docs/gmail-mcp-multi-account-runbook.md) — TRUE
  simultaneous multi-account Gmail (one process per account) + a silent-wrong-account failure
  mode.
- [`docs/claude-code-observability-runbook.md`](docs/claude-code-observability-runbook.md) —
  local OTel Collector for Claude Code's own `tool_decision` telemetry + the `/routing-review`
  loop.
- [`docs/claude-hook-messages.md`](docs/claude-hook-messages.md) — decoder for this repo's hook
  messages (why DENYs read as "errors", how to read a prompt-hook denial).
- [`docs/auto-merge-and-merge-queue.md`](docs/auto-merge-and-merge-queue.md) — how every fleet
  flake merges itself once CI is green (CI bot App token, merge-queue ruleset, `merge_group:`).
- [`docs/mcp-gateway-accessibility-tcc.md`](docs/mcp-gateway-accessibility-tcc.md) — the
  one-time Accessibility (TCC) grant `macos-automator` needs.
- [`docs/hyperframes-selfhost.md`](docs/hyperframes-selfhost.md) — self-hosting
  Kinocut+HyperFrames (terranix `infra/hyperframes/stack.nix`; `hf-export`/`hf-apply`/`hf-doctor`),
  with its [test plan](docs/hyperframes-selfhost-test-plan.md) and
  [publish notes](docs/hyperframes-selfhost-publish.md).
- [`docs/claude-desktop-instructions.md`](docs/claude-desktop-instructions.md) — the one Claude
  behaviour this repo can't manage declaratively (account-level Desktop instructions) + the
  canonical "diagrams as ASCII" wording.
