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
  reinvented under a different name. The `media-cli` capsule's
  `modules/features/media-cli/packages/media-queue.nix` header is the running log of exactly
  this: what's genuinely custom there, and the grep/research that justified it each time —
  and its `module.nix` header carries the table proving every queue mechanism is launchd's
  own, which is why 1,300 lines of queue contain no scheduler of ours.
- **Proprietary monoliths, avoided:** a broker-based job queue, a bespoke supervision daemon,
  or any other heavy framework is *also* a violation of this motto when it's bigger than the
  problem warrants — reuse cuts both ways. The right-sized community Lego, not the fanciest
  one available.

## Overview

Fully declarative **aarch64-only** fleet, single source of truth, platform divergence in
`modules/` (never ad-hoc shell):

| Host | System | Role |
|---|---|---|
| `macos` | aarch64-darwin | The sole client Mac (nix-darwin). **ONE account**: `ismail` (`system.primaryUser`) — a second admin account existed 2026-09-15 to 2026-09-17 and was deleted forever. No incoming traffic; it is the SSH *client*, reaching `nixpi` via `cloudflared access ssh`. Builds `aarch64-linux` locally on Determinate's native Linux builder. |
| `nixpi` | aarch64-linux | **LIVE server** (NixOS on a Pi 4): Access-gated, loopback-bound SSH over a Cloudflare Tunnel connector + Caddy, serving its real sites directly (`config.fleet.hostedSites`, `modules/parts/identity.nix`). Runs **Determinate Nix** (nixosModule, since 2026-09-21) with `nix.settings` still live; the prebuilt Nix substitutes from `install.determinate.systems`. |
| `nixvm` | aarch64-linux | Throwaway XFCE build-vm, materialised **only** as `nix run .#nixvm`. No installed disk, no builder, no runner. |
| devcontainer | +`x86_64-linux` | The one exception to aarch64-only, so it runs on x86_64 Codespaces. |

Full map: [`docs/repo-map.md`](docs/repo-map.md).

## Build & Commands

```bash
git add -A                                   # MANDATORY before any eval — flakes ignore untracked files
nix flake check --all-systems --no-build     # Evaluate every output on BOTH systems, build nothing — a bare check on the
                                             #   Mac silently OMITS aarch64-linux ("incompatible systems"), measured 2026-09-21
nix flake check                              # Build the native-system formatting/lint/pre-commit checks (the test suite)
nix flake show                               # List exported darwin/nixosConfigurations + packages
nix fmt                                      # Format + lint-fix all .nix via treefmt (nixfmt + statix + deadnix)
nix develop                                  # Dev shell (nixd LSP, treefmt, home-manager); installs pre-commit hooks
nix build .#checks.<system>.formatting       # CI formatting/lint gate
nix build .#checks.<system>.ast-grep         # Structural-lint gate (report-only; rules in ast-grep/rules/)
ast-grep scan --no-ignore hidden .           # Same scan by hand (devShell); --no-ignore hidden or .claude/ is SKIPPED
ast-grep test --skip-snapshot-tests          # Prove each rule still fires (fixtures in ast-grep/rule-tests/)
nix build .#checks.<system>.capsule-registry # readDir modules/features == the capsules import-tree loaded
nix build .#checks.<system>.claude-md-budget # THIS file must stay under 40,000 chars — it is a GATE
scripts/drv-snapshot.sh --compare .baseline/wave0-final   # "moved code, changed no build" (see § Testing)
# Agent hygiene (LEAN/DRY/docs drift → fix → fmt → check): /hygiene  or skill nix-hygiene

# Activation
activate                                     # Activate macos, from ANY directory. `darwin-rebuild switch` that self-elevates
                                             #   (Touch ID) and prints the flake dir + branch@rev (+ DIRTY) before it builds.
                                             #   No --flake/#attr: modules/parts/hosts.nix plants /etc/nix-darwin/flake.nix,
                                             #   which darwin-rebuild resolves, and the attr defaults to LocalHostName (= macos).
                                             #   `sudo darwin-rebuild switch` works too but names nothing it is about to build.
nix run github:kattakath/nix-config#macos    # FIRST activation only, straight from the flake (before `activate` exists). Self-elevates.
nixos-rebuild switch --flake .#nixpi --target-host ismail@nixpi.kattakath.com
                                             # Activate the Pi: builds HERE (substituting the CI-warmed closure from
                                             #   Cachix), activates THERE. NEVER --build-host — the Pi must not build
                                             #   (hard-blocked by the PreToolUse guard, Rule 1d).
nix develop -c deploy --targets .#nixpi      # Same, via deploy-rs w/ magicRollback: an unreachable Pi auto-reverts
                                             #   instead of needing a physical SD-card pull. ALWAYS --targets (bare
                                             #   `deploy` fans out over every node). --dry-activate to rehearse.
                                             #   `nix develop -c` is NOT optional: deploy-rs is consumed as a flake
                                             #   LIB, so the `deploy` CLI exists only in the devShell
                                             #   (modules/parts/devshell.nix). A bare `deploy` is NOT on PATH and
                                             #   exits 1 with EMPTY output — a silent failure, not a missing-command
                                             #   error. Measured 2026-09-16.
nix run .#nixvm                              # Build + boot the throwaway nixvm XFCE build-vm in a native QEMU window
nix eval .#nixosConfigurations.nixpi.config.system.build.toplevel   # Fast single-target eval

# Bootstrap a clean/reset Mac (no Nix yet): install Determinate Nix, clone, activate #macos.
# `| bash -s -- --check` for a dry run. It does NOT manage SSH keys — a lost machine's
# keypair stays lost and every agenix secret is vendor-re-issuable. See docs/new-mac-runbook.md
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

```

