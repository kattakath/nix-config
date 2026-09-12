This is `kattakath/nix-config` — the all-in-one, public Nix mono-repo that declaratively
manages Ismail's entire aarch64-only fleet: one client Mac, one live Raspberry Pi server, a
throwaway NixOS dev VM, and a devcontainer image. Everything below is
guidance for Claude Code (claude.ai/code) when working in this repository.

# CLAUDE.md

**This file is an index, not an encyclopedia.** It stays scannable and under the 40k-char
context lint limit; the full per-path detail lives in [`docs/repo-map.md`](docs/repo-map.md).
When you change repo shape, update the one-liner here **and** the section there.

## Motto — ground every development decision in this repo here first

> **Off-the-shelf over hand-rolled.**
> **Proven patterns over reinvented wheels.**
> **Community Legos over proprietary monoliths.**

Before writing custom Nix, a custom script, or a custom protocol: is there an existing
nixpkgs/nix-darwin/home-manager option, a standard Unix/POSIX mechanism, or an established
community pattern that already does this? Reach for that first, weighted roughly **2x** over
building something bespoke — and when custom genuinely is warranted, say **why** the
off-the-shelf option didn't fit, not just that one wasn't found.

- **Mechanized, not just aspirational:** [`upstream-first`](.claude/rules/upstream-first.md)
  is this motto's enforcement — grep the pinned input's option surface and cite the result
  before proposing custom Nix. A hand-rolled `home.activation` shim that turns out to
  duplicate an existing nix-darwin option is exactly the failure mode this rule exists to
  catch.
