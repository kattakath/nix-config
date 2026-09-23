This is `kattakath/nix-config` — the all-in-one, public Nix mono-repo that declaratively
manages Ismail's entire aarch64-only fleet: one client Mac, one live Raspberry Pi server, a
disposable NixOS dev VM, and a devcontainer image. Everything below is
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
  reinvented under a different name. The `media-cli` capsule's `media-queue.nix` and
  `module.nix` headers are the running log of exactly this: what is genuinely custom there, the
  research that justified it, and the table proving every queue mechanism is launchd's own —
  which is why 1,300 lines of queue contain no scheduler of ours.
- **Proprietary monoliths, avoided:** a broker-based job queue, a bespoke supervision daemon,
  or any other heavy framework is *also* a violation of this motto when it's bigger than the
  problem warrants — reuse cuts both ways. The right-sized community Lego, not the fanciest
  one available.

## Overview

Fully declarative **aarch64-only** fleet, single source of truth, platform divergence in
`modules/` (never ad-hoc shell):

| Host | System | Role |
|---|---|---|
| `macos` | aarch64-darwin | The sole client Mac (nix-darwin). **ONE account**: `ismail` (`system.primaryUser`) — never a second (one existed 2026-09-15→17, deleted forever). No incoming traffic; it is the SSH *client*, reaching `nixpi` via `cloudflared access ssh`. Builds `aarch64-linux` locally on Determinate's native Linux builder. |
| `nixpi` | aarch64-linux | **LIVE server** (NixOS on a Pi 4): Access-gated, loopback-bound SSH over a Cloudflare Tunnel connector + Caddy, serving its ONE site directly (`config.fleet.hostedSites`, `modules/parts/identity.nix`). Runs **Determinate Nix** (nixosModule, since 2026-09-21) with `nix.settings` still live; the prebuilt Nix substitutes from `install.determinate.systems`. |
| `nixvm` | aarch64-linux | Unprovisioned XFCE build-vm, **only** as `nix run .#nixvm`. No installed disk, no builder, no runner — but its root disk PERSISTS in `$XDG_STATE_HOME/nixvm`. |
| devcontainer | +`x86_64-linux` | The one exception to aarch64-only, so it runs on x86_64 Codespaces. |

Full map: [`docs/repo-map.md`](docs/repo-map.md).

## Build & Commands