Prefer the `/eval` and `/update-input` commands over retyping the stage→check→evaluate sequence.

## Testing

`nix flake check` **is** the test suite (evaluation of every output + treefmt/statix/deadnix
and ast-grep structural-lint gates). Run it before declaring any change done — a config that
evaluates on one system can still break the other.

- Two-system coverage is mandatory: `aarch64-darwin` and `aarch64-linux`.
- CI (`.github/workflows/nix-ci.yml`) splits it across GitHub-hosted legs DERIVED from the
  fleet's host systems (today 2), and requires the
  aggregate `required-checks` job. Details: [`docs/repo-map.md`](docs/repo-map.md) § CI.
- **Never report a config as passing on a system only CI evaluated.** If `nix` is unavailable
  locally, validate syntax with `nix-instantiate --parse` and say the rest is CI-deferred. The
  SessionStart hook reports which mode you're in.
- **`scripts/drv-snapshot.sh` is the second test** — the acceptance harness ADR-002 built. It
  captures `nix flake show --json`, all three host toplevels, and every package/check drvPath.
  `--out DIR` captures, `--compare DIR` diffs. Use it whenever a change is meant to MOVE code
  without changing what the fleet BUILDS; baselines live in gitignored `.baseline/`. It is
  deliberately **not** a flake package — that would add a `nix flake show` row and perturb the
  baseline it measures.

## Navigating the Codebase

One line per path; the *why* and the per-file specifics are in
[`docs/repo-map.md`](docs/repo-map.md), whose section headings match this table.