- **Community Legos, concretely:** launchd's own primitives
  (`QueueDirectories`/`StartInterval`/`ProcessType`), POSIX mechanisms (`SIGSTOP`/`SIGCONT`,
  `setsid`), and prior art with a name (systemd's `MAINPID` pattern) — reused and cited, not
  reinvented under a different name. The extracted
  [`nix-media-cli`](https://github.com/kattakath/nix-media-cli)'s `packages/media-queue.nix`
  header is the running log of exactly this: what's genuinely custom there, and the
  grep/research that justified it each time.
- **Proprietary monoliths, avoided:** a broker-based job queue, a bespoke supervision daemon,
  or any other heavy framework is *also* a violation of this motto when it's bigger than the
  problem warrants — reuse cuts both ways. The right-sized community Lego, not the fanciest
  one available.

## Overview

Fully declarative **aarch64-only** fleet, single source of truth, platform divergence in
`modules/` (never ad-hoc shell):

| Host | System | Role |
|---|---|---|
| `macos` | aarch64-darwin | The sole client Mac (nix-darwin). No incoming traffic; it is the SSH *client*, reaching `nixpi` via `cloudflared access ssh`. Builds `aarch64-linux` locally on Determinate's native Linux builder. |
| `nixpi` | aarch64-linux | **LIVE server** (NixOS on a Pi 4): Access-gated, loopback-bound SSH over a Cloudflare Tunnel connector + Caddy. **Site-free in this public repo** — the real site list comes from the private nix-personal flake ([`docs/private-home-modules.md`](docs/private-home-modules.md)). |
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
| `flake.lock` | Pinned revisions — bump only via `nix flake update` / `/update-input`, never hand-edit. Held at **67 nodes** by a deliberate `follows` diet plus ADR-002's capsule absorption (each satellite that comes in-tree drops its own node and its private deps — cloudflared-connector took 2); a `follows` edit is **shape-only** (`nix flake lock`, never a bare `nix flake update`) and `follows = ""` REBINDS to this flake rather than removing — see [`docs/repo-map.md`](docs/repo-map.md) § `flake.lock`. |
| `treefmt.nix` | Single source of truth for format + lint-fix (tools that REWRITE); drives `nix fmt`, the CI gate, and the pre-commit hook. |
| `sgconfig.yml` + `ast-grep/` | Report-only structural lint (ast-grep): `rules/` mechanises prose conventions **and the capsule boundary** (`capsule-must-not-reach-out`), `rule-tests/` proves they fire. Gated by `checks.<system>.ast-grep`, **not** treefmt. |
| `hosts/` | Per-host entry profiles: `macos.nix`, `nixpi.nix`, `nixvm.nix` (host-only deltas + per-host Homebrew lists). |
| `modules/parts/` | The FLAKE ENGINE, one file per concern, discovered by `import-tree` (ADR-002 wave 2): `identity.nix`, `systems.nix`, `compose.nix` (`mkDarwin`/`mkNixos`), `hosts.nix`, `packages.nix`, `checks.nix`, `terranix.nix`, `devshell.nix`, `deploy.nix`, `templates.nix`, `devcontainer.nix`, `lib-option.nix`, `touchup.nix` (what the flake does **not** export), `capsules.nix`. The engine **may** reach anywhere. |
| `modules/features/` | CAPSULES — the absorbed satellite flakes, one directory each: `flake-module.nix` (the ONLY file anything outside imports) + `module.nix` + `checks/` + `README.md`. A capsule **may not reach outside its own directory**, enforced by `ast-grep/rules/capsule-must-not-reach-out.yml` + `checks.<system>.capsule-registry`, not by convention. Today: `cloudflared-connector`. |
| `modules/shared/` | Home Manager profile on every host: `home.nix`, `mcp.nix`, `terminal-theme.nix` (`local.terminalTheme` — the fleet's one ANSI ring + type, consumed by Ghostty, VS Code and Terminal.app), `chromium.nix` (`programs.ungoogledChromium` — sideloaded CRXes, Apple's Passwords native host, and *recommended*-level policy incl. the default search engine, all for the Homebrew cask), `default-browser.nix` (the LaunchServices default-browser claim, split out of `chromium.nix`), `desktop-aesthetics.nix`, `nix-cache.nix`, `nix-ld-libraries.nix`, `wireguard-configs.nix`, `claude-otel.nix`, `claude-bedrock-gate.nix` (Bedrock routing survives a public-only activation), `git-allowed-signers.nix` (option-only seam nix-personal fills), `wallpaper/`, `hm-launchd/`. |
| `modules/darwin/` | macOS system: `core.nix`, `user-folders.nix` (`local.folders.*` — inbox paths; unset = system default), `homebrew.nix` (framework only), `nix-homebrew.nix`, `xcode-license.nix`, `github-runner.nix` (`services.macosGithubRunner` — LIVE on `macos`, see § Configuration). |
| `modules/nixos/` | `core.nix` (user + keys-only **loopback-bound** sshd with `openFirewall = false` + a firewall that opens **no** TCP port + avahi + nix-ld + zram + GC), `desktop-vm.nix` (opt-in XFCE for `nixvm`). |
| `packages/` | Flake apps/packages: devcontainer image, `nixpi-*` provisioning, `key-recovery`, `spotlight-launchers`, plus single-purpose CLIs (`android-phone`, `jsonresume`, `mermaid-ascii`, `claude-otel-doctor`, …). Root `bootstrap.sh` is the no-Nix stage 1. The media/photo CLIs are **no longer here** — they moved to the [`nix-media-cli`](https://github.com/kattakath/nix-media-cli) input (see § Configuration). |
| `userscripts/` | The **public** Violentmonkey `.user.js` scripts, declared by name in `modules/shared/home.nix`; authored via the portable `plugins/page-lab` (method + picker + diagnosis) + project skill `userscript-author` (Nix declaration), gated by `checks.<system>.userscripts` — which **runs the plugin's own linter**, so the Greasy Fork rulebook lives once. Private ones merge in from nix-personal — keys must not collide, and that tree is **not** covered by the gate. Mechanism + why Chromium allows nothing declarative: `modules/shared/chromium.nix`. |
| `infra/` | terranix (Nix → Terraform JSON): `cloudflare/nixpi-tunnel.nix`, `cloudflare/mcp-public.nix` (the published MCP stack — tunnel, origin hostname, Access app + service token, portal registrations), `hyperframes/stack.nix`. Applied only via the `cf-*` / `mcp-public-*` / `hf-*` apps. |
| `secrets/` | agenix recipients (`secrets.nix`) + the operator pubkey (`operator-key.nix`, single-sourced into both recipients and `authorizedKeys`) + **four** ciphertexts: `cloudflared-token.age` (operator-only) and three host-decrypted on `macos` — `gh-app-dontsell-ai-key.age`, `gh-app-fleet-key.age`, `gitlab-runner-token.age`. |
| `skills/` | **Global** Claude Code skills vendored here (forks needing a patch + originals): `brag`, `brags-review`, `rag`, `android-phone`, `nix-dev-toolkit`. Most global skills instead come from pinned `flake = false` inputs. |
| `plugins/` | This repo's own Claude Code plugin marketplace (`kattakath-nix-config`); today `plugins/llmstxt`, `plugins/seargraph`, `plugins/page-lab`. Reach for a plugin only when the unit is more than a skill (a command, hook, MCP server, or `agents/`) **or is meant to be publishable outside the fleet**. |
| `.claude/` | Project agent config — see the two tables below. |
| `claude/` + `qwen/` | The **global** (all-projects) agent context this repo installs on `macos`: `claude/CLAUDE.md` → `~/.claude/CLAUDE.md` (via `programs.claude-code.context`) and `qwen/QWEN.md` → `~/.qwen/QWEN.md`. Both wired from `modules/shared/home.nix`; do not confuse either with **this** file, which is project-scoped. |
| `.github/workflows/` | `nix-ci.yml` (2 hosted legs), `auto-merge.yml`, `build-devcontainer.yml`, `build-installers.yml`, `claude*.yml`, `gitleaks.yml`, `flakehub-publish.yml`, `update-flake-lock.yml` (the weekly lock bump). |
| `docs/` | Runbooks + this repo's design docs — indexed at the bottom of this file. |

**Commands** (`.claude/commands/`): `/eval`, `/hygiene`, `/update-input`, `/superhook-review`,
`/pretooluse-review`, `/remember-nix`, `/gmail-account`, `/routing-review`,
`/mcp-scout`, `/fleet-doctor`, `/userscript`. (`/devtools` and `/pick` are **not** here —
they ship from the `plugins/page-lab` marketplace.)

**Project skills** (`.claude/skills/`): `nix-hygiene`, `nixpi-firmware-provision`,
`vast-instance-log-tail`, `jsonresume-tailor`, `gmail-mcp-accounts`, `mcp-scout`,
`fleet-doctor`, `userscript-author`.

**Always-applied rules** (`.claude/rules/`):
[`git-purity.md`](.claude/rules/git-purity.md) (stage `.nix` before eval),
[`pr-title.md`](.claude/rules/pr-title.md) (PR title = comma-separated touched components;
one PR per change, off `main`),
[`launchd-naming.md`](.claude/rules/launchd-naming.md) (every launchd unit this repo authors
exposes a `nix-<kebab>` `arg0` — never a bare `sh`/`python3`),
[`upstream-first.md`](.claude/rules/upstream-first.md) (grep the **pinned** input's option
surface before writing custom Nix, and cite the result).

**Hooks** (`.claude/hooks/`): `stop-gate.js` + `pretooluse-bash-guard.js` (both wrapped by
`superhook.js`), the `*-digest.js` SessionStart nudges, `autostage-nix.js`,
`nix-home-path-lint.js`. What their messages mean:
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
- **agenix holds four secrets, on two different models** — don't assume any one of them:
  - **Operator-only (1):** `secrets/cloudflared-token.age` (nixpi's tunnel token) is encrypted to
    the operator's `~/.ssh/id_ed25519` alone, decrypted on the Mac and planted on the SD card's
    FIRMWARE partition. **`nixpi` never decrypts it** — a fresh SD flash rotates the host key.
  - **Host-decrypted on `macos` at activation (3):** `gh-app-dontsell-ai-key.age` and
    `gh-app-fleet-key.age` (GitHub App RS256 keys — the two runner lanes) and
    `gitlab-runner-token.age` (the `glrt-` token). Recipients are operator **+** the `macos`
    host key → `/run/agenix/…`. So "nothing is host-decrypted" is **false** — that path is live.
  - The two `gh-app-*` files hold **identical key material on purpose** (same App, different
    owning user: `_github-runner` daemons vs. the login-user Tart agents) — rotating the App key
    means re-encrypting **both**. `secrets/secrets.nix` carries the full why.
  - Edit any with `agenix -e secrets/<name>.age`; re-key with `-r` after changing recipients.
- **Personal tokens live in the macOS login Keychain**, managed with
  `secret <set|reveal|rm|ls|exec|copy|fp|bind|unbind|adopt|load>` (there is **no `secret get`** —
  printing a value is opt-in via `reveal`); no secret *names* live in `.nix` either (the Keychain index is
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
- **Extracted features plug in as inputs, and can be stripped off in one line.** The media
  stack (`programs.mediaCli`, from
  [`nix-media-cli`](https://github.com/kattakath/nix-media-cli)) and the Keychain secret
  store (`programs.keychainSecrets`, from `nix-keychain-secrets`) both left this tree for
  standalone MIT flakes and come back as home-manager modules. Dogfooding, and the reason
  is practical: `programs.mediaCli.enable = false` removes the CLIs, both launchd agents,
  the Finder Services and the companion tools together — no orphaned package, no dangling
  session variable, no stale menu item to hunt down.
- **Binary cache:** the public `kattakath` Cachix cache is consumed tokenless by every host
  (`modules/shared/nix-cache.nix`); only CI and the operator's Keychain hold the write token.
- **`macos` runs self-hosted CI runners — two kinds, neither for this repo's CI.**
  (1) `services.macosGithubRunner` (`modules/darwin/github-runner.nix`, `count = 2`): bare-metal
  ephemeral org runners for **`dontsell-ai`**'s nix/cachix/pgvector-heavy CI. (2) `tart.githubRunners.*`
  (`nix-tart-vms` `darwinModules.github-runner`, configured in `hosts/macos.nix`): **ephemeral
  Tart-VM-per-job** runners for `kattakath` + `silvercreek-ai` + `dontsell-ai` (label
  `dontsell-vm`), sharing Apple's hard 2-concurrent-VM budget via a slot semaphore. Both mint ~1h
  tokens from GitHub App keys (agenix); since 2026-09-06 **both lanes share ONE App**,
  `ismailkattakath-ci` (appId 4849830, operator-owned + public), which replaced the retired
  `kattakath-fleet-ci` (4845230), `kattakath-ci` (4243998) and `dontsell-ai` (4689619). The **GitLab**
  lane rides the same budget: `tart.gitlabRunner` (`darwinModules.gitlab-runner`) runs
  gitlab-runner declaratively, rendering its config at agent start from the agenix
  `gitlab-runner-token.age`. **This repo's own CI uses none of them** — `nix-ci.yml` is 100%
  GitHub-hosted.

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
  live Pi a Caddy with **zero vhosts** — every site goes dark
  while sshd stays up. **Magic rollback cannot save you from that**: it only reverts an
  activation that leaves the host **unreachable**, and a site-free Pi is perfectly reachable,
  so deploy-rs reports SUCCESS. Deploy from the private nix-personal flake, which reuses this
  node against *its* `nixosConfigurations.nixpi`. Also: bare `deploy` with no `--targets` fans
  out over **every** node — always name the target.
- **Never run the `cf-*` terranix apps from this public repo** — the twin of the `deploy` trap.
  `mkCfTunnelTofu` calls `cfTunnelConfig` with **no `hostedSites`** (it defaults to `[ ]`), so
  the public tree renders a tunnel whose ingress is **SSH + the catch-all 404 and nothing
  else**, with no site CNAMEs and no www→apex rulesets. A *successful* apply of that blanks
  the live tunnel and deletes every site record in state, while reporting SUCCESS — exactly
  the failure shape `deploy` has. `mkCfTunnelTofu` now **refuses** a render with ≤2 ingress
  entries (override: `CF_TUNNEL_ALLOW_SITE_FREE=1`), but run those apps from the private
  nix-personal flake, which supplies the real site list.
- **The edge's TLS floor and the SSH Access gate are DECLARED, not clicked.**
  `infra/cloudflare/nixpi-tunnel.nix` owns `cloudflare_zone_setting` (ssl=strict,
  min_tls=1.2, always_use_https, HSTS) for the SSH host's zone and every hosted site's
  zone, plus `cloudflare_zero_trust_access_application.nixpi_ssh`. That Access app
  **vanished once** (2026-08-20) and took `ssh` + both deploy legs with it; declaring it
  means a rebuild restores the gate. Zones with no terranix module here (aloshy.ai,
  etuper.com, izzykatt.ca, silvercreek.ai) are still configured out-of-band.
- **OpenTofu state is the fragile part of the edge, not the config.** State has been lost
  **twice** — both times because `tofu` ran in whatever the CWD happened to be, leaving a
  gitignored state file behind. There is **no backend block**; instead each terranix app pins
  its own working directory (0700, `umask 077`, state 0600 — **both** hold a tunnel connector
  token in plaintext, and the MCP one also holds an Access service-token secret):
  `cf-*` → `$XDG_STATE_HOME/nix-config-cf-tunnel`, `mcp-public-*` →
  `$XDG_STATE_HOME/nix-config-mcp-public`. Never run `tofu` in a bare directory, and never
  apply before a `plan` reads clean.
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
  installed `nixvm` disk, no builder VM, and no runner on it. (Every self-hosted runner in the
  fleet lives on `macos` — two bare-metal, three Tart-VM, one GitLab — and none of them serve
  this repo's CI; see § Configuration.)
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
- [`docs/mcp-public-exposure-design.md`](docs/mcp-public-exposure-design.md) — **BUILT and live
  (2026-09-12)**: `services.mcpGateway.public = [ … ]` flips a gateway server to publicly
  reachable. A **second** `mcp-proxy` on `:8097` carries only the published subset (so a leaked
  credential cannot reach Gmail/Postgres/WordPress on `:8096`), fronted by a cloudflared
  connector + **one** Access app + **one** service token, which the MCP portal presents via
  `auth_credentials` `{"headers":{"cf-access-client-id":…}}`. **Exactly two hostnames, and they
  do not grow per server:** `mcp.<domain>` is the portal clients talk to, `upstream.<domain>` is
  the origin only the portal dials. A new public server costs one list entry.
  The old standalone-Worker invariant (*"safe when the portal is bypassed"*) is **retired** — the
  last Worker running its own OAuth dropped it, so bypass is now impossible rather than merely
  survivable. §9 is the correction record.
- [`docs/open-design.md`](docs/open-design.md) — OpenDesign's declared/imperative boundary:
  adopted cask + updater kill-switch + per-client stdio MCP vs. the app's mutable state.
- [`docs/secrets-and-keychain.md`](docs/secrets-and-keychain.md) — agenix operator-only vault +
  login-Keychain loader and the `secret` CLI.
- [`docs/nixpi-sd-flashing-runbook.md`](docs/nixpi-sd-flashing-runbook.md) — flashing the
  `nixpi` SD card (full verified `dd` write).
- [`docs/mac-key-recovery-runbook.md`](docs/mac-key-recovery-runbook.md) — rebuilding `macos`
  from a wiped Mac + the iCloud key-recovery kit; also the manual steps Nix can't do.
- [`docs/flakehub-input-freshness.md`](docs/flakehub-input-freshness.md) — the automated weekly
  `flake.lock` bump flow.
- [`docs/terminal-theme.md`](docs/terminal-theme.md) — the one terminal palette: the provider
  contract, per-surface coverage (16/16 for Ghostty and VS Code, **4/16** for Terminal.app —
  an OS ceiling), what deliberately stays uncentralized, and the measured reasons stylix and
  base16.nix were both rejected.
- [`docs/macos-settings-surface.md`](docs/macos-settings-surface.md) — what macOS settings
  `macos` can configure declaratively, and the TCC/FileVault walls.
- [`docs/vastai-template-provisioning.md`](docs/vastai-template-provisioning.md) — the Vast.ai
  GPU-template provisioning subsystem end to end.
- [`docs/private-home-modules.md`](docs/private-home-modules.md) — composition contract for
  private modules: public engine, private plug-ins, no private references in this tree.
- [`docs/flake-architecture-strategy-adr.md`](docs/flake-architecture-strategy-adr.md) — ADR-001
  (2026-08-20): flake-parts for the small supporting flakes; nix-config's own core engine and
  the dendritic pattern stay out of scope. **Decision #2 is SUPERSEDED by ADR-002 below** — read
  both; ADR-002 answers its objections one by one and one of them still stands.
- [`docs/monoflake-capsule-adr.md`](docs/monoflake-capsule-adr.md) — **ADR-002 (2026-09-12,
  decided, not yet implemented)**: absorb all seven satellite flakes, move to flake-parts, and
  replace the deleted repo boundaries with **capsules** — `modules/features/<name>/` directories
  that may not reach outside themselves, enforced by the existing ast-grep gate plus a stub-host
  `lib.evalModules`. `flake.nix` 2219 → ~390 lines, lock 68 → ~55. Carries the off-the-shelf
  scorecard, the 3 blocking corrections an adversarial pass found (including that `import-tree`'s
  default filter imports *every* `.nix`), the wave plan, and what the collapse gives up.
- [`docs/macvm-readd-runbook.md`](docs/macvm-readd-runbook.md) — re-adding the removed
  `macvm` Tart guest (removed 2026-09-05); what survives in `nix-tart-vms`.
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
- [`docs/photo-system.md`](docs/photo-system.md) — the photo retrieval system end to end: what
  `photo-describe` writes into a file, what `rclip` keeps beside the folder, and how to search
  each. The durable/derived split in one page.
- [`docs/nix-media-cli-extraction-grant.md`](docs/nix-media-cli-extraction-grant.md) — a
  self-contained brief for studying the media stack and designing its extraction into a
  public `kattakath/nix-media-cli` flake — and its answer,
  [`docs/nix-media-cli-extraction-study.md`](docs/nix-media-cli-extraction-study.md): the
  repo design, the migration plan, and why the queue does **not** become its own flake yet.
  **Both are now HISTORY, not a plan**: the extraction shipped, and the stack lives in
  [`nix-media-cli`](https://github.com/kattakath/nix-media-cli) behind
  `programs.mediaCli.enable`. The `media-<verb>` renaming proposal in the study is the one
  part still undecided, and it is now that repo's call, not this one's.
- [`docs/claude-desktop-instructions.md`](docs/claude-desktop-instructions.md) — the one Claude
  behaviour this repo can't manage declaratively (account-level Desktop instructions) + the
  canonical "diagrams as ASCII" wording.