```bash
git add -A                                   # MANDATORY before any eval — flakes ignore untracked files
nix flake check --all-systems --no-build     # Evaluate every output on BOTH systems, build nothing — a bare check on the
                                             #   Mac silently OMITS aarch64-linux ("incompatible systems"), measured 2026-09-21
nix flake check                              # Builds them — THE SUITE. The --no-build line RUNS no check; run BOTH lines
nix flake show                               # List exported darwin/nixosConfigurations + packages
nix fmt                                      # Format + lint-fix all .nix via treefmt (nixfmt + statix + deadnix)
nix develop                                  # Dev shell (nixd LSP, treefmt, home-manager); installs pre-commit hooks
nix build .#checks.<system>.formatting       # CI formatting/lint gate
nix build .#checks.<system>.ast-grep         # Structural-lint gate (BLOCKS, no autofix; ast-grep/rules/)
ast-grep scan --no-ignore hidden .           # Same scan by hand (devShell); without --no-ignore hidden, .claude/ is SKIPPED
ast-grep test --skip-snapshot-tests          # Prove each rule still fires (fixtures in ast-grep/rule-tests/)
nix build .#checks.<system>.capsule-registry # readDir modules/features == the capsules import-tree loaded
nix build .#checks.<system>.claude-md-budget # THIS file must stay under 40,000 BYTES (wc -c) — a GATE
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
                                             #   `nix develop -c` is NOT optional: deploy-rs is a flake LIB, so the
                                             #   CLI exists only in the devShell. A bare `deploy` exits 1 with EMPTY
                                             #   output — silent failure, not "command not found". Measured 2026-09-16.
nix run .#nixvm                              # Build + boot the nixvm XFCE build-vm in a QEMU window (root disk PERSISTS)
nix eval .#nixosConfigurations.nixpi.config.system.build.toplevel   # Fast single-target eval

# Bootstrap a clean/reset Mac (no Nix yet): install Determinate Nix, clone, activate #macos.
# On a RESET Mac run `| bash -s -- --check` FIRST — it names the leftover "Nix Store" volume
# that forces a reboot + a manual re-run mid-bootstrap. It does NOT manage SSH keys — a lost
# keypair stays lost, every agenix secret is vendor-re-issuable. See docs/new-mac-runbook.md
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash

# nixpi SD card
nix build .#nixosConfigurations.nixpi.config.system.build.sdImage   # aarch64-linux; builds on the native Linux builder, or use --release
nix run .#nixpi-flash -- --disk /dev/diskN --release   # Download the CI-prebuilt image → verified dd → auto-plant token+wifi on FIRMWARE
nix run .#nixpi-provision                     # Plant/update token + Wi-Fi on a mounted card (--token / --wifi)
# Flashing: do a FULL verified write (confirm dd's ~5.6GB byte count) — see docs/nixpi-sd-flashing-runbook.md
# Companions: nixpi-wifi-creds (emit wpa_supplicant.conf from this Mac), nixpi-vault-token (re-encrypt a rotated token)

# terranix — 6 stacks, 5 on one GCS backend. Run inside `nix develop` or tofu picks the WRONG ADC.
# ALWAYS *-plan first — every stack has one. Every *-destroy is hard-blocked by the guard.
CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-tunnel-{plan,apply}        # nixpi's tunnel + ingress + CNAME; apply PRINTS the connector token
CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-zones-{plan,apply}         # kattakath.com DNS records
CLOUDFLARE_API_TOKEN=<scoped> nix run .#mcp-public-{plan,apply,sync,token}  # published MCP gateway; `sync` re-polls the portal
CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-access-org-{import,plan,apply}  # Zero Trust org; `import` FIRST or plan/apply refuse
nix run .#gcp-{foundation,budget}-{plan,apply}              # GCP APIs/SA/state bucket; the 5 CAD spend ALERT

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
| `sgconfig.yml` + `ast-grep/` | SIX rules, every one `severity: error` — a match FAILS the build; "report-only" means only that it never REWRITES a file. Two are the layer boundaries (a capsule may not reach **out**; `modules/shared/` may reach **down** only); the rest guard hardcoded home paths, launchd bare-interpreter `arg0`, unguarded `JSON.parse` in hooks, and activation touching secrets. Gated by `checks.<system>.ast-grep`, **not** treefmt. |
| `hosts/` | Per-host entry profiles: `macos.nix`, `nixpi.nix`, `nixvm.nix` (host-only deltas + per-host Homebrew lists), plus identity-free `generic-darwin.nix`/`generic-linux.nix` that `templates/` and `checks.<system>.template-consumer` build on. |
| `modules/parts/` | The FLAKE ENGINE — one flake-parts module per concern, discovered by `import-tree`. The engine **may** reach anywhere. |
| `modules/features/` | The seven CAPSULES — six absorbed satellites (`cloudflared-connector`, `firmware-secrets`, `keychain-secrets`, `tart-vms`, `media-cli`, `local-rag`) plus `cloud-cli` (born in-tree 2026-09-20: AWS CLI + `~/.aws/config.example`, never the real file). `flake-module.nix` is the ONLY file anything outside imports, and **a capsule may not reach outside its own directory** — enforced by `ast-grep` + `checks.<system>.capsule-registry`, not by convention. **Satellite count: 0.** |
| `modules/shared/` | The Home Manager profile on every host. Modules that DECLARE a `local.*` option: `mcp.nix`, terminal theme, chromium, default browser, übersicht (the one HTML widget) + next-right-thing (what it says), wireguard, desktop aesthetics (the wallpaper), containers (`local.containers` — per-user Colima), claude plugins/otel/desktop/code-settings, metube + yt-dlp-web-ui (the two loopback download servers — moved off `launchd.user.agents` 2026-09-22 for the agent self-heal only Home Manager does). Option-free modules that just configure: `home.nix`, nix cache, nix-ld, launchd-launcher, claude brain/bedrock-gate/guardrails — `local.claudeBedrock` was DELETED 2026-09-15, so do not look for it. |
| `modules/darwin/` | macOS system: `core.nix`, `user-folders.nix`, `homebrew.nix` (framework only), `nix-homebrew.nix`, `xcode-license.nix`, `launchd-reconcile.nix` (option-free — re-bootstraps a `launchd.daemons` unit that left the domain, at switch AND boot; nix-darwin's activation is diff-gated and never does), `logging.nix` (EVERY launchd log, agents AND daemons: `system.newsyslog` rename+create for the ones that re-exec, `logrotate --copytruncate` on an hourly tick for the long-lived ones — launchd's fd is **O_APPEND**, so truncating reclaims where renaming cannot), `github-runner.nix` (`local.macosGithubRunner` — LIVE, see § Configuration), `ollama-daemon.nix` (`local.ollamaDaemon` — ONE machine-wide `ollama serve`, so every account shares one process and one 31 GB model store), `claude-managed-settings.nix` (`local.claudeManagedSettings` — the root-owned Claude Code MANAGED settings file; `enable = false` DELETES it). |
| `modules/nixos/` | `core.nix` (user + keys-only **loopback-bound** sshd, `openFirewall = false`, a firewall that opens **no** TCP port, avahi, nix-ld, zram, GC), `desktop-vm.nix` (opt-in XFCE for `nixvm`). `nixpi`'s composed posture is GATED — `checks.<system>.nixpi-security-posture` (built on BOTH systems: the edits it guards are made on the Mac). |
| `packages/` | Flake apps/packages: devcontainer image, `nixpi-*` provisioning, `activate` (the self-elevating rebuild above), `spotlight-launchers`, plus single-purpose CLIs. `launchd-doctor` reports what `nix flake check` structurally cannot: drift **both ways** — declared-but-not-loaded, and loaded-but-in-no-generation, which nix-darwin’s single-transition removal loop orphans permanently — plus non-zero exits, log growth, disabled-DB and log orphans. `grok.nix`/`antigravity-cli.nix` are SRI-pinned prebuilt vendor binaries, SHARED via `environment.systemPackages`, not per-user. Root `bootstrap.sh` is the no-Nix stage 1; the media/photo CLIs live in the `media-cli` capsule. |
| `infra/` | terranix (Nix → Terraform JSON). Six stacks: `cloudflare/{nixpi-tunnel,mcp-public,zones,access-org}.nix` (+ `kattakath-dns.nix`, records as data), `gcp/{foundation,budget}.nix`. Applied only via the `cf-*`/`mcp-public-*`/`gcp-*` apps; state in GCS for five, `gcp-foundation` local (§ Important Notes). |
| `secrets/` | agenix recipients + the operator pubkey + **four** ciphertexts — one operator-only, three host-decrypted on `macos`. Details in § Security. |
| `sites/` | TWO trees, ONE Caddy-served: `snoringirl` (`config.fleet.hostedSites[].root`, a **directory** literal, so every byte lands in the LIVE closure — [`store-copied-trees`](.claude/rules/store-copied-trees.md)). `ismail-landing` is NOT served: `next-right-thing.nix`'s fonts. |
| `templates/` | `nix flake init -t` starter that consumes this engine's `lib.mkDarwin` (`identity` + `extraModules`) instead of forking `hosts/`. |
| `claude/` | The **global** (all-projects) agent context this repo installs on `macos` (`CLAUDE.md` + one rule — plugins cannot carry either) — not to be confused with **this** file, which is project-scoped. |
| `.claude/` | Project agent config — see the lists below. |
| `.github/workflows/` | `nix-ci.yml` (hosted legs DERIVED from the fleet's own host systems), `warm-nixpi-cache.yml` (**keeps the Pi from ever building** — see § Important Notes), `auto-merge.yml`, `build-*`, `claude*.yml`, `gitleaks.yml`, `flakehub-publish.yml`, `update-flake-lock.yml`. |
| `docs/` | Runbooks + design docs — indexed at the bottom of this file. |

**Gone on purpose — do not re-add.** No `plugins/` or `skills/` tree: both live in
`github:kattakath/skills`, installed as an **auto-updating git marketplace** (a merge there
ships, no pin bump here) and pinned as `kattakath-skills` only for the `superhook` /
`page-lab-pick` PATH packages; **zero userscripts** (published to Greasy
Fork, so an installed copy self-updates). Why:
[`docs/agent-resource-externalization.md`](docs/agent-resource-externalization.md).

**Commands** (`.claude/commands/`): `/eval`, `/hygiene`, `/update-input`, `/superhook-review`,
`/pretooluse-review`, `/remember-nix`, `/gmail-account`, `/routing-review`, `/mcp-scout`,
`/fleet-doctor`, `/userscript`. (`/devtools` and `/pick` ship from the `page-lab` plugin instead.)

**Project skills** (`.claude/skills/`): `nix-hygiene`, `nixpi-firmware-provision`,
`gmail-mcp-accounts`, `mcp-scout`, `fleet-doctor`, `userscript-author`.

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
here or each fires twice. `.claude/hooks/tests/*.sh` covers BOTH hooks — three guard-rule suites plus
`stop-gate-fail-closed.sh` — **gated by `claude-config-lint.yml`**: each asserts both halves
(must-BLOCK and must-stay-APPROVED) and that it never throws, since a throw fails OPEN. Message
decoder: [`docs/claude-hook-messages.md`](docs/claude-hook-messages.md).
All of the above is **project-scoped** — it guards sessions in THIS repo only. Policy that is
wrong in EVERY repo sits in two wider tiers: user-scope `permissions.deny` in
`modules/shared/claude-guardrails.nix`, and above it the root-owned MANAGED file
`modules/darwin/claude-managed-settings.nix` (`macos` only; secret-value denies + attribution
keys) — a managed deny cannot be retracted by any lower scope. Deny lists from every scope
COMBINE, so that duplication is deliberate, not drift.

**MCP servers**: ONE `mcp-proxy` gateway (`modules/shared/mcp.nix`, darwin-only) on
`127.0.0.1:<publicMcpPort>` hosting all 26; no per-client stdio servers remain. Clients declare
ONE connector — the portal at `https://mcp.<domainName>/mcp` — not a server list;
`checks.*.mcp-published-parity` holds hosted == `fleet.publicMcpServers`. No project
`.mcp.json`. Inventory: [`docs/mcp-gateway.md`](docs/mcp-gateway.md).

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
  rather than build. The only sanctioned activations are the `--target-host` and
  `deploy --targets` lines in § Build & Commands. **Building on the Pi is hard-blocked** by `.claude/hooks/pretooluse-bash-guard.js` (Rule 1d):
  `--build-host <pi>`, `deploy --remote-build`, `ssh <pi> nix build`, `--builders ssh://<pi>`.
  - **If the Mac plans a BUILD instead of a fetch, the cache is merely not warm yet** — or Nix
    negatively cached a 404 (`narinfo-cache-negative-ttl`, default **1 h**), which makes a
    warmed cache look broken. Retry with `--narinfo-cache-negative-ttl 0`; never "fix" it by
    moving the build onto the Pi.
- `deploy.nodes.nixpi` and the `cf-tunnel-*`/`mcp-public-*` terranix apps all render this repo's
  real data directly now — `mkCfTunnelTofu` and `mkMcpPublicTofu` still **refuse** a render that would blank
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
- **OpenTofu state is the fragile part of the edge, not the config.** State was lost **twice**
  to `tofu` running in whatever the CWD happened to be. Since ADR-005 five of the six share a
  **GCS backend** (`fleet.gcpStateBucket`, versioned) **encrypted** with a Keychain passphrase
  (`tofu:state:passphrase`) — the state PAYLOAD holds a connector token and an Access
  service-token secret, which is why encryption is not optional and why **losing that
  passphrase makes all state unreadable**. `gcp-foundation` alone
  keeps **local** (still encrypted) state: it declares that bucket. Never apply before a
  `plan` reads clean.
- **Magic rollback** (`deploy.nodes.nixpi.magicRollback = true`): a change that kills sshd, the
  tunnel or networking becomes a *failed deploy* — the Pi reverts **itself** unless the deployer
  reconnects and confirms. `--target-host` has no such undo. Detail: `docs/repo-map.md`.
- `home-manager switch` activates and is hard to reverse; prefer `build` to verify, and
  `switch` only when explicitly asked. `home-manager generations` lists,
  `home-manager rollback` reverts.
- **`nix run .#nixvm` is the only way `nixvm` is ever booted** — a `nixos-rebuild build-vm`
  runner exposed as a flake app (XFCE desktop, native QEMU/Cocoa window on macOS, no
  macOS-guest path, no VM config outside Nix, no builder VM and no runner on it). **Not
  stateless:** only the Nix store image is rebuilt per boot — the ROOT disk, so `/home`, persists
  in `$XDG_STATE_HOME/nixvm/nixvm.qcow2` until you `rm` it. The app's wrapper pins it there
  because upstream would resolve it against YOUR CWD, i.e. a different VM per directory.
- **aarch64-linux builds on the Mac** go to Determinate's **native Linux builder** (Apple
  Virtualization; ephemeral VM, 1 CPU / 8 GiB). Two traps: `determinate-nixd` logged OUT of
  FlakeHub silently kills the builder, and every build then fails as `platform mismatch`; and
  `cp --no-preserve=mode` into `$out` EPERMs, which breaks nixpkgs' caddy `Caddyfile-formatted`
  and so every Mac-side build of a Caddy-serving `nixpi` generation. **Never fix that by
  building on the Pi** — CI warms the cache so the Mac substitutes instead. `memoryBytes` (not
  `cpuCount`) is the OOM knob. Measurements, and why it is NOT a general chmod ban:
  [`docs/repo-map.md`](docs/repo-map.md) § Building aarch64-linux on the Mac.

## Documentation

Every `docs/*.md` is listed and annotated in
[`docs/repo-map.md`](docs/repo-map.md) § Documentation index — that is the map to read.
Only the pointers whose absence would cause a WRONG ACTION are duplicated here:

- [`docs/repo-map.md`](docs/repo-map.md) — **the full fleet architecture**, and the long form
  of every one-liner above. When in doubt, this is the file.
- **ADRs** — [`ADR-001`](docs/flake-architecture-strategy-adr.md) (superseded in part),
  [`ADR-002`](docs/monoflake-capsule-adr.md) (**read §9 first** — what execution found the
  design got wrong), [`ADR-003`](docs/externalization-boundary-adr.md) (decided, NOT
  implemented), [`ADR-004`](docs/secrets-recovery-and-identity-adr.md) (phase 1 of 3 shipped),
  [`ADR-005`](docs/iac-coverage-adr.md) (**IMPLEMENTED**; §8c is its doc-rot record),
  [`ADR-006`](docs/mcp-gateway-succession-adr.md) (ContextForge named as `mcp-proxy`'s successor —
  **name only, NOT implemented**; **read §3**: a ContextForge gateway REJECTS stdio, so each server
  needs a `mcpgateway.translate` sidecar).
- [`docs/mcp-public-exposure-design.md`](docs/mcp-public-exposure-design.md) — **read §10
  first**: the two-proxy model §§1-6 describe was collapsed 2026-09-22.
- [`docs/secrets-and-keychain.md`](docs/secrets-and-keychain.md) — agenix vault, the
  login-Keychain loader, the `secret` CLI. Read before touching anything under `secrets/`.
- [`docs/answer-shape-evidence.md`](docs/answer-shape-evidence.md) — why § Answer shape is
  evidence, not taste. **A diagram carrying no data measurably HURTS** (g ≈ −0.4).