| Path | What it owns |
|---|---|
| `flake.nix` | **Inputs/pins and ONE `flake-parts.lib.mkFlake` call — nothing else.** Every output lives in `modules/parts/`. `flake-parts` is a DIRECT input; its `nixpkgs-lib` **cannot** be `follows = ""`. |
| `flake.lock` | Pinned revisions — bump only via `nix flake update` / `/update-input`, never hand-edit. A `follows` edit is **shape-only** (`nix flake lock`, never a bare `nix flake update`), and `follows = ""` REBINDS to this flake rather than removing. |
| `treefmt.nix` | Single source of truth for format + lint-fix (tools that REWRITE); drives `nix fmt`, the CI gate, and the pre-commit hook. |
| `sgconfig.yml` + `ast-grep/` | Report-only structural lint mechanising both layer boundaries: a capsule may not reach **out**, and `modules/shared/` may reach **down** only. Gated by `checks.<system>.ast-grep`, **not** treefmt. |
| `hosts/` | Per-host entry profiles: `macos.nix`, `nixpi.nix`, `nixvm.nix` (host-only deltas + per-host Homebrew lists), plus identity-free `generic-darwin.nix`/`generic-linux.nix` that `templates/` and `checks.<system>.template-consumer` build on. |
| `modules/parts/` | The FLAKE ENGINE — one flake-parts module per concern, discovered by `import-tree`. The engine **may** reach anywhere. |
| `modules/features/` | The seven CAPSULES — six absorbed satellites (`cloudflared-connector`, `firmware-secrets`, `keychain-secrets`, `tart-vms`, `media-cli`, `local-rag`) plus `cloud-cli` (born in-tree 2026-09-20: AWS CLI + `~/.aws/config.example`, never the real file). `flake-module.nix` is the ONLY file anything outside imports, and **a capsule may not reach outside its own directory** — enforced by `ast-grep` + `checks.<system>.capsule-registry`, not by convention. **Satellite count: 0.** |
| `modules/shared/` | The Home Manager profile on every host. Modules that DECLARE a `local.*` option: `mcp.nix`, terminal theme, chromium, default browser, übersicht (the one HTML widget) + next-right-thing (what it says), wireguard, desktop aesthetics (the wallpaper), claude plugins/otel/desktop. Option-free modules that just configure: `home.nix`, nix cache, nix-ld, launchd-launcher, claude brain/bedrock-gate/guardrails — `local.claudeBedrock` was DELETED 2026-09-15, so do not look for it. |
| `modules/darwin/` | macOS system: `core.nix`, `user-folders.nix`, `homebrew.nix` (framework only), `nix-homebrew.nix`, `xcode-license.nix`, `github-runner.nix` (`local.macosGithubRunner` — LIVE, see § Configuration), `ollama-daemon.nix` (`local.ollamaDaemon` — ONE machine-wide `ollama serve`, so every account shares one process and one 31 GB model store), `claude-managed-settings.nix` (`local.claudeManagedSettings` — the root-owned Claude Code MANAGED settings file; `enable = false` DELETES it). |
| `modules/nixos/` | `core.nix` (user + keys-only **loopback-bound** sshd, `openFirewall = false`, a firewall that opens **no** TCP port, avahi, nix-ld, zram, GC), `desktop-vm.nix` (opt-in XFCE for `nixvm`). `nixpi`'s composed posture is GATED — `checks.<system>.nixpi-security-posture` (built on BOTH systems: the edits it guards are made on the Mac). |
| `packages/` | Flake apps/packages: devcontainer image, `nixpi-*` provisioning, `activate` (the self-elevating rebuild above), `spotlight-launchers`, plus single-purpose CLIs. `grok.nix` and `antigravity-cli.nix` are SRI-pinned prebuilt vendor binaries (`grok` also needs `dontFixup` to keep xAI's signature); `fal.nix` ships `fal` + `fal-gen` as ephemeral `uv` envs. These are SHARED via `environment.systemPackages`, not per-user. Root `bootstrap.sh` is the no-Nix stage 1. The media/photo CLIs live in the `media-cli` capsule instead. |
| `infra/` | terranix (Nix → Terraform JSON): `cloudflare/nixpi-tunnel.nix`, `cloudflare/mcp-public.nix`. Applied only via the `cf-*` / `mcp-public-*` apps. |
| `secrets/` | agenix recipients + the operator pubkey + **four** ciphertexts — one operator-only, three host-decrypted on `macos`. Details in § Security. |
| `sites/` | The static sites `nixpi`'s Caddy serves. Referenced by **directory** path literal (`config.fleet.hostedSites[].root`), so every byte lands in the LIVE closure — see [`store-copied-trees`](.claude/rules/store-copied-trees.md). |
| `templates/` | `nix flake init -t` starter that consumes this engine's `lib.mkDarwin` (`identity` + `extraModules`) instead of forking `hosts/`. |
| `skills/` | **Global** skills still in-tree: ONLY the Brain Signals `/explain` family, declared in `modules/shared/claude-brain.nix` next to the output style they encode. Every other global skill arrives from a pinned input. |
| `claude/` + `qwen/` | The **global** (all-projects) agent context this repo installs on `macos` — not to be confused with **this** file, which is project-scoped. |
| `.claude/` | Project agent config — see the lists below. |
| `.github/workflows/` | `nix-ci.yml` (hosted legs DERIVED from the fleet's own host systems), `warm-nixpi-cache.yml` (**keeps the Pi from ever building** — see § Important Notes), `auto-merge.yml`, `build-*`, `claude*.yml`, `gitleaks.yml`, `flakehub-publish.yml`, `update-flake-lock.yml`. |
| `docs/` | Runbooks + design docs — indexed at the bottom of this file. |

**Gone on purpose — do not re-add.** There is no `plugins/` tree (the operator's marketplace is
`github:kattakath/ai`, pinned as `kattakath-ai`), and the fleet declares **zero userscripts**
(published to Greasy Fork instead, so an installed copy self-updates — which a Nix-materialised
`file://` copy never could). Both:
[`docs/agent-resource-externalization.md`](docs/agent-resource-externalization.md).

**Commands** (`.claude/commands/`): `/eval`, `/hygiene`, `/update-input`, `/superhook-review`,
`/pretooluse-review`, `/remember-nix`, `/gmail-account`, `/routing-review`, `/mcp-scout`,
`/fleet-doctor`, `/userscript`. (`/devtools` and `/pick` ship from the `page-lab` plugin instead.)

**Project skills** (`.claude/skills/`): `nix-hygiene`, `nixpi-firmware-provision`,
`jsonresume-tailor`, `gmail-mcp-accounts`, `mcp-scout`, `fleet-doctor`, `userscript-author`.

**Always-applied rules** (`.claude/rules/`):
[`git-purity`](.claude/rules/git-purity.md) (stage `.nix` before eval),
[`pr-title`](.claude/rules/pr-title.md) (title = comma-separated touched components; one PR per
change, off `main`),
[`launchd-naming`](.claude/rules/launchd-naming.md) (every launchd unit exposes a `nix-<kebab>`
`arg0` — never a bare `sh`/`python3`),
[`upstream-first`](.claude/rules/upstream-first.md) (grep the **pinned** input's option surface
before writing custom Nix, and cite the result — plus, for a CLI or wrapper, check whether a
community TOOL already owns it, which an option grep structurally cannot see). Scoped to `sites/**`:
[`store-copied-trees`](.claude/rules/store-copied-trees.md) (a directory path literal copies
the whole tree into the store — check for stray `.DS_Store`/etc. before committing).

**Hooks** (`.claude/hooks/`): `stop-gate.js` + `pretooluse-bash-guard.js` (both wrapped by the
`superhook` PATH package, since a checked-in `settings.json` can hold neither a store path nor
`${CLAUDE_PLUGIN_ROOT}`), plus the `*-digest.js` SessionStart nudges. `autostage-nix` and
`nix-home-path-lint` arrive as PLUGIN hooks from `claude-code-nix@kattakath` — do not re-add them
here or each fires twice. The guard's case suites are `.claude/hooks/tests/*.sh`, **gated by
`claude-config-lint.yml`** — they assert both halves (must-BLOCK and must-stay-APPROVED) and that
the hook never throws, because a throw fails OPEN and silently disarms every rule. Message
decoder: [`docs/claude-hook-messages.md`](docs/claude-hook-messages.md).
All of the above is **project-scoped** — it guards sessions in THIS repo only. Policy that is
wrong in EVERY repo sits in two wider tiers instead: user-scope `permissions.deny` in
`modules/shared/claude-guardrails.nix`, and above it the root-owned MANAGED file
`modules/darwin/claude-managed-settings.nix` (`macos` only) — a managed deny cannot be
retracted by any lower scope, and every per-key precedence sentence in claude-code 2.1.260
puts managed first. It carries the secret-value denies + attribution keys. Deny lists from
every scope COMBINE, so that duplication is deliberate, not drift.

**MCP servers**: one localhost `mcp-proxy` gateway (`modules/shared/mcp.nix`, darwin-only) on
`127.0.0.1:8096` hosting every server as HTTP; `desktop-commander` and `open-design` stay
per-client stdio. There is **no project `.mcp.json`**. Inventory + gotchas:
[`docs/mcp-gateway.md`](docs/mcp-gateway.md).

## Code Style & Conventions

- **Naming:** kebab-case files; `lowerCamelCase` Nix bindings; modules named by the
  platform/concern they own.
- **Platform branching:** isolate in `modules/` via `lib.mkIf` on
  `stdenv.hostPlatform`/`isDarwin`/`isLinux` — host profiles stay declarative and
  platform-agnostic.
- **Paths — two axes, never conflate them:** a Nix **source path literal**
  (`source = ../../claude/CLAUDE.md;`, `callPackage ../../packages/x.nix`,
  `"${../../claude/CLAUDE.md}"`) is resolved **relative to the `.nix` file at evaluation time**,
  content-hashed, and copied into `/nix/store` — it **must** be repo-relative (or a store
  path); `$HOME`/XDG is impossible here (`$HOME` is undefined at eval, and a runtime home path
  is neither reproducible nor store-addressable). A `../..` source literal is **correct and
  idiomatic — never "fix" it to a home path.** The `$HOME`/XDG rule applies only to the *other*
  axis: **runtime paths** — where a program reads/writes or files land at runtime (`home.file`
  TARGET keys are `$HOME`-relative by definition; env vars like
  `BUKU_DEFAULT_DBDIR = "$HOME/Developer/…"`; data dirs). Those must be `$HOME`/XDG-relative,
  **never a hardcoded `/Users/<name>` or `/home/<name>`** (such a literal in a `.nix` *value* —
  not a comment — is the real anti-pattern to reject, and the `claude-code-nix` plugin's
  `nix-home-path-lint` hook flags it).
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
  value ever reaches argv or the store. **Durable copy (ADR-004, off by default):**
  `local.keychainSecrets.backend.type = "gcp"` adds `secrets-{status,rehydrate,push,resolve}` over
  GCP Secret Manager — operator-invoked after `gcloud auth login`, **never by activation**
  (`ast-grep/rules/activation-must-not-touch-secrets.yml`). Project id is read from `gcloud`
  at runtime, never a Nix string.
- **Never display a secret value** — using one is fine, echoing/logging/committing it is not.
- Mechanism, history, and the two documented loader footguns:
  [`docs/secrets-and-keychain.md`](docs/secrets-and-keychain.md).

## Configuration

How a host gets composed — change these knobs, not the hosts' internals:

- **Identity once.** `loginName = "ismail"`, `domainName = "kattakath.com"`, `fullName`,
  `userEmail` are `identityArgs` in `modules/parts/identity.nix`, threaded through
  `specialArgs`/`extraSpecialArgs`. Those four are a **closed** typed submodule, so a fifth
  field fails at eval here instead of in a template consumer's build. The CANONICAL identity is `config.fleet.googleAccount`
  (the Workspace account — GitHub, FlakeHub, Cloudflare Access and Secret Manager all trace
  to it; [`docs/identity-and-offboarding.md`](docs/identity-and-offboarding.md)); it is a fleet
  constant, deliberately NOT in `identityArgs`. `mkDarwin` accepts a per-host `identity` override, but
  **nothing in the fleet uses it** — every host runs the same operator identity.
- **Per-host divergence is a gate, not a fork.** `networking.hostName`-gated `lib.mkIf` (or
  `osConfig`) inside `modules/`; never a second identity, never a copy-pasted host block.
- **No private layer any more.** `lib.mkDarwin { extraHomeModules }` / `mkNixos { hostedSites }`
  are still generic, optional composition hooks (both default to `[ ]`), but the private
  nix-personal flake that used to fill them was retired 2026-09-15 — its values (AWS SSO
  profiles, extra gmail accounts, git identities, the OpenAI gateway, the real `hostedSites`)
  were folded directly into `hosts/macos.nix` and `modules/parts/identity.nix` — and on
  2026-09-20 (ADR-004) the AWS profiles and the personal git-identity files left Nix again for
  hand-placed local files (`~/.aws/config`, `~/.config/git/{silvercreek,izzykatt}.inc`,
  `allowed_signers`): the repo ships shape, the operator's content stays on the Mac. See
  [`docs/repo-map.md`](docs/repo-map.md).
- **Whole features are ONE enable flag — and they are all IN-TREE now.** The media stack
  (`local.mediaCli`) and the Keychain secret store (`local.keychainSecrets`) are each one
  switch: `local.mediaCli.enable = false` removes the CLIs, both launchd agents, the Finder
  Services and the companion tools together — no orphaned package, no dangling session variable,
  no stale menu item to hunt down. **They no longer arrive as flake INPUTS.** ADR-002 absorbed
  all seven satellites as `modules/features/<name>/` capsules (waves 3-6) and the origin repos
  are archived, so "feature X plugs in as an input" is false for every one of them.
- **Binary cache:** the public `kattakath` Cachix cache is consumed tokenless by every host
  (`modules/shared/nix-cache.nix`); only CI and the operator's Keychain hold the write token.
- **`macos` runs self-hosted CI runners — two kinds, neither for this repo's CI.**
  (1) `local.macosGithubRunner` (`modules/darwin/github-runner.nix`, `count = 2`): bare-metal
  ephemeral org runners for **`dontsell-ai`**'s nix/cachix/pgvector-heavy CI. (2) `local.tart.githubRunners.*`
  (the `tart-vms` capsule's `github-runner.nix`, configured in `hosts/macos.nix`): **ephemeral
  Tart-VM-per-job** runners for `kattakath` + `silvercreek-ai` + `dontsell-ai` (label
  `dontsell-vm`), sharing Apple's hard 2-concurrent-VM budget via a slot semaphore. Both mint ~1h
  tokens from GitHub App keys (agenix); since 2026-09-06 **both lanes share ONE App**,
  `ismailkattakath-ci` (appId 4849830, operator-owned + public), which replaced the retired
  `kattakath-fleet-ci` (4845230), `kattakath-ci` (4243998) and `dontsell-ai` (4689619). The **GitLab**
  lane rides the same budget: `local.tart.gitlabRunner` (the same capsule's `gitlab-runner.nix`) runs
  gitlab-runner declaratively, rendering its config at agent start from the agenix
  `gitlab-runner-token.age`. **This repo's own CI uses none of them** — `nix-ci.yml` is 100%
  GitHub-hosted.

## Using Subagents

Agent definitions live in `.claude/agents/` (project) — today just `terranix-infra-reviewer`.

| Situation | Use |
|---|---|
| Explain architecture / get the big picture | `cartographer` agent (read-only, ASCII diagrams) |
| Touching `infra/**.nix`, or **before any** `cf-tunnel-apply` / `mcp-public-apply` | `terranix-infra-reviewer` agent — reviews + plans, never applies |
| "Does it evaluate?" | `/eval` (stage + `nix flake check`) — no agent needed |
| LEAN/DRY/doc-drift cleanup | `/hygiene` → skill `nix-hygiene` (audit → fix → gate) |
| Cross-repo fleet sweep | `/fleet-doctor` (repos listed in `.claude/skills/fleet-doctor/fleet-repos.txt`) |
| Adopt an MCP server | `/mcp-scout` → skill `mcp-scout` (declare in `mcp.nix`, never install imperatively) |

## Important Notes

- **Flakes ignore untracked files.** A new `.nix` not yet `git add`ed is invisible to
  `nix flake check` and fails with confusing "file not found" / stale-eval errors. ALWAYS
  `git add` before evaluating — enforced by [git-purity](.claude/rules/git-purity.md) and the
  Stop hook.
- **`nixpi` is LIVE, and it must NEVER build.** It is a Pi 4 on an SD card: a build there is
  slow, and a power cut mid-build corrupts the card, which needs hands on the hardware to
  reflash (~40 min) — defeating the remotely-managed design. So the Pi only ever
  **substitutes**. `.github/workflows/warm-nixpi-cache.yml` builds the toplevel on a real
  `ubuntu-24.04-arm` runner and pushes the closure to Cachix on **every** nixpi-closure change
  (including `sites/**` and `modules/parts/**`); after it lands, both the Mac and the Pi fetch
  rather than build. Sanctioned commands: `nixos-rebuild switch --flake .#nixpi --target-host
  ismail@nixpi.kattakath.com` (builds HERE, activates there) or `nix develop -c deploy
  --targets .#nixpi` (devShell-only — a bare `deploy` is not on PATH and fails silently).
  **Building on the Pi is hard-blocked** by `.claude/hooks/pretooluse-bash-guard.js` (Rule 1d):
  `--build-host <pi>`, `deploy --remote-build`, `ssh <pi> nix build`, `--builders ssh://<pi>`.
  - **If the Mac plans a BUILD instead of a fetch, the cache is merely not warm yet** — or Nix
    negatively cached an earlier 404 (`narinfo-cache-negative-ttl`, default **1 h**), which
    makes an already-warmed cache look broken. Retry with `--narinfo-cache-negative-ttl 0`;
    never "fix" it by moving the build onto the Pi. Only on a genuine miss does nixpkgs' caddy
    `Caddyfile-formatted` EPERM appear (§ aarch64-linux builds, below).
- `deploy.nodes.nixpi` and the `cf-tunnel-*`/`mcp-public-*` terranix apps all render this repo's
  real data directly now (the private nix-personal flake that used to gate this was retired
  2026-09-15) — `mkCfTunnelTofu` and `mkMcpPublicTofu` still **refuse** a render that would blank
  an already-provisioned tunnel or unpublish a live server (overrides:
  `CF_TUNNEL_ALLOW_SITE_FREE=1` / `MCP_PUBLIC_ALLOW_EMPTY=1`) — that guard stays as a "do you
  really mean to destroy this" check. Bare `deploy` with no `--targets` still fans out over
  **every** node — always name the target.
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
  Virtualization; ephemeral VM, **1 CPU / 8 GiB by default**). The account entitlement is
  enabled at https://dtr.mn/features; the VM itself **is** settable from Nix since the pinned
  `determinate` module grew `determinateNix.determinateNixd.builder.{state,memoryBytes,cpuCount}`
  (rendered to `/etc/determinate/config.json`) — only the raw `external-builders` line is
  reserved and rejected by `customSettings`. Upstream says do **not** change `cpuCount`;
  `memoryBytes` is the knob if a Linux build ever OOMs. nix-darwin's `nix.linux-builder` is
  unusable because it needs `nix.enable = true`, which Determinate disables (nix-darwin#1505).
  It also **cannot run `cp --no-preserve=mode` into `$out`** (EPERM "setting permissions"),
  which breaks nixpkgs' caddy `Caddyfile-formatted` and therefore every Mac-side build of a
  Caddy-serving `nixpi` generation. Measured 2026-09-15: **only that one operation fails** —
  `cat >`, `install -m` and `cp` + `chmod` all succeed on the same builder, so this is a narrow
  (undocumented, unreported) builder bug, not a general chmod ban. **Do not work around it by
  building on the Pi** — `warm-nixpi-cache.yml` builds the closure on a real ARM Linux runner
  and pushes it to Cachix, so the Mac substitutes and never runs that `cp` at all.
  **Account entitlement alone is not enough** — the local `determinate-nixd` must also be
  logged in to FlakeHub, or `native-linux-builder` silently vanishes and every aarch64-linux
  build fails with a `platform mismatch` that looks unrelated to auth. Manual, per-machine step:
  see "Manual steps Nix can't do" in
  [`docs/new-mac-runbook.md`](docs/new-mac-runbook.md). Heavy multi-core
  builds (e.g. the Pi SD image) still go to GitHub CI / Cachix.

## Documentation

- [`docs/repo-map.md`](docs/repo-map.md) — **the full fleet architecture**: every path, module,
  package and flake output, with the reasoning. The long form of § Navigating the Codebase.
- [`docs/mcp-gateway.md`](docs/mcp-gateway.md) — the localhost MCP gateway: server inventory,
  credentials model, opt-ins, how to add one.
- [`docs/mcp-public-exposure-design.md`](docs/mcp-public-exposure-design.md) — **BUILT and live**:
  `local.mcpGateway.public` flips a server public via a **second** proxy on `:8097`, behind one
  connector + one Access app + one service token. **Exactly two hostnames, and they never grow
  per server.** §9 is its correction record.
- [`docs/secrets-and-keychain.md`](docs/secrets-and-keychain.md) — agenix operator-only vault +
  the login-Keychain loader and the `secret` CLI.
- **ADRs, in order** — [`ADR-001`](docs/flake-architecture-strategy-adr.md) (flake-parts for the
  small supporting flakes; **superseded in part**, and its objection 3 still stands);
  [`ADR-002`](docs/monoflake-capsule-adr.md) (decided **and implemented**: absorbed all seven
  satellites onto flake-parts + `import-tree` as capsules — **read §9 first**, the record of what
  execution found the design got wrong); [`ADR-003`](docs/externalization-boundary-adr.md)
  (decided, **NOT implemented**: Nix is the **harness**, governance never leaves; skills MAY
  overlay from `$HOME`, **MCP servers may not**).
  [`ADR-004`](docs/secrets-recovery-and-identity-adr.md) (decided, **Phase 1 of 3 shipped — docs
  and `OPERATOR-ONLY` markers only**: GCP Secret Manager as the durable source of truth with the
  login Keychain as cache, Google Workspace canonical, namespace rename + repo split deferred with
  triggers; §7 is the committed-identifier inventory awaiting approval, §8 the open conflicts).
- [`docs/identity-and-offboarding.md`](docs/identity-and-offboarding.md) — the single lever:
  suspend the Workspace account and every derived login goes with it; the three privilege tiers.
- [`docs/agent-resource-externalization.md`](docs/agent-resource-externalization.md) — why the
  operator's plugins, skills and userscripts left this tree while the seven satellites came back
  in, and the rule it turned on: **a gate must move with the content it gates.**
- [`docs/nixpi-sd-flashing-runbook.md`](docs/nixpi-sd-flashing-runbook.md) — flashing the `nixpi`
  SD card (full verified `dd` write).
- [`docs/new-mac-runbook.md`](docs/new-mac-runbook.md) — standing up `macos` from a wiped
  Mac (no key recovery: rotate, don't transport); also the manual steps Nix can't do.
- [`docs/macvm-readd-runbook.md`](docs/macvm-readd-runbook.md) — re-adding the removed `macvm`
  Tart guest (2026-09-05); what survives in the `tart-vms` capsule.
- [`docs/gmail-mcp-multi-account-runbook.md`](docs/gmail-mcp-multi-account-runbook.md) — TRUE
  simultaneous multi-account Gmail + a silent-wrong-account failure mode.
- [`docs/claude-code-observability-runbook.md`](docs/claude-code-observability-runbook.md) — local
  OTel for Claude Code's own `tool_decision` telemetry + the `/routing-review` loop.
- [`docs/claude-hook-messages.md`](docs/claude-hook-messages.md) — decoder for this repo's hook
  messages (why DENYs read as "errors", how to read a prompt-hook denial).
- [`docs/claude-desktop-instructions.md`](docs/claude-desktop-instructions.md) — the one Claude
  behaviour this repo can't manage declaratively + the canonical "diagrams as ASCII" wording.
- [`docs/answer-shape-evidence.md`](docs/answer-shape-evidence.md) — the published standards
  (COGA, ISO 24495-1, BDA) and measured effect sizes behind § Answer shape, so the rules stop
  being re-litigated as taste. **A diagram that carries no data measurably HURTS** (g ≈ −0.4).
- [`docs/terminal-theme.md`](docs/terminal-theme.md) — the one terminal palette: provider
  contract, per-surface coverage (**4/16** on Terminal.app is an OS ceiling), and the measured
  reasons stylix and base16.nix were both rejected.
- [`docs/macos-settings-surface.md`](docs/macos-settings-surface.md) — what `macos` can configure
  declaratively, and the TCC/FileVault walls.
- [`docs/mcp-gateway-accessibility-tcc.md`](docs/mcp-gateway-accessibility-tcc.md) — the one-time
  Accessibility (TCC) grant `macos-automator` needs.
- [`docs/open-design.md`](docs/open-design.md) — OpenDesign's declared/imperative boundary: cask +
  updater kill-switch + per-client stdio MCP vs. the app's mutable state.
- [`docs/photo-system.md`](docs/photo-system.md) — the photo retrieval system end to end: the
  durable/derived split between what `photo-describe` writes and what `rclip` keeps, and how to
  search each.
- [`docs/auto-merge-and-merge-queue.md`](docs/auto-merge-and-merge-queue.md) — how every fleet
  flake merges itself once CI is green (CI bot App token, ruleset, `merge_group:`).
- [`docs/flakehub-input-freshness.md`](docs/flakehub-input-freshness.md) — the automated weekly
  `flake.lock` bump flow.
- [`docs/nix-media-cli-extraction-grant.md`](docs/nix-media-cli-extraction-grant.md) + its
  [study](docs/nix-media-cli-extraction-study.md) — **HISTORY, not a plan**: extracted in 2026-09,
  then ADR-002 brought the whole stack back in-tree as the `media-cli` capsule. Only the
  `media-<verb>` rename is still undecided, and it is this repo's call again.
