# Repo map — the full fleet architecture

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Overview and § Navigating the Codebase.
`CLAUDE.md` stays a scannable index (one line per path); this file holds the *why* and the
per-path specifics. **Update both together** — a path that changes shape here needs its
one-liner in `CLAUDE.md` refreshed too.

Two sibling docs carry the surfaces that outgrew this map:
[`mcp-gateway.md`](mcp-gateway.md) (the MCP server inventory) and
[`secrets-and-keychain.md`](secrets-and-keychain.md) (agenix + Keychain).

## The fleet

All-in-one Nix mono-repo managing a fully declarative **aarch64-only** fleet:

- **`macos`** (aarch64-darwin) — macOS/nix-darwin, the sole client Mac. No remote/incoming
  traffic; it is the SSH *client*, reaching `nixpi` via `cloudflared access ssh` over the
  tunnel, and builds `aarch64-linux` locally on Determinate's native Linux builder.
- **`nixpi`** (aarch64-linux) — NixOS Raspberry Pi 4, the **LIVE server**: static-key SSH
  over a Cloudflare Tunnel connector + Caddy, serving its real sites directly
  (`config.fleet.hostedSites`, `modules/parts/identity.nix` — two today, `snoringirl.com` and
  `ismail.kattakath.com`).
- **`nixvm`** (aarch64-linux) — a throwaway NixOS dev VM materialised **only** as
  `nix run .#nixvm` (a build-vm XFCE desktop — no installed VM, no builder, no runner).
- A matching **Devcontainer** image.

(The `macvm` Tart guest was removed 2026-09-05 — re-add path + what survives in the
in-tree `tart-vms` capsule: [`macvm-readd-runbook.md`](macvm-readd-runbook.md).)

Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## Entry points

### `flake.nix`

**Since ADR-002 wave 2 this file is inputs + ONE `flake-parts.lib.mkFlake` call** — down from
2,254 lines, and smaller again since, as removed subsystems took their comments with them.
The count is deliberately not restated here: nothing gates it, so a number in prose only
rots. `wc -l flake.nix` is the answer. Every output is defined in [`modules/parts/`](#modulesparts--the-flake-engine),
one file per concern, discovered by `import-tree`. Nothing below moved *semantically*; the
acceptance test for that wave was an **empty `nix flake show --json` diff** plus byte-identical
host toplevels.

Pins `nixpkgs` + `nix-darwin` + `home-manager` + `treefmt-nix` + `git-hooks` + **`flake-parts`**
+ **`import-tree`** + `raspberry-pi-nix` + `nix-vscode-extensions` + `nix-homebrew` + `agenix` +
Claude Code skill inputs (`agent-skills-vercel`, `agent-skills-anthropic`, both `flake = false`).
**`flake-parts` is a DIRECT input** with `nixpkgs-lib.follows = "nixpkgs"` — it cannot be
`follows = ""`, because flake-parts does `inherit (nixpkgs-lib) lib` (`lib.nix:12`), so rebinding
that name to THIS flake makes it the `lib` of a thing with no `lib`. It was already forced and
undroppable before wave 2 (six of the seven satellites called `mkFlake`); now it is declared here
rather than borrowed from an arbitrary satellite anchor. **There are no satellite inputs left.**

Exports:

- `darwinConfigurations."macos"` (aarch64-darwin).
- `nixosConfigurations."nixpi"` / `"nixvm"` (aarch64-linux) — `nixvm` is the throwaway GUI dev
  VM, materialised only via `nix run .#nixvm`.
- `packages` / `devShells` / `checks` / `formatter` per system via flake-parts' `perSystem`
  (the old `forAllSystems` fold is gone).
- `deploy.nodes.nixpi` — the deploy-rs remote-activation node (see below). **deploy-rs has no
  `flakeModule`** (grepped in the pinned source), so this stays hand-written in the freeform
  `flake` attr, as do `mkDarwin` / `mkNixos` / `mkHomeManagerModule`.
- `templates.default` (top-level `templates/default/`) — `nix flake init -t github:kattakath/nix-config` scaffolds a
  tiny consumer fleet flake (identity override + host deltas over `lib.mkDarwin`), the
  no-fork alternative to README.md § Fork this for your own fleet.

There is **no `nixpi-installer`** — the LIVE `nixpi` sdImage is secret-free, so it *is* the
flashable artifact, prebuilt in CI as the `nixpi-sd-image` package and published to the
`installer-latest` release; token + Wi-Fi are planted post-flash on the FIRMWARE partition.

The FLEET is two systems: `aarch64-darwin` and `aarch64-linux` — **no x86_64 HOST anywhere**.
The devcontainer image is the sole exception: it also builds `x86_64-linux` (via
`devcontainerSystems`) so it runs on x86_64 GitHub Codespaces.

**Identity** (`loginName = "ismail"`, `domainName = "kattakath.com"`, `fullName`, `userEmail`)
is defined once in `modules/parts/identity.nix` (`identityArgs`) and threaded through
`specialArgs`/`extraSpecialArgs`. `mkDarwin` takes an optional per-host `identity` override
(and `mkHomeManagerModule` is a function of it) so a host *could* run under a different
persona, but nothing in the fleet uses it today — `macos` and `nixpi` both inherit
the same global identity; per-host divergence (leanness, package sets, desktop aesthetics) is
achieved entirely via `networking.hostName`-gated `lib.mkIf`, never via a separate identity.

### `flake.lock`

Pinned input revisions; commit every change, never hand-edit.

**The input diet — `follows` is not optional bookkeeping here.** 32 root inputs pull a
transitive graph, and every duplicate node is another fetch, another eval, another thing
`flake-checker` has to reason about. The lock sits at **57 nodes** today; it bottomed out at
**56** the day ADR-002 finished, was **69** before ADR-002 absorbed the satellites, and **72**
before the dedupe pass. The wave table below is that ADR's accounting, not a live count —
inputs added since carried it back up, the 2026-09-14 userscripts removal took it 59 → 58, and
the `kattakath-ai` consolidation (one repo per owner, same day) took it 58 → 57.
Each absorption takes the satellite's own node and its private deps with it:

| Wave | Absorbed | Nodes dropped | Lock after |
|---|---|---|---|
| 3 | `cloudflared-connector` | 2 (itself + its private `treefmt-nix`) | 67 |
| 4 | `firmware-secrets` | 2 | 65 |
| 4 | `keychain-secrets` | 2 | 63 |
| 4 | `vast-provision` | 2 | 61 |
| 5 | `tart-vms` | 2 | 59 |
| 5 | `media-cli` | **1** — it had already followed all three of its inputs | 58 |
| 6 | `local-rag` | 2 — itself **plus a SECOND `treefmt-nix`**, the one input it never followed | **56** |

With `local-rag` went the last `follows = "flake-parts"` line. **All seven satellites are
absorbed; the satellite input count is 0.**

Two mechanisms, and conflating them is the trap:

| Form | Means | Use when |
|---|---|---|
| `X.inputs.Y.follows = "<root input>"` | **DEDUPE** — Y resolves to our copy | Y is *used* by X but we already ship an equivalent |
| `X.inputs.Y.follows = ""` | **REBIND to this flake** — Y's node vanishes | Y is *provably never forced* by X |

`follows = ""` is documented as a circular-dependency tool, **not** as "remove". The empty
follows path is the *root flake*, so the name still binds — to nix-config's own outputs. A
child that never evaluates the input is fine (the node disappears); a child that *does* force
it gets nix-config instead of, say, flake-parts, and fails with `attribute 'lib' missing` —
an error naming neither the input nor the `follows` line. So `""` requires reading the
dependency's source and proving non-use; **when in doubt, dedupe instead.**

What the current lock drops, and the evidence for each:

| Line | Kind | Evidence |
|---|---|---|
| `agenix.inputs.darwin.follows = "nix-darwin"` | dedupe | A whole second nix-darwin tree, referenced only at `darwin.lib.darwinSystem` inside agenix's own `checks`. We consume `packages.<sys>.default` + `darwinModules.default` only. |
| `agenix.inputs.home-manager.follows = "home-manager"` | dedupe | Same shape, and agenix's copy was pinned to April 2025 — a stale second HM tree. Used only in `checks` / `legacyPackages`. |
| `agenix.inputs.systems.follows = "terranix/systems"` | dedupe | **Cannot** be `""`: `import systems` feeds agenix's `packages`, which our devShell pulls. Identical rev to terranix's. |
| `deploy-rs.inputs.utils.inputs.systems.follows = "terranix/systems"` | dedupe | Same: flake-utils' `outputs = { self, systems }` is a *closed* pattern doing `import systems`. |
| `deploy-rs.inputs.flake-compat.follows = ""` | drop | Non-flake `import` shim only. |
| `determinate.inputs.nixpkgs.follows = "nixpkgs"` | dedupe | Legit only since 2026-09-21, when the root `nixpkgs` moved onto FlakeHub's `DeterminateSystems/nixpkgs-weekly/0.1` — the **same flake URL** determinate declares, so this is one node fewer and not a re-point. It feeds only the `determinate-nixd` wrapper derivation (a `cp` of a prebuilt binary). Its `nix` input (nix-src) keeps its own tree on purpose — see the bullet below. |
| `git-hooks.inputs.flake-compat.follows = ""` | drop | `outputs = { self, nixpkgs, ... }` never destructures it; `default.nix`/`shell.nix` read the rev from git-hooks' *own vendored* `flake.lock`, and we only ever call `lib.<system>.run`. |
| `flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs"` | dedupe | Our extracted flakes all call `flake-parts.lib.mkFlake` (forced — never droppable) at the **same rev**, yet each shipped its own flake-parts *and* its own `nixpkgs.lib`: 8 nodes for one library, now 1. The `nixpkgs-lib` half is upstream-blessed — `terranix` already carries that exact line, and flake-parts documents the override behind a 23.05 floor our `nixpkgs.lib` clears by three years. **The anchor moved twice:** it was `firmware-secrets/flake-parts` (an arbitrary satellite) until ADR-002 wave 2 made this flake a flake-parts consumer and declared it directly, which is the only reason wave 4 could delete the `firmware-secrets` (and then `keychain-secrets`, `vast-provision`) inputs without breaking the remaining `follows` at lock time. Absorbed capsules left this row one by one — `vast-provision` at wave 4, `media-cli` at wave 5, and `local-rag` at wave 6 — so **no `follows = "flake-parts"` line survives**: every flake-parts consumer left in the lock is this flake itself. The `nixpkgs-lib` half stays and is the whole row now. |

**Deliberately left duplicated.** Not everything that looks like a duplicate is one:

- **`raspberrypi/linux` ×3** — three *different* revs; a deliberate kernel-branch matrix that
  raspberry-pi-nix selects from at eval time. A `follows` between them silently swaps the LIVE
  Pi's kernel.
- **nix-src's `nixpkgs` trees** (its own `nixpkgs-weekly` pin, `nixpkgs-23-11`,
  `nixpkgs-regression`) — the build/regression pins of `determinate → nix`. Not ours to
  re-point: that tree builds the Determinate Nix package, and re-basing it turns a cache HIT on
  `install.determinate.systems` into a from-source C++ Nix build on every NixOS host and on the
  warm-cache runner. (determinate's *own* top-level `nixpkgs` is now followed — table above.)
- **The surviving `flake-compat`** belongs to `determinate → nix → git-hooks-nix`, not to us.
- **terranix's `flake-parts`** stays on its own rev: it imports flake-parts internals
  (`flakeModules.partitions`, `flake-parts-lib.importApply`), and folding it in would net one
  node while downgrading a third-party flake to a rev its maintainers never tested.
- **The 15 `agent-skills-*` / plugin inputs** are `flake = false` leaves with zero transitive
  nodes. They inflate the *root-input* count and nothing else; dieting them means deleting a
  skill.

**Regenerating after a `follows` change is shape-only** — see
[`flakehub-input-freshness.md`](flakehub-input-freshness.md) § Shape vs. revisions.

### `treefmt.nix`

Single source of truth for formatting + lint-fix (nixfmt + statix + deadnix). Drives
`nix fmt`, the `checks.formatting` CI gate, and the pre-commit hook — change a tool here and
every entrypoint follows.

Scope is deliberately **tools that rewrite files**. Report-only structural lint is a separate
layer (`sgconfig.yml` below) because the pre-commit hook *is* the `nix fmt` wrapper: a checker
in a formatter slot would block every commit with a diagnostic nothing can auto-fix.

### `sgconfig.yml` + `ast-grep/`

Structural lint via [ast-grep](https://ast-grep.github.io) — pattern-matching on the **AST**,
not on lines. ast-grep's own documented layout: `sgconfig.yml` at the repo root (paths resolve
relative to it) pointing at `ast-grep/rules/` and `ast-grep/rule-tests/`. Namespaced under
`ast-grep/` so a bare `rules/` never gets confused with `.claude/rules/` (Claude prompt rules).

Gated by `checks.<system>.ast-grep` (a `runCommand`) — **not** a
treefmt formatter. treefmt-nix ships no `programs.ast-grep`, and none of these rules has a
mechanical `fix:`, so the honest home is a check. `ast-grep` is also in the devShell (from the
same pinned nixpkgs) for iterating on rules; the binary is `ast-grep` — there is no `sg` alias.

Five rules, each mechanising a convention that was **prompt-only** until now:

| Rule | Lang | Mechanises | Notes |
|---|---|---|---|
| `nix-hardcoded-home-path` | nix | CLAUDE.md § Conventions "Paths — two axes" (runtime half) | The gate half of the [`claude-code-nix`](https://github.com/kattakath/ai/tree/main/plugins/claude-code-nix) plugin's `nix-home-path-lint` hook, which is PostToolUse and so only ever sees *Claude's* writes — a human or flake-bump commit slipped through. Matches `string_fragment` nodes only, so comments and Nix source path literals are exempt by construction rather than by heuristic. Keep the regex in sync with the hook. |
| `launchd-bare-interpreter-arg0` | nix | [`.claude/rules/launchd-naming.md`](../.claude/rules/launchd-naming.md) | Flags `ProgramArguments[0]` / `Program` pointing at a bare `sh`/`bash`/`python3`/`node`/… so Background Task Manager can't list a fleet agent as generic persistence. Only sees units authored *here*; the three known upstream `/bin/sh` daemons live in no `.nix` file and must not be renamed. |
| `capsule-must-not-reach-out` | nix | ADR-002's capsule boundary (§ `modules/features/`) | Scoped by `files:` to `modules/features/**`; flags a `path_expression` escaping the capsule's own directory. The file-layer half of the boundary — `checks.<system>.capsule-registry` is the option-layer half. Blind to overlays, `specialArgs` and runtime-built store paths (ADR-002 §7.6, §9.3). |
| `shared-must-not-cross-layers` | nix | the `modules/shared/` layer boundary (`662db6a`, 2026-09-14) | The Home Manager profile may reach **down** into `packages/`, `skills/` and `claude/` — never **across** into `modules/features/`, nor **up** into `modules/parts/`, `hosts/` or `infra/`. |
| `activation-must-not-touch-secrets` | nix | ADR-004 §2.5 ([`secrets-recovery-and-identity-adr.md`](secrets-recovery-and-identity-adr.md)) | A `home.activation` / `system.activationScripts` / `system.userActivationScripts` string that names `secrets-{rehydrate,push,resolve,status}` or `gcloud secrets`/`gcloud auth`. Activation must never touch a secret backend; the CLIs are operator-invoked after `gcloud auth login`. Eval-time twin: `checks.aarch64-darwin.keychain-secrets-backend-inert`. |
| `hook-json-parse-must-be-guarded` | javascript | the "never wedge a turn" invariant every `.claude/hooks/*.js` header states | An unguarded `JSON.parse` of untrusted event JSON throws and surfaces as a hook error. Scoped by `files:` to the hooks. First mechanical check those ~1.3k lines have ever had — `claude-config-lint.yml` checks frontmatter, never hook JS. |

Two things the check does that a naive `ast-grep scan` would not:

- **`--no-ignore hidden`.** ast-grep skips dot-dirs by default, so a bare scan silently
  excludes `.claude/hooks/**` and `.github/**` — a green check that lints nothing. Verified
  empirically: without the flag the JS rule matches zero files.
- **`ast-grep test` before the scan.** `ast-grep/rule-tests/*.yml` carry valid/invalid snippets
  per rule, so a typo'd pattern fails loudly instead of passing vacuously.

**Honest limits.** ast-grep parses the Nix AST, so it *cannot* lint shell embedded in a
`writeShellScriptBin` / `runCommand` string body (25 `.nix` files) — only the Nix around it.
Workflow-YAML security lint is also deliberately out of scope: treefmt-nix already ships
`programs.zizmor` for exactly that, and reinventing it as hand-written ast-grep patterns would
be strictly worse.

### `deploy.nodes` — deploy-rs remote activation (magic rollback)

The `deploy-rs` input (`github:serokell/deploy-rs`, `nixpkgs` followed, `flake-compat` dropped
and `utils/systems` deduped — § `flake.lock` above) exists for one property
`nixos-rebuild switch --target-host` does
not have: **an undo**. It is consumed purely as a `lib` (`activate.nixos`, `deployChecks`) plus
the `deploy` CLI in the devShell — it is **not** a NixOS/HM module and no host imports it.

`deploy.nodes.nixpi` (defined in [`modules/parts/deploy.nix`](../modules/parts/deploy.nix)):

| Setting | Value | Why |
|---|---|---|
| `magicRollback` | `true` | The Pi activates behind a watchdog and **reverts itself** unless the deployer reconnects over a *second* ssh session and confirms. A change that kills sshd / the tunnel connector / networking becomes a failed deploy, not a physical SD-card pull (`nixpi-sd-flashing-runbook.md`, ~40 min). |
| `autoRollback` | `true` | Roll back if the activation script itself fails. |
| `remoteBuild` | `false` | **The Pi must never build.** Closures are built on the Mac / CI and `nix copy`'d, substituting from Cachix on the destination. |
| `fastConnection` | `false` | Keeps `--substitute-on-destination`, so the Pi pulls most paths straight from Cachix instead of over the tunnel. |
| `activationTimeout` / `confirmTimeout` | `600` / `120` | Upstream defaults are too tight for a Pi 4 over a Cloudflare Tunnel, and a timeout here does not mean "slow" — it means an unattended **rollback of a good deploy**. |
| `hostname` | `nixpi.${domainName}` | The tunnelled name, not `nixpi.local` — see the ssh block in `modules/shared/home.nix`. |
| `sshUser` / `profiles.system.user` | `loginName` / `root` | SSH in as the operator (keys-only), activate as root via passwordless `wheel` sudo (`modules/nixos/core.nix`), so no `interactiveSudo`. |

`sshOpts` is deliberately **empty**. deploy-rs space-joins `sshOpts` into `NIX_SSHOPTS`, which
nix then re-splits on whitespace, so a spaced `-o ProxyCommand=…` is mangled for the `nix copy`
leg. `~/.ssh/config` is the one place a spaced `ProxyCommand` survives **both** legs — hence
the declarative `Host nixpi.<domain>` block in `modules/shared/home.nix` (store-path
`cloudflared`, `StrictHostKeyChecking = accept-new` because a reflash mints a new host key).
That block replaces the old "hand-edit `~/.ssh/config`" instruction in the runbooks, which was
unfollowable — the file is a read-only `/nix/store` symlink.

`deploy --targets .#nixpi` deploys the real Pi directly — the private nix-personal flake that
used to gate this (a separate checkout carrying the real `hostedSites`) was retired 2026-09-15;
this repo's own `nixosConfigurations.nixpi` now carries the real data. `remoteBuild = false`
still means the Pi never builds, and the caddy `Caddyfile-formatted` EPERM on Determinate's
native Linux builder still means `nixos-rebuild --build-host nixpi` (no magic rollback) is the
working path today, not this deploy-rs node — see `hosts/` above.

Only **one** of deploy-rs' two `deployChecks` is wired into `checks.<system>`:

- **`deploy-schema` ✅** — validates `self.deploy` against deploy-rs' own `interface.json`:
  **types on known keys** (`magicRollback = "yes"` → `'yes' is not of type 'boolean', 'null'`),
  the **required** keys (`hostname`, `profiles.*.path`), and the node/profile name pattern.
  ⚠ It does **NOT** reject **unknown** keys — `interface.json` sets `additionalProperties: false`
  on the `nodes`/`profiles` **maps** only (constraining names), never on
  `generic_settings`/`node_settings`/`profile_settings`. A typo'd `magicRollBack` therefore
  **validates clean** (measured: exit 0) and the Pi deploys with magic rollback silently **off**.
  Renaming/typo'ing a setting stays a **human** review item; this gate cannot catch it. It is fed
  a copy of `self.deploy` whose `profiles.*.path` is demoted to a **context-free** string
  (`builtins.unsafeDiscardStringContext`): `builtins.toJSON` renders a derivation as its outPath
  *with string context*, and `writeText` turns that into a real `inputDrv` — measured, the naive
  form makes `nix flake check` build nixpi's cold `linux-rpi` kernel to run a JSON-schema
  assertion. The bytes (and therefore the verdict) are identical; only the phantom build edge is
  gone.
- **`deploy-activate` ❌ excluded** — it interpolates `toString profile.path`, so it
  build-depends on the full aarch64-linux toplevel. It only asserts an upstream invariant
  (`activate.nixos` adds its own activator scripts), which is not worth a Pi closure build per
  CI leg.
- **No gate BUILDS the darwin closure.** `nix flake check` evaluates `darwinConfigurations`
  with the build skipped, and CI (`nix-ci.yml`) deliberately only evaluates the host
  toplevels' drvPaths. A package that *evaluates* but cannot *build* therefore passes every
  gate and first fails at `activate`, on the real Mac — measured when `rclip` broke activation
  while the check and the CI build leg were both green. When adding or overriding a PACKAGE
  the only real gate is `nix build .#darwinConfigurations.macos.system` yourself.

It is added via `deployChecksFor system` folded into `forAllSystems`, guarded by
`lib.optionalAttrs (deploy-rs.lib ? ${system})`, **not** the README's `mapAttrs …
deploy-rs.lib` — deploy-rs exports `lib` for four systems, and that idiom would create
`checks.x86_64-linux` + `checks.x86_64-darwin`, which this flake permits nowhere.

### devShell

Entered with `nix develop` (in the devcontainer or on a nix host). There is **no**
`.envrc`/direnv auto-load — run `nix develop` explicitly. (`programs.direnv` + `nix-direnv` ARE
enabled fleet-wide in `modules/shared/home.nix`; this repo alone opts out, since `2fa73b9`.)

**The shell sets `CLOUDSDK_CONFIG`** to `$XDG_CONFIG_HOME/gcloud-nix-config`, so `gcloud` and any
`tofu` run here use an account and project scoped to this repo rather than whatever is globally
active. It is **not** `CLOUDSDK_ACTIVE_CONFIG_NAME`, and the difference is load-bearing: measured
2026-09-22, a named configuration is only `configurations/config_<name>` (account, project,
region), while `credentials.db` and `application_default_credentials.json` sit at the TOP of the
config dir, shared by every configuration. The google Terraform provider reads **ADC**, so a
named configuration gives a correct `gcloud` and a `tofu` silently authenticated as whoever last
ran `gcloud auth application-default login`. Repointing the whole directory moves both.

First use needs **two** logins, because the CLI and Terraform read different files:
`gcloud auth login` **and** `gcloud auth application-default login`, then
`gcloud config set project <id>`. The shell prints these until ADC exists. The directory is under
XDG, never in the worktree — it holds live credentials.

The `deploy` CLI is in the devShell on **darwin only** (from the deploy-rs *input*, not
`pkgs.deploy-rs`, so the CLI and the `activate` binary baked into nixpi's closure come from one
lock entry and stay in lockstep). `macos` is the fleet's only SSH client and the only holder of
the operator key + the cloudflared Access path, so a deploy can originate nowhere else — and
keeping it out of `devPackagesFor` keeps a from-source Rust build out of the devcontainer image
(including its x86_64 Codespaces variant, which cannot reach the Pi anyway).

⚠ **The lockstep costs a from-source Rust build, once per machine.** The input's overlay build
(`deploy-rs-0.1.0`) is in **no** binary cache — verified absent from both `cache.nixos.org` and
`kattakath.cachix.org`, on both arches — while `pkgs.deploy-rs` (`0-unstable-*`) substitutes
fine. So a fresh Mac's first `nix develop` builds it, and the first real deploy builds the
`aarch64-linux` `activate` for nixpi's closure on Determinate's native Linux builder (1 CPU /
8 GiB by default; sizable via `determinateNix.determinateNixd.builder.*` — see CLAUDE.md).
Deliberately **not** warmed via `checks`: `checks` is strictly lint-only (`nix flake check`,
`/eval`, `nix-ci.yml` all build it), and paying a Rust build on every `/eval` to save it on a
rare fresh-machine `nix develop` is the worse trade.

### `secrets/secrets.nix`

agenix recipients rules — **four** committed secrets on **two different models**. The operator
public key they all share is single-sourced in **`secrets/operator-key.nix`** (also the fleet's
`authorizedKeys`, via `flake.nix` → `modules/nixos/core.nix`), so a key rotation is one edit.

- **Operator-only vault (1).** `secrets/cloudflared-token.age` (nixpi's Cloudflare tunnel token)
  — encrypted to the **operator's key alone**: the operator decrypts it on the Mac to plant on
  the SD card's FAT `FIRMWARE` partition, and it is NEVER decrypted on nixpi.
- **Host-decrypted on `macos` at activation (3).** Recipients are operator **+ the `macos` host
  key**, landing in `/run/agenix/`: `gh-app-dontsell-ai-key.age` and `gh-app-fleet-key.age` (the
  two runner lanes' GitHub App RS256 keys — **identical key material on purpose**, because an
  agenix secret has one owner and the lanes run as different users) and
  `gitlab-runner-token.age` (the `glrt-` token `local.tart.gitlabRunner` renders its `config.toml`
  from). The host-decryption path is live; do not describe it as unused.

All four are safe to commit. Full rules: [`secrets-and-keychain.md`](secrets-and-keychain.md).

## `hosts/` — per-host entry profiles

**`macos` carries ONE account.** `ismail` is `system.primaryUser` and owns the operator
profile. A second ADMINISTRATOR account (`izzy`, uid 502) lived here from 2026-09-15 to
2026-09-17 and was then **deleted forever** — account, home directory, per-user casks
(Opera/CapCut/Audacity) and FileVault enrolment. Three things it taught outlive it, because
they bite any future second account:

- **`users.knownUsers` is the DELETE switch, and deleting is NOT "remove the name".**
  Measured 2026-09-17, against the pinned nix-darwin `modules/users/default.nix:26`:
  `deletedUsers = filter (n: isDeleted cfg.users n) cfg.knownUsers` — a user is deleted only
  while its name is STILL in `knownUsers` and its `users.users.<name>` entry is GONE. Drop
  both at once (the intuitive spelling) and nix-darwin simply stops knowing the account:
  activation exits 0, says nothing, and the account survives. To retire one declaratively,
  delete `users.users.<name>` first, activate, THEN drop the name from `knownUsers`. It also
  refuses any uid ≤ 501, and it removes the directory RECORD only — the home directory,
  `admin` group membership and FileVault enrolment are all left behind. `isHidden` likewise
  defaults `true` and is applied ONLY at creation, so flipping it later needs a converge shim.
- **Homebrew `args.appdir` only applies at INSTALL time**, and `brew bundle` runs as
  `homebrew.user` under sudo — so a per-user cask directory is created `root:staff 0755` and
  the owning account's own Home Manager then dies with EPERM on its `~/Applications` symlink.
- **A never-logged-in account blocks activation, SILENTLY.** A user launchd agent can only
  bootstrap into that user's own GUI session, so any agent declared for an account that has
  never logged in fails with `Bootstrap failed: 125: Domain does not support specified
  action`. Home Manager's activation then exits non-zero and **nix-darwin's own**
  `$systemConfig/activate` — not the `activate` CLI — runs under `set -e`, so the abort lands
  ~80 lines short of its final `ln -sfn … /run/current-system`. The system **profile**
  advances while `/run/current-system` and `/nix/var/nix/gcroots/current-system` stay on the
  OLD generation — and `/run/current-system/sw/bin` is what PATH resolves. Packages end up
  installed and unreachable at the same time.

  **`darwin-rebuild` exits 1.** MEASURED 2026-09-15 by re-enabling one such agent and
  capturing the status with no pipe (`> file 2>&1; RC=$?`): broken run 1, healthy run 0.
  Every link propagates — `setupLaunchAgents` returns 1 (pinned home-manager
  `modules/launchd/default.nix:564`), the generation's `activate` then does
  `exit "$launchdStatus"`, `launchctl asuser` passes a child status through (verified: a child
  exiting 7 yields 7), and `$systemConfig/activate` is `darwin-rebuild`'s last statement under
  `set -e`. Cite that one by CONSTRUCT, not line: the generation's `activate` is GENERATED per
  user per generation, and the same `exit` sat at 833, 848 and 936 across three of them on one
  afternoon. The pinned-input citations around it (`modules/launchd/default.nix:166`, `:232`,
  `:326`, `:564`) are the opposite case and stay — a `/nix/store` flake input only moves on a
  `flake.lock` bump, which is a reviewed event, and that is the same basis
  [`upstream-first`](../.claude/rules/upstream-first.md) already requires citing. **The rule is
  not "no line numbers" — it is "no line numbers into generated artifacts."**

  So it is not silent for lack of a signal — it is silent because **nobody reads the exit code
  of an interactive activation**, and because a status read through a pipe
  (`activate | tail`) is the PIPE's, not the command's. That misreading is exactly how an
  earlier revision of this paragraph came to claim exit 0. It is the same family as the
  `cmd | grep -q` trap that returns 141 on a SUCCESSFUL match under `pipefail` (§ Home Manager
  activation): **a status taken through a pipe describes the pipe.**

  The obvious fix is itself a trap, and this fleet hit all three rungs of it. `$PIPESTATUS`
  is a BASH array; in zsh — the login shell here — it does not exist, so **every** index
  expands to the empty string, not just `[0]`. zsh's array is lowercase `$pipestatus` and is
  1-indexed. And either array is destroyed by the next COMMAND that runs — an assignment
  counts, a newline does not. Measured:

  ```
  sh -c 'exit 3' | cat; LO=("${pipestatus[@]}")   # -> (3 0)   correct
  sh -c 'exit 3' | cat; UP=("${PIPESTATUS[@]}")   # -> ()      empty at EVERY index
  sh -c 'exit 5' | cat
  echo "(${pipestatus[@]})"                       # -> (5 0)   survives a newline
  sh -c 'exit 7' | cat
  : ; echo "(${pipestatus[@]})"                   # -> (0)     one no-op command destroys it
  ```

  So the rule is **capture before anything else runs**, not "same line" — reading it on the
  following line works, because the expansion happens while building the next command's
  arguments rather than after that command has run. Same line, lowercase first, nothing in
  between is simply the version that cannot go wrong.

  So the rule is not "use `[1]`" — that still yields nothing in zsh and still reads as a pass.
  Either do not pipe (`cmd > /tmp/out 2>&1; RC=$?`, then read the file) or use lowercase
  `${pipestatus[1]}` captured immediately. **A bare `EXIT=` in your output is a BROKEN PROBE,
  not a passing one** — an empty status reads as "no failure" when it means "the instrument
  returned nothing".

  Diagnose by comparing
  `nix eval .#darwinConfigurations.macos.system` against `readlink -f /run/current-system`;
  the system profile is NOT the authority here. (It stranded four generations deep before
  anyone noticed, 2026-09-15.)

  **`launchd.enable = false` does not fix it — it is a no-op.** The option reads like the
  class-wide switch, but upstream uses `cfg.enable` in exactly one place, an assertion
  (pinned home-manager `modules/launchd/default.nix:232`): `agentPlists` filters on the
  PER-AGENT flag (`:166`) and `home.activation.setupLaunchAgents` is gated on `isDarwin`
  alone (`:242`). Measured — it evaluated `false` and both agents still bootstrapped. The
  working spelling is `launchd.agents.<name>.enable` (`:20`), and it needs `lib.mkForce`
  because the agents are unconditionally `true` at their source.

  Removal is safe on a domain-less user even though installation is not: `bootoutAgent`
  whitelists that same error (`:326`) where `bootstrapAgent` treats it as fatal — which is
  why the per-agent `false` works at all.

  The cost is upstream's per-agent design: every agent added to `modules/shared/home.nix`
  would have to be listed again in such an account's block, or its activation starts
  aborting anew.

- **`macos.nix`** — the darwin client host. Imports `../modules/darwin/github-runner.nix` and
  enables `local.macosGithubRunner` with `count = 2` for the **`dontsell-ai`** org (see that
  module's section below) — nix-config's *own* CI is fully GitHub-hosted and uses no runner, but
  this Mac is not runner-free. Also configures **`local.tart.githubRunners.*`** (the `tart-vms` capsule's
  `darwinModules.github-runner`, in `mkDarwin`'s BASE module list): ephemeral **Tart-VM-per-job**
  GitHub Actions runners for `kattakath`, `silvercreek-ai`, and `dontsell-ai` (label
  `dontsell-vm` — the bare-metal pair keeps that org's nix-toolchain CI), one fleet GitHub App
  (`ismailkattakath-ci`, appId 4849830 — it replaced the retired `kattakath-fleet-ci` on
  2026-09-06; key = agenix `gh-app-fleet-key.age`, host-decrypted), digest-pinned
  Cirrus runner image, and Apple's 2-concurrent-VM budget shared by a slot semaphore. The base
  clone and the host-key pin are content-keyed by `oci@digest`, so a digest bump renames both;
  one elected instance per image re-pulls and re-pins itself on its next cycle
  (`tart-runner-setup-kattakath [image|pin|all]` pre-warms that by hand). Slots, pins and both
  lanes' logs live under `local.tart.runnerStateDir` — `~/.local/state/tart-runner` by default,
  durable and user-writable; a volatile root now fails at eval, after the old `/tmp` default
  was purged and darked all three lanes on 2026-09-05. The **GitLab** runner shares the
  same VM budget declaratively since 2026-09-05: **`local.tart.gitlabRunner`** (the same capsule's `gitlab-runner.nix`,
  same base list) runs `pkgs.gitlab-runner` as a GUI LaunchAgent that renders its `config.toml`
  at start from the agenix `gitlab-runner-token.age` (host-decrypted), pointing at the
  `gitlab-tart` slot shims around cirruslabs' first-party executor — the semaphore
  (`modules/features/tart-vms/packages/tart-slots.nix`) is the single protocol both forges speak; only runner
  *registration* (minting the glrt- token) remains manual. Carries its own Homebrew brew/cask/masApps lists, incl. a
  `libreoffice` cask backing the docx/pptx/xlsx/pdf Claude Code skills' `soffice` dependency,
  and the `open-design` cask (`greedy = true`, adopted the hand-dragged app in place) paired
  with `launchd.user.envVariables.OD_UPDATE_ENABLED = "0"` so versioning belongs to brew, not
  the app's drift-prone self-updater — the full declared/imperative boundary is
  [`open-design.md`](open-design.md). Also imports `../modules/darwin/claude-managed-settings.nix`
  and sets `local.claudeManagedSettings.enable = true` — the root-owned Claude Code policy tier
  (§ `modules/darwin/`); it is the only host that has one. Consequence worth recognising when it
  fires: a PRE-EXISTING unowned `managed-settings.json` (an MDM payload, a hand-placed file)
  now FAILS activation with exit 2 rather than being clobbered.
- `macvm.nix` — removed 2026-09-05 with the rest of the `macvm` Tart guest; re-add path:
  [`macvm-readd-runbook.md`](macvm-readd-runbook.md).
- **`nixpi.nix`** — Pi 4, LIVE: boot fixes + cloudflared + upstream `services.caddy`. Its
  `sdImage` is prebuilt in CI and published to the `installer-latest` release, since it bakes
  no secrets.
  - ⚠ **The Mac's native Linux builder cannot build this host's `etc` closure.** Upstream's
    caddy module formats the generated Caddyfile in a `Caddyfile-formatted` derivation whose
    build command is `cp --no-preserve=mode <Caddyfile> $out/Caddyfile`, and **`cp
    --no-preserve=mode` into `$out` fails with `setting permissions: Permission denied`** on
    Determinate's native Linux builder (reproduced minimally with
    `runCommand "p" {} "mkdir -p $out; cp --no-preserve=mode ${writeText "s" "x"} $out/f"`; a
    plain `chmod` in `$out` on the same builder works). That failure cascades to `etc.drv` and
    the toplevel, so **any** Mac-side build of a Caddy-serving nixpi generation dies. Upstream
    already skips the derivation when `buildPlatform != hostPlatform`, which does not help here
    (both are `aarch64-linux`). Measured 2026-09-15: **only that one operation fails** — `cat >`,
    `install -m` and `cp` + `chmod` all succeed on the same builder, so this is a narrow,
    undocumented, unreported builder bug rather than a general chmod ban.
    - **THE ANSWER IS NOT TO BUILD ON THE PI.** That was the old workaround, and it is now
      hard-blocked (`.claude/hooks/pretooluse-bash-guard.js` Rule 1d): the Pi is on an SD card,
      and a power cut mid-build corrupts it, which needs hands on the hardware to reflash.
      Instead `.github/workflows/warm-nixpi-cache.yml` builds the toplevel on a real
      `ubuntu-24.04-arm` runner — where that `cp` works — and pushes the closure to Cachix on
      every nixpi-closure change. Both the Mac and the Pi then substitute, and the EPERM never
      enters the path.
    - **The EPERM only fires on a cache MISS**, and a miss can OUTLIVE the warm: if you
      evaluate a nixpi change before CI has pushed it, Nix records the 404 in its narinfo
      negative cache for an hour (`narinfo-cache-negative-ttl`, default 3600), so it keeps
      planning a build against an already-warmed cache. **You cannot clear that from the CLI**
      — the operator is `Trusted: 0` against the local daemon, so `--narinfo-cache-negative-ttl 0`
      is answered with *"ignoring the client-specified setting … you are not a trusted user"*
      (same reason `--builders`/`--max-jobs 0` are ignored). Wait it out, or add the operator to
      `determinateNix.customSettings.trusted-users`.
- **`nixvm.nix`** — a SLIM throwaway aarch64-linux dev VM: no disko, no runner, no install;
  materialised only as the graphical `nix run .#nixvm` build-vm, whose guest builds locally on
  the native Linux builder or substitutes from Cachix.

## `modules/` — reusable modules split by platform

Platform branching lives **here** behind `lib.mkIf`, not duplicated across hosts.

Two subtrees are **not** platform splits and are governed by ADR-002
([`monoflake-capsule-adr.md`](monoflake-capsule-adr.md)) rather than by the rule above. Both get
their own top-level section below:

- **`modules/parts/`** — the FLAKE ENGINE. It **may reach anywhere** in the tree.
  → [§ `modules/parts/`](#modulesparts--the-flake-engine)
- **`modules/features/<name>/`** — the six CAPSULES (the absorbed satellite flakes that
  survive; `vast-provision` was removed 2026-09-12). A capsule
  is entered **only** through its `flake-module.nix` and **may not reach outside its own
  directory**. → [§ `modules/features/`](#modulesfeatures--the-seven-capsules)

### `modules/shared/`

`modules/shared/{home.nix,mcp.nix,chromium.nix,default-browser.nix,ubersicht.nix,next-right-thing.nix,terminal-theme.nix,desktop-aesthetics.nix,nix-cache.nix,nix-ld-libraries.nix,launchd-launcher.nix,wireguard-configs.nix,claude-otel.nix,claude-bedrock-gate.nix,claude-brain.nix,claude-plugins.nix,claude-guardrails.nix,claude-desktop.nix,wallpaper/}`
— the Home Manager profile loaded on every host.

- **`home.nix`** — git/ssh-signing, zsh+starship, direnv, gh, bash, claude-code + nerd-fonts;
  darwin-only ssh/vscode blocks gated `lib.mkIf pkgs.stdenv.isDarwin`. The ssh block owns
  `Host nixpi.<domain>` with the `cloudflared access ssh` `ProxyCommand` (store path, not
  `/opt/homebrew`) — the *only* remote path to the Pi, and what makes both deploy-rs legs work
  (`ssh` for activation + `nix copy` for the closure); see `deploy.nodes` above. Host-gated: RAG
  (ollama/pgvector) + public MCP tunnel only when `networking.hostName == "macos"`.
  `home.packages` also carries `pandoc`/`poppler` (nixpkgs, darwin-only) — together with
  macos's `libreoffice` cask, these satisfy the docx/pptx/xlsx/pdf skills' stated runtime deps
  (LibreOffice/poppler/pandoc), a gap flagged inline at that skills block since it was first
  wired. Also declares a Spotlight-visible, focus-or-launch `.app` bundle for the Android
  emulator (`home.file."Applications/Android Emulator.app"`, backed by
  `packages/spotlight-launchers.nix`, macos-only).
- **`mcp.nix`** — the claude-code MCP-server config. See [`mcp-gateway.md`](mcp-gateway.md);
  the per-client stdio `open-design` entry's boundary doc is [`open-design.md`](open-design.md).
- **`chromium.nix`** — `local.ungoogledChromium`, real-Mac-only: the declarative surface for
  the Homebrew `ungoogled-chromium` cask. Installs **no** browser (`programs.chromium.package =
  null`) — nixpkgs' `chromium`/`ungoogled-chromium` are `*-linux` only, so the `.app` must be a
  cask; this module contributes only the files Chromium reads out of its user-data dir, via
  upstream HM `programs.chromium` (no custom shell), plus two recommended-level policies. The
  LaunchServices default-browser claim is NOT here any more — it left with `local.defaultBrowser`
  when Chromium stopped being the default (`chromium.nix:10`). Five surfaces, five sideloaded
  extensions:
  - **`External Extensions/<id>.json`** — pinned `fetchurl` CRXes installed as
    `external_crx` + `external_version`. The Web Store `external_update_url` is **dead** here
    (ungoogled's `disable-webstore-urls.patch`), so a local CRX is the only path; the official
    extension ID survives because it derives from the signed CRX3 public key, not the path.
    One option per extension, all defaulting on:

    | Option | Extension | MV | Note |
    |---|---|---|---|
    | `applePasswords` | iCloud Passwords | 3 | also plants the native host below |
    | `adBlock` | uBlock Origin | **2** | the **real** MV2 build, not uBO Lite |
    | `userScripts.enable` | Violentmonkey | 3 | also materialises `userScripts.scripts` |
    | `claudeInChrome` | Claude in Chrome | 3 | native host is claude-code's, not ours |
    | `kaptureMcp` | Kapture MCP Browser Automation | 3 | browser end only; per-tab gate is **DevTools** |
    | `darkTheme` | Into The Black Hole | 2 | code-free theme (a `theme` key, nothing else) |

    `adBlock` gets the **real MV2** uBlock Origin — with blocking `webRequest`, not
    `declarativeNetRequest` — because ungoogled's `extensions-manifestv2.patch` makes
    `ShouldDisableLegacyExtensions()` return false unconditionally. Chrome and Brave cannot.
    **Two browser-automation extensions, on purpose.** Both hold `debugger` +
    `<all_urls>`; they differ in *who can reach them*, which is the whole point:

    | | `claudeInChrome` | `kaptureMcp` |
    |---|---|---|
    | Transport | native messaging | DevTools panel → local bridge |
    | Reachable by | the one CLI its host manifest names | any MCP client that speaks to the bridge |
    | Per-tab gate | none | **must open DevTools + connect** |
    | Fails when | its tools never load into the session | the `npx` bridge isn't running |

    `claudeInChrome`'s `com.anthropic.claude_code_browser_extension` native host is written
    by claude-code itself (its `path` must track the current CLI install), so this module must
    **not** re-declare it — only Apple's host needs replanting. `kaptureMcp` needs no host at
    all, but its **server half is not declared here**: `~/.claude.json` runs
    `npx -y kapture-mcp@latest bridge` at user scope — imperative and unpinned, so it can
    change under a session with no rebuild. Declaring it in `mcp.nix` is an open follow-up.
    (Historical note: the kapture *gateway* entry was removed 2026-08-22 along with the whole
    public-MCP-exposure subsystem; that removal was about the gateway and the Cloudflare
    tunnel, not about the tool, and this extension does not resurrect either.)
  - **`NativeMessagingHosts/com.apple.passwordmanager.json`** — Apple's own native-messaging
    manifest, re-pointed at Chromium. macOS ships it to **Chrome and Firefox only**; replanting
    it is what makes Passwords.app autofill here, and it is safe because the manifest gates on
    **extension ID** (`allowed_origins`), not on browser brand.
  - **`userScripts.scripts`** — an `attrsOf (nullOr path)`, attr name → `.user.js` source, each
    materialised to `~/.local/share/userscripts/<name>.user.js` (an **XDG runtime** path;
    deliberately not `~/Documents`/`~/Desktop`, which are TCC-walled and would need Chromium a
    Full Disk Access grant to read a `file://` from) plus a generated `index.html` of install
    links. `null` (e.g. `lib.mkForce null`) keeps a declaration but skips the file.

    **EMPTY since 2026-09-14, and kept on purpose.** No host declares a script any more —
    every one was published to Greasy/Sleazy Fork instead (see § Userscripts below for the
    trade). `xdg.dataFile` is gated on the attrset being non-empty, so an empty one writes
    nothing at all; `enable` still sideloads Violentmonkey itself, which is what the published
    scripts install into. The option stays because it is a free seam and a private script that
    must not reach a public fork is still a real case. It remains the public/private merge
    point, so if both repos ever repopulate it, **keys must be distinct** — the module system
    treats a repeated key as a **conflict**, not an override.

    **Nix owns the files, never Violentmonkey's database**, and that is a Chromium wall rather
    than a shortcut. bitbloxhub's Firefox pattern (enterprise policy → `browser.storage.managed`
    → a Violentmonkey *fork* that parses it at startup) does **not** port: the fork's hook is
    Firefox-gated, Chromium only populates `chrome.storage.managed` for extensions declaring a
    `storage.managed_schema` (Violentmonkey declares none), and the *forced* policy level the
    fork would need lives in MDM-owned `/Library/Managed Preferences/org.chromium.Chromium.plist`,
    unreachable from Home Manager (the **recommended** level is reachable — see
    `hideBookmarkBar` below — but it cannot lock a value, which is what that trick relies on).
    A userscript is installed by **navigating** to it, so a declared script cost one click per
    script off the index page and had **no update channel** — `checks.<system>.userscripts`
    banned `@downloadURL`/`@updateURL`/`@installURL` outright (pointed at this repo they would
    let a push to `main` mutate an installed script with no activation), so every change was a
    `@version` bump plus that same click-through. That gate is gone with the scripts; a
    fork-published copy gets the `@updateURL` the declared one was forbidden, which is exactly
    why the fleet stopped declaring them.
    **Never put a secret in a userscript** — `source` is
    copied into the world-readable store, private flake or not.
  - **`hideBookmarkBar`** — one of two *policy* surfaces, and the place this repo writes
    Chromium's own preferences domain: HM `targets.darwin.defaults."org.chromium.Chromium"` sets
    `BookmarkBarEnabled = false`, so **View ▸ Always Show Bookmarks Bar** starts OFF (it seeds
    the `bookmark_bar.show_on_all_tabs` pref). macOS has **no** policies-JSON directory — that is
    the Linux path; Chromium's platform loader reads CFPreferences and grades every key by
    `CFPreferencesAppValueIsForced`: forced → **mandatory** (greys the menu item out, and only an
    MDM configuration profile in `/Library/Managed Preferences/` can set it), everything else →
    **recommended**. So the plain, unprivileged user domain is precisely the level that means
    "off by default, still toggleable", and a manual tick then wins for good. HM applies it with
    `defaults import`, which **merges**, so Chromium's own state in that domain survives.
    - **No sibling for View ▸ Always Show Toolbar in Full Screen.** That is
      `browser.show_fullscreen_toolbar`, a macOS-only *profile pref* with **no policy behind
      it** — this cask's Chromium 152 carries a 579-name policy table (`AIModeSettings` →
      `XSLTEnabled`) with nothing fullscreen-toolbar-shaped in it. The only remaining lever is
      the profile's `Preferences` JSON, browser-owned mutable state Nix must not seed (same
      class as `extensions.pinned_extensions`), so it stays a one-time manual click.
  - **No default-SEARCH-ENGINE option — tried, shipped, and removed 2026-08-31.** Worth keeping
    the negative result: ungoogled ships **no working prepopulated engine**, because
    `replace-google-search-engine-with-nosearch.patch` rewrites Google's row of
    `prepopulated_engines.json` into a "No Search" stub, so a fresh profile's picker reads *No
    Search (Default)*. A `defaultSearchProvider` option seeding the `DefaultSearchProvider*` set
    looked like the fix and **evaluated, activated, and verified green from Nix's side** — the
    plist was written and `chrome://policy` showed every key arriving with Source `Platform`,
    Level `Recommended`. The browser then **refused it**: `DefaultSearchProviderEnabled` reported
    *"This policy is blocked, its value will be ignored"* and the other four cascaded to `Error`
    behind the dead main switch, while `BookmarkBarEnabled` in the same table read `OK`.
    - **Lesson, and the reason this paragraph exists:** upstream `can_be_recommended: true` is a
      *hint*, not a guarantee — the set carries it and is still mandatory-only in practice.
      **`chrome://policy` is the only real test of a policy's tier**, and a policy can arrive
      correctly and still be ignored. Mandatory would need an MDM-installed
      `/Library/Managed Preferences` plist and would **padlock** Settings ▸ Search engine, which
      is worse than a click. Do not re-attempt.
    - **Manual instead, once per profile:** DuckDuckGo is prepopulated → ⋮ ▸ *Make default*.
      Google is not (its row is stripped) → Settings ▸ Search engine ▸ Site search ▸ **Add**,
      name `Google`, shortcut `google.com`, URL `https://www.google.com/search?q=%s`.
    - **Adding an engine hits the same wall**: `SiteSearchSettings` and
      `EnterpriseSearchAggregatorSettings` are mandatory-only too, and engines they create can
      never be promoted to default (`CreatedByNonDefaultSearchProviderPolicy`).
  - **`makeDefaultBrowser`** — the one surface that is neither a user-data-dir file nor a policy:
    it claims LaunchServices' `http`/`https` handler for Chromium with nixpkgs'
    **`defaultbrowser`** (darwin-only, substitutable from cache), run from a Home Manager
    activation step. The argument is the **short name `chromium`**, not the bundle id —
    `org.chromium.Chromium` is rejected as "not available as an HTTP handler". The `defaultbrowser`
    CLI also lands on PATH as this setting's read-only doctor: **no arguments** prints the handler
    list with the current default starred.
    - **Idempotent by the tool's own guard**, not ours: it reads the current handler first and
      early-returns with "chromium is already set as the default HTTP handler", never touching
      LaunchServices. A settled Mac is a true no-op.
    - **One consent dialog, once**, on the activation that actually changes the handler (a fresh
      or reset Mac) — unavoidable, and the reason the idempotence above matters. `defaultbrowser`
      calls Launch Services' `LSSetDefaultHandlerForURLScheme`, whose SDK-declared replacement
      `-[NSWorkspace setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:]` is
      documented in the macOS 26 `AppKit/NSWorkspace.h` as: *"Some URL schemes require user
      consent before you can change their handlers. If a change requires user consent, the system
      will ask the user asynchronously"*. The browser schemes are exactly those, for every tool
      and every API. The legacy call is still safe to use — that same SDK declares it
      `API_TO_BE_DEPRECATED`, i.e. soft-deprecated with **no** removal version.
    - **`duti` passed over**: it takes bundle ids but has no idempotence guard, so it would
      re-ask on every activation. The step also tolerates its own failure, because the `.app` is
      a Homebrew cask and nothing orders brew's activation before Home Manager's — a first-ever
      rebuild warns and retries next time rather than failing over which browser opens a link.
  - **No policy can tidy the NEW-TAB PAGE** — a settled dead end, not an omission. **Every** NTP
    policy Chromium defines is **mandatory-only**: `NewTabPageLocation`, `NTPCardsVisible`,
    `NTPCustomBackgroundEnabled`, `NTPMiddleSlotAnnouncementVisible`, `NTPOutlookCardVisible`,
    `NTPSharepointCardVisible`, `NTPContentSuggestionsEnabled` and both `NTPFooter*` all **omit**
    `can_be_recommended` in their upstream `policy_definitions/**.yaml`, which defaults it to
    false. Absence is the answer, not a metadata gap — the flag is written explicitly when true,
    and both policies this repo *does* ship (`BookmarkBarEnabled`,
    `DefaultSearchProviderSearchURL`) carry `can_be_recommended: true`. `NewTabPageLocation`'s own
    `desc` says it outright: "configures the default New Tab page URL **and prevents users from
    changing it**". A padlocked new-tab page is worse than a click, so it stays unset. Nor is
    there any policy that hides just the **shortcut tiles**: the one shortcut-shaped policy,
    `NTPShortcuts`, goes the wrong way (it *pre-configures up to 10 organization shortcuts in
    addition to* the user's own) and is mandatory-only too. Hiding the tiles writes a
    profile-JSON pref (`custom_links.*` / `home.module.most_visited.enabled`), browser-owned
    mutable state Nix must not seed → one click in **Customize Chrome ▸ Shortcuts ▸ Hide
    shortcuts**. ungoogled's `--custom-ntp` flag is not a route either: `chromium-flags.conf` is
    Linux-only, so on macOS it needs `chrome://flags`.
  - **Three manual, one-time clicks Nix cannot do:** Chromium parks every *externally* installed
    extension disabled pending acknowledgement on macOS (enable once → `ack_external` sticks;
    `ExtensionInstallForcelist` can't help, it needs the patched-out Web Store), and Chrome 138+
    gates Violentmonkey's `userScripts` permission behind a per-extension "Allow User Scripts"
    toggle that is deliberately not settable by policy, plus its sibling "Allow access to file
    URLs" toggle, without which it refuses a `file://` install off the index page (fallback:
    paste the script into Violentmonkey's own editor). The theme rides the same gate — until
    it is enabled once, Chromium unpacks it but leaves `extensions.theme` unset and the browser
    still looks stock.
- **The media stack is a CAPSULE, not a module in this directory.** `media-queue.nix`, the
  media CLIs and the Finder Services left for
  [`kattakath/nix-media-cli`](https://github.com/kattakath/nix-media-cli) on 2026-09-05 and came
  back in-tree on 2026-09-12 as `modules/features/media-cli/` (ADR-002 wave 5). They reach the
  Mac as one home-manager module: `local.mediaCli.enable`, set from `home.nix` on
  `isMacosHost`. Everything that used to be documented here — the three `QueueDirectories`
  tiers, `ProcessType = "Background"`, the `SIGSTOP`/`SIGCONT` pause, the `MAINPID` orphan
  adoption, the deliberate absence of a GUI status surface — lives with the code, in that
  capsule's `packages/media-queue.nix` header and `module.nix`.

  Two things changed in the EXTRACTION and are worth knowing here, because both were invisible
  couplings this repo was supplying by accident — and both survived the absorption unchanged,
  which is the point of bringing the code back rather than the old vendored shape:

  - **The launchd `arg0`.** The agents' `nix-media-queue` basename came from this repo's
    VENDORED `hm-launchd` fork; upstream home-manager emits `/bin/sh -c 'wait4path … && exec …'`
    instead. That is not cosmetic — a `/nix/store` arg0 is what lets the worker read the
    TCC-protected folders it exists to work on. The capsule's module therefore builds its own
    named wrapper, so it needs no fork and works on stock home-manager — and
    `checks.<system>.media-cli-module` asserts the arg0 is both `nix-*` AND a store path.
  - **The vision model** was a hardcoded literal, so no environment variable could have
    overridden it. It is now a `defaultModel` derivation argument, surfaced as
    `local.mediaCli.visionModel`.

  `rclip` stays HERE (`rclipCli` in `home.nix`, with its `dontCheckRuntimeDeps` override and
  `RCLIP_USE_ONNX_ON_MACOS`): it is a third-party search tool this repo merely installs, and
  the VECTOR half of retrieval, deliberately independent of the XMP half. It reaches the stack
  through that module's `extraSearchPackages` seam, alongside `exiftool` and `auge`.
- **`default-browser.nix`** — `local.defaultBrowser`, a fleet-level concern rather than a
  Chromium one: the HTTP/HTTPS handler is a LaunchServices property any installed browser can
  hold, so it moved out of `chromium.nix` once Chromium stopped being the daily browser and
  became the debugging one. Takes `defaultbrowser`'s SHORT name — the last dot-component of the
  bundle id, lowercased (`com.google.Chrome` → `chrome`, `org.chromium.Chromium` → `chromium`,
  also `operaair`, `opera`, `safari`); a bundle id itself is rejected, and `null` claims
  nothing. **The fleet holds `chrome`, and the reason is PASSKEYS, not preference.** Reaching a
  macOS Passwords.app passkey needs the RESTRICTED entitlement
  `com.apple.developer.web-browser.public-key-credential`, which Apple grants per-Team-ID to
  registered browser vendors on request. Verified 2026-09-15 with `codesign -d --entitlements`:
  Chrome (`EQHXZ8M8AV`) carries it plus `com.google.common.folsom` (iCloud Keychain) and
  `com.google.Chrome.webauthn{,-uvk}` (Touch ID); Opera and Opera Air carry the same shape;
  Safari has the WebKit equivalent; **ungoogled-chromium carries NEITHER** — seven
  entitlements, all hardware/sandbox, and no `keychain-access-groups` key at all. So no
  Chromium swap fixes it, and the plain (googled) `chromium` cask is worse: DISABLED in
  Homebrew since 2026-09-01 for failing the Gatekeeper check. A community rebuild can never
  obtain the grant — do not re-attempt. The sideloaded iCloud Passwords extension does not
  rescue it either; that does passwords, while a macOS passkey comes from the
  AuthenticationServices API the browser itself calls. Two behaviours worth knowing before
  blaming an activation: the tool early-returns when the handler already matches, so a settled
  Mac is a true no-op; and the activation that actually CHANGES it raises one macOS consent
  dialog, which is Launch Services' documented behaviour for browser schemes, not a bug. `duti`
  was passed over — bundle ids, but no idempotence guard, so it would re-ask every activation.
- **`ubersicht.nix`** — `local.ubersicht`, the fleet's ONE Übersicht widget: `htmlWidget` is
  a runtime shell path (a `$HOME` string, never a store path) to a single HTML file the widget
  `cat`s and renders full-screen with no chrome, re-read every `refreshMinutes` (5). A plain
  `home.file` symlink into Übersicht's watched widgets directory
  (`~/Library/Application Support/Übersicht/widgets/html-fullscreen.jsx`) — hot-loaded, no
  activation shim, no launchd unit. Upstream-first: neither home-manager nor nix-darwin has an
  Übersicht option (grepped 2026-09-15). The app itself is the `ubersicht` cask in
  `hosts/macos.nix`; the file goes into an `<iframe srcDoc>` so a full HTML document keeps its
  own `<head>`/CSS instead of leaking into Übersicht's page. The file lives in
  `~/.local/share/ubersicht/`, NOT `~/Documents`/`~/Desktop`/`~/Downloads`: Übersicht shells out
  via `/bin/sh`, which TCC denies in those three.
- **`next-right-thing.nix`** — `local.nextRightThing`, the generator that decides what the
  Übersicht widget SAYS. Split from `ubersicht.nix` so that module stays "render whatever HTML is
  at this path" and remains reusable; `local.ubersicht.htmlWidget` is single-sourced from
  `outputPath` here so writer and reader cannot drift. A `launchd.agents.next-right-thing`
  (`StartInterval`, default 20 min, `nix-next-right-thing` arg0 via `launchd-launcher.nix`) runs
  six scripts from `packages/next-right-thing/`: `probe.sh` is cheap change-detection that decides
  whether a run earns a model call at all, `gather.sh` collects candidate signal as plain text
  using no MCP and no model, `art.sh` caches a fallback wallpaper, `decide.sh` calls `claude -p`
  under an enumerated read-only tool allowlist (never `tg_send`, and never `tg_read` — despite the
  name it MARKS MESSAGES READ), `render.sh` emits one self-contained Duochrome card, and `run.sh`
  publishes atomically via a same-filesystem rename. The `probe`/`gather` pair is the cost control:
  the expensive step is reached only when something actually changed. It shows exactly ONE
  action: a dashboard forgives a bad ranking because the eye finds the real item among nine, but
  with one card a wrong pick IS the product — hence the art fallback, which lets the generator
  decline to speak. Darwin-gated; a clean no-op on `nixpi`.
- **`terminal-theme.nix`** — `local.terminalTheme`, the ONE place the fleet's 16-slot ANSI
  ring, ground/ink/cursor, and font face + per-surface sizes are stated. Publishes a derived
  view at `config.lib.terminalTheme` (`byName`, `ghosttyPalette`, `toRgb16`) through
  home-manager's own `options.lib` extension point (pinned `modules/misc/lib.nix:5`) — the
  same seam `config.lib.base16` and `config.lib.stylix` use. **Pure options, no packages, no
  activation, no platform gate**, so it evaluates on `aarch64-linux` too; each consumer keeps
  its own gate. Ghostty and VS Code take **16/16** slots, Terminal.app **4/16** (an OS
  ceiling, not a gap — `sdef Terminal.app | grep -ci ansi` is `0`). Before this existed, VS
  Code held **pre-lift Tango in 7 of 16 slots** while Ghostty held the WCAG-corrected values.
  **stylix was rejected on measurement, not taste** — its Ghostty target hardcodes
  `"9=${base08}" … "14=${base0C}"`, so brights collapse onto normals and 8 of 16 values come
  out wrong, for +16 lock nodes. Full reasoning: [`terminal-theme.md`](terminal-theme.md).
- **Ghostty** (`programs.ghostty` in `home.nix`, `macos` only) — GPU-accelerated terminal,
  installed as a **Homebrew cask** because nixpkgs' `ghostty` is **Linux-only** and refuses to
  evaluate on aarch64-darwin. That is precisely the case home-manager documents for
  `package = null` ("set this on platforms where ghostty is not available"), so the cask ships
  the app and Nix owns nothing but `$XDG_CONFIG_HOME/ghostty/config` — the same split already
  used for the ungoogled-chromium cask. Settings deliberately **match the existing terminal**
  rather than introduce a second look. **Colours and type are not stated here at all** —
  they come from `terminal-theme.nix` via `programs.ghostty.themes.fleet`, selected with
  `settings.theme = "fleet"`, which is upstream's own option for exactly this (pinned HM
  `modules/programs/ghostty.nix:67`, written to `$XDG_CONFIG_HOME/ghostty/themes/<name>` at
  `:172-179`). **The inline colours had to be DELETED, not merely supplemented**: an explicit
  `background`/`foreground`/`palette` in `settings` overrides a theme's, so keeping both would
  make the theme file dead weight. System-following stays off deliberately, but is now
  *reachable* — `light:NAME,dark:NAME` applies to `theme`. The palette's derivation lives in
  [`terminal-theme.md`](terminal-theme.md).

  On the SPLITS specifically, a nine-agent workflow derived four alternatives that improved
  the contrast numbers and each lost the thing worth having — the winner lifted the *unfocused* ground and thereby made the panes you
  are **not** in the loudest thing on screen, which no contrast metric can see.
  **`unfocused-split-fill` is deliberately unset**: it then defaults to `background`, so the
  unfocused ground is unchanged and only the text dims (17.58:1 → 6.80:1). Ground stays
  identical across both panes *and* the titlebar. **`window-titlebar-background` is not used**
  — Ghostty's own docs say it "only takes effect if window-theme is set to ghostty" and is
  "currently only supported in the GTK app", so on macOS it validates but is **inert**; the
  titlebar takes `background`, and `macos-titlebar-style` is the only real lever.
  `enableZshIntegration` is deliberately **off**: it sources the integration script out of the
  Nix `package`, which is null here, so it would point at nothing — the cask's app bundle
  injects shell integration itself.
- **`desktop-aesthetics.nix`** — the macOS desktop look, split in two:
  - **Terminal.app** is UNGATED on every darwin host — type on EVERY profile, and the four
    colours macOS actually exposes (`background`/`normal text`/`bold text`/`cursor`) plus
    `font name` on `Pro`, which this block also forces as default/startup. Values come from
    `terminal-theme.nix`; this module owns **delivery**, never the palette. Driven through
    Terminal's own AppleScript `settings set` API since Terminal owns `com.apple.Terminal`
    and clobbers direct plist writes. Guarded on Terminal already running so a rebuild never
    launches it — with **`pgrep -x Terminal`, never a `ps | grep -q` pipe**. An earlier
    comment claimed the opposite ("`pgrep` can't see it from activation"); that was a
    misdiagnosis. home-manager's generated activate script runs under `set -o pipefail`,
    `grep -q` exits the instant it matches, the closed pipe kills `ps` with SIGPIPE, and the
    pipeline reports 141 on a *successful* match — so the guard skipped forever on a Mac
    where Terminal was running. Measured in the real activation context
    (`launchctl asuser <uid> sudo -u <user>`): the pipe form exits 141, `pgrep` exits 0. Rule:
    no pipe in a guard that runs under `pipefail`. Every property
    is compared before it is written, so a settled Mac is a true no-op. This repo used to
    VENDOR an "Ubuntu" profile + generator here; #319 dropped that, and Apple's scripting
    interface replaced it — which is also why the ANSI ring is unreachable (it lives only in
    the NSKeyedArchiver blobs a `.terminal` profile carries). Writes **unversioned user
    state**: `home-manager rollback` does not revert `com.apple.Terminal`.
  - The **custom wallpaper** stays behind `local.desktopAesthetics.enable` (default true;
    the former `macvm` guest set it false as a visual tell).
- **`nix-cache.nix`** — the Cachix binary-cache option (see § Binary cache below).
- **`nix-ld-libraries.nix`** — the shared nix-ld library list.
- **`wireguard-configs.nix`** — operator-managed WG confs synced to `~/.config/wireguard`, no
  autostart; import-only for the `WireGuard.app` GUI (the `vpn` CLI left with the `macvm`
  guest, 2026-09-05 — [`macvm-readd-runbook.md`](macvm-readd-runbook.md)).
- **`claude-otel.nix`** — `local.claudeOtel`, real-Mac-only: a local OTel Collector
  receiving Claude Code's native OpenTelemetry `tool_decision`/`tool_result` events over
  localhost OTLP, writing a rotating JSONL for `/routing-review` to mine for
  deterministic-routing hardening candidates. See
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`claude-bedrock-gate.nix`** — **Bedrock routing's governance**: a `nix-bedrock-gate` shell
  hook that makes Claude Code's Bedrock routing conditional on an AWS identity actually
  resolving, instead of on `CLAUDE_CODE_USE_BEDROCK` merely existing.
  - **The identity is runtime-owned (2026-09).** `~/.aws/config` belongs to the `aws` CLI
    (`aws configure sso`), like the SSO tokens in `~/.aws/sso/cache` always did — it is in
    no repo. The gate resolves the profile (`AWS_PROFILE`, else `default`) and the region
    (shell → `settings.json` `env` → that profile's `region` key; never `sso_region`), and
    the hook **exports** a file-derived `AWS_REGION`, because Claude Code reads the region
    from the environment only (anthropics/claude-code#18962). Select a non-default profile
    with `secret set AWS_PROFILE <name>`. ADR-003's split: identity is content, the gate is
    governance.
  - **This module declares NO options.** `local.claudeBedrock.{region,profile}` — which wrote
    `AWS_*` into `settings.json`'s `env` — was deprecated when the identity became
    runtime-owned and **deleted 2026-09-15**, once nix-personal (the only thing that ever set
    it) was retired. The settings.json writer and its deprecation warning went with it. Do not
    reintroduce them: a value there overrides the runtime `~/.aws/config` in every session,
    which is the exact failure this module exists to prevent. There is deliberately no
    `enable` option either — `CLAUDE_CODE_USE_BEDROCK` stays in the login Keychain so it
    remains a runtime toggle.
  - **`adoptAwsConfig` — the one-shot migration.** When no `home.file` entry targets
    `.aws/config`, an activation step between `writeBoundary` and `linkGeneration` replaces a
    leftover store symlink with a real `0600` copy. Ran once, when nix-personal's `aws-sso.nix`
    (which store-symlinked the file) stopped being evaluated — home-manager's orphan cleanup
    would otherwise have deleted the symlink and every profile with it.
  - **The trap it closes** is unchanged: the Keychain flag survives every activation, a
    missing identity does not, and a read-only `settings.json` cannot be hand-repaired. It
    degrades to Claude Code's default provider rather than erroring. Offline and CLI-free by
    design (local files only; no `aws sts` call per shell). Companion: the
    `.claude/hooks/pretooluse-bash-guard.js` block, which only covers activations the *agent*
    runs; this covers a switch typed by hand.
- **`claude-guardrails.nix`** — the **global guardrail floor**: user-scope
  `programs.claude-code.settings` (upstream `jsonFormat.type`, so it is freeform and the deny
  list concatenates with any other module's), darwin-gated, no options, no hooks, no scripts.
  Exists because every decision hook in `.claude/` is project-scoped — sessions in any other repo
  had none of them while VS Code starts in `bypassPermissions`, and the globally-wired
  `mcpfinder` exposed its config-writing tool everywhere but here. Two halves:
  - `permissions.deny`. Entry rule: a fleet-wide policy already written down (imperative MCP
    adoption, secret values in the transcript — `secret reveal`, `security find-*-password
    -w/-g`, and since 2026-09-21 `agenix -d` / `age -d` age decryption — `/run/agenix` and
    OpenTofu-state plaintext, `gh pr merge`, force-push) — never repo policy. Deny rules still
    apply in `bypassPermissions` (it skips prompts; a deny is not one), but they match the
    command text Claude writes, not `sh -c` or an absolute binary path — a floor, not a
    boundary. **No catch-all `Read(**)`**: a blanket Read deny disables Bash auto-approve
    everywhere, so the path denies stay narrow on purpose.
  - `attribution = { commit = ""; pr = ""; sessionUrl = false; }` (2026-09-21) — mechanises
    `claude/CLAUDE.md` § Git authorship, which forbids `Co-Authored-By: Claude` trailers and
    "Generated with Claude Code" PR footers but had to be re-won each session against Claude
    Code's own session-start reminder. All three sub-keys are required: setting only `commit`
    makes Claude Code ignore the deprecated `includeCoAuthoredBy` and fall back to its DEFAULT
    PR text, and `sessionUrl` is a separate `Claude-Session` trailer that appears only from
    cloud/Remote Control sessions.
  - **Not the top tier any more.** Since 2026-09-21 `modules/darwin/claude-managed-settings.nix`
    restates the secret-value denies and all three `attribution` keys at **managed** scope on
    `macos`, where a deny cannot be retracted by any lower scope and every per-key precedence
    sentence in claude-code 2.1.260 puts managed first. The two are ADDITIVE, not a
    replacement: this file is the only tier that reaches the devcontainer and machines this
    Home Manager config never touched. See § `modules/darwin/`.
- **`claude-desktop.nix`** — `local.claudeDesktop`, **Client side D** of the MCP hub: the
  gateway's `endpoints` plus the per-client stdio servers rendered into Claude Desktop's
  stateful `claude_desktop_config.json`. Desktop accepts ONLY the stdio shape, so every
  `url` becomes a pinned `mcp-remote` shim (`lib.hm.mcp.transformMcpServer` + one
  `extraTransform`, the codex module's pattern); an activation merges ONLY `.mcpServers`
  and ONLY entries carrying the `NIX_CONFIG_MANAGED` env marker, so hand-added servers and
  Desktop's own keys survive. `desktop-commander` is excluded (it is a Desktop Extension
  already). Everything here is also proxied into a linked Cowork session as
  `mcp__remote-devices__<name>__*`. Contract held by `checks.claude-desktop-config-shape`.
  Full rationale: [`docs/claude-desktop-mcp.md`](claude-desktop-mcp.md).
- **`claude-plugins.nix`** — `local.claudePlugins.marketplaces`, the **N-marketplace** Claude
  Code plugin mechanism. An `attrsOf submodule` keyed by marketplace name, each carrying a
  `source` (a `/nix/store` path or an `https://` git URL — asserted, so an impure
  `toString ../plugins` fails loudly), a `plugins` list of BARE names, and a derived `repin`
  flag. Install ids are derived as `<plugin>@<marketplace>`, single-sourcing
  `settings.enabledPlugins` and the install loop so a plugin can never be
  installed-but-disabled through a typo.
  - **Why it exists.** This was a single-marketplace mechanism inlined in `home.nix`
    (`claudePluginIds` / `localPluginsMarketplace` / `home.activation.claudeCodePlugins`)
    until nix-personal needed a second marketplace and grew a near-verbatim 80-line COPY of
    the activation script, ordered `entryAfter [ "claudeCodePlugins" ]` so the two would not
    race on mutable `~/.claude`. `attrsOf` merges by key, so the private layer now adds one
    attribute, there is exactly one script, and the race has no reason to exist. `plugins`
    being a `listOf` means a private layer can also append a plugin to a marketplace THIS
    repo declares — impossible before.
  - **`source` is a scalar on purpose.** A marketplace has exactly one source, so two
    differing definitions SHOULD be a loud conflict, not a silent pick. It is `mkDefault`
    here so a downstream layer can repoint one (a fork of the official marketplace, say)
    with a plain assignment. Everything a private layer needs to ADD merges.
  - **Path-literal trap.** `source = "${../../plugins}"` is a Nix SOURCE PATH LITERAL,
    resolved relative to the `.nix` file it is written in. The same line moved to another
    flake silently re-points at THAT flake's `plugins/`, so each repo's marketplace entry
    must stay in the repo that owns the tree — which is why nix-personal keeps its
    `plugins/` directory and a 5-line module, rather than shipping the tree here.
  - **Two phases, not fused.** Every marketplace is pinned first, then ONE flat install loop
    runs. Pin-then-install per marketplace would let a later re-pin teardown uninstall a
    plugin the loop had already installed. `programs.claude-code.marketplaces` (upstream) is
    still unusable for the same two reasons as before: it writes a Nix-managed
    `known_marketplaces.json` symlink where the CLI needs a mutable file, and the reserved
    `claude-plugins-official` rejects directory pins as untrusted.
- **Git SSH signing principals** — no module of its own any more. `git-allowed-signers.nix`
  and its custom `kattakath.git.extraAllowedSignersPrincipals` option were **deleted**
  2026-09-13 in favour of upstream's own `programs.git.signing` (pinned home-manager
  `programs/git.nix:63-116`; impl `:470-506` writes `$XDG_CONFIG_HOME/git/allowed_signers` and
  points `gpg.ssh.allowedSignersFile` at it). `modules/shared/home.nix` sets the fleet default
  principal (`userEmail`); because `allowedSigners` is a `lines` option, extra identities
  simply **append** — the persona addresses `izzy@silvercreek.ai` and `hi@izzykatt.ca` are
  listed alongside it, which is how the retired nix-personal layer's principals came across
  with no custom seam.
- **`wallpaper/wallpaper.png`** — the vendored desktop wallpaper `desktop-aesthetics.nix`
  installs. It is copied to `~/.local/share/nix-desktop-wallpaper.png` via `home.file` and
  pointed at from there, **not** referenced as a store path directly: `settings.picture` set
  to a store path leaves the wallpaper out of the generation's closure, so
  `nix-collect-garbage` would delete the file out from under the desktop.
- **`hm-launchd/`** — replaces stock HM launchd so every agent's `ProgramArguments[0]`
  basename is `nix-<activity>` (macOS BTM rule — tags nix-config origin; **never** a bare
  interpreter like `sh`/`python3`). It is upstream's own `waitForNixStore = false` trade
  (pinned HM `modules/launchd/default.nix:47-52`): a named launcher instead of a
  `/bin/sh -c wait4path` arg0, accepting that launchd's exec fails outright if it fires
  before `/nix` is mounted. There is **no** wait4path "inside the wrapper" — a wrapper that
  itself lives in `/nix/store` could never run one. This is **mandatory
  for every launchd unit this repo authors**: HM user agents are auto-wrapped here, and any
  hand-written `launchd.daemons`/`launchd.agents` MUST point `arg0` at a
  `writeShellScriptBin "nix-<activity>"` wrapper (canonical:
  `telegramMcp`/`wpMcp`/`apifyMcp` in `mcp.nix`) — codified as the always-applied
  [`launchd-naming.md`](../.claude/rules/launchd-naming.md) rule, which also documents the
  three known-upstream `/bin/sh` exceptions that are NOT ours and must never be renamed.
  **The fork is GONE (2026-09-14).** It shrank to one file, then to none: the pinned
  home-manager grew the three options it existed for, so `modules/shared/launchd-launcher.nix`
  (53 lines) now just sets them — `waitForNixStore = false`, `launcher.name`, `launcher.shell`
  — and upstream's own `mutateConfig` rewrites both `Program` and `ProgramArguments`. The
  drift check that guarded the fork (`hm-launchd-drift`, which pinned the sha256 of upstream's
  `default.nix`) went with it; there is nothing left to drift against. This is the repo's
  worked example of the [`upstream-first`](../.claude/rules/upstream-first.md) rule paying
  off: a 560-line vendored copy deleted the moment the input owned the behaviour.

### Home-Manager modules that are not in `modules/shared/`

Three whole features reach the Mac's Home Manager profile from outside this directory, each
behind **one** `enable`. One is now an in-tree capsule; two are still flake inputs (ADR-002
waves 5-6 absorb them).

- **`modules/features/keychain-secrets/`** (an IN-TREE CAPSULE — it was extracted from this
  repo into the standalone MIT `nix-keychain-secrets` flake, then absorbed back by ADR-002
  wave 4) — `local.keychainSecrets`: the macOS login-Keychain `secret` CLI
  (`secret`/`set-secret`/`remove-secret`/`pb-conceal`) plus `~/.config/secrets/loader.sh`, a
  loader wired into **all four** shell entry points so even the non-interactive bash an agent
  spawns gets the operator's tokens. Darwin-gated internally, a clean no-op on the NixOS
  hosts. Full behaviour: [`secrets-and-keychain.md`](secrets-and-keychain.md) and the
  capsule's own `README.md`.

  **It is a security surface, so two cross-file contracts are gated rather than trusted.**
  (1) `modules/darwin/core.nix` derives `launchd.user.envVariables.BASH_ENV` from
  `local.keychainSecrets.loaderRelPath` **by reference** — that is the only thing covering
  a bash spawned by a GUI app or a launchd job, which descends from no shell at all; the
  capsule's `checks/module-evaluates.nix` pins that option's DEFAULT as a literal, so a
  rename cannot move one half without the other. (2) `modules/shared/claude-bedrock-gate.nix`
  writes the same three shell-init options at `lib.mkOrder 1600` and must run AFTER this
  module's `lib.mkAfter` (= 1500), because it reads a variable this loader exports — run it
  first and it sees an unset variable, does nothing, and Claude Code silently keeps a Bedrock
  route it cannot use. Nothing checked that until wave 4 put both halves in one evaluation;
  `checks.aarch64-darwin.bedrock-gate-after-loader` (`modules/parts/checks.nix`) now asserts
  it against the REAL `macos` config, on all three surfaces.

  Reached through `modules/parts/compose.nix` as the `keychainSecretsModule` specialArg, from
  the `capsuleModules` seam rather than `flake.modules` — see § `modules/features/` for the
  measurement behind that. Its three darwin CLIs are still `packages`/`apps`
  (`nix run .#secret`), registered by the capsule itself; `pb-conceal` is deliberately
  installed but not published, exactly as before the absorption.

- **`modules/features/local-rag/`** (an IN-TREE CAPSULE — extracted from this repo to
  `kattakath/nix-local-rag` on 2026-08 and absorbed back by ADR-002 wave 6, the last
  satellite) — `local.rag.ollama` + `local.rag.pgvector`, the loopback RAG stack
  (launchd Postgres+pgvector+pgsql-http, a local Ollama embed model, and the in-DB `embed()`
  that makes retrieval plain SQL). Threaded in as `localRagModule` through the RAW
  `capsuleModules` seam. **It measured drv-identical on BOTH seams** — unlike keychain-secrets
  it contributes nothing to `home.packages` directly — and rides the raw one anyway for
  consistency and because order-insensitivity here is a property of today's contents, not of
  the class; the reasoning is in its `flake-module.nix` header.

  The seam that matters is `local.rag.pgvector.databaseUri`: `modules/shared/mcp.nix`
  hands it to the `postgres` MCP server as `env.DATABASE_URI`, which is the career RAG's only
  path to Claude Code. `checks.<system>.local-rag-module` pins that URI as a **literal** so a
  port/role/db rename fails there instead of silently returning zero rows, and
  `local-rag-inert` is the kill-switch gate — both switches unset must contribute nothing,
  which is the state `nixpi`/`nixvm` are in since `modules/shared/home.nix` imports it
  unconditionally. There is deliberately **no** wrapping `programs.localRag.enable`
  (ADR-002 §4's "two-switch regression"). It registers no packages: everything it installs is
  nixpkgs', reached through `home.packages` from inside the two modules.

  It was the only satellite with a SECOND consumer — `ircc-whatsapp-bot` pinned it too, which
  is why that unpin (ircc grew a `botOnly` output) was an ADR-002 wave-0 prerequisite rather
  than part of the absorption diff.
- **`modules/features/media-cli/`** (an IN-TREE CAPSULE — it was extracted from this repo to
  `kattakath/nix-media-cli` on 2026-09-05 and absorbed back by ADR-002 wave 5) —
  `local.mediaCli`, the eleven media CLIs + the launchd work queue + the Finder Services,
  `macos`-only because of closure size. Threaded in as `mediaCliModule` through the RAW
  `capsuleModules` seam rather than `flake.modules` — see § `modules/features/` for the
  measurement. Its eleven packages are deliberately **not** re-published as flake outputs
  (nix-config never carried one); `checks.<system>.media-cli-packages` builds all of them, so
  the shellcheck coverage the satellite's CI had is kept.

### `modules/darwin/`

`modules/darwin/{core.nix,user-folders.nix,homebrew.nix,nix-homebrew.nix,xcode-license.nix,github-runner.nix,ollama-daemon.nix,claude-managed-settings.nix}`

- **`core.nix`** — macOS system defaults (dock/finder/NSGlobalDomain, Touch ID for sudo,
  `stateVersion = 5`). On **macos only**: login openers (`nix-*` BTM wrappers) + two
  `mkTrashSweep` rotations into `~/.Trash` (paired with `finder.FXRemoveOldTrashItems` so
  Trash self-purges): **`~/Desktop`** — the capture inbox (⇧⌘4/⇧⌘5 land there by macOS's own
  default; the real Mac sets no `screencapture.location`) swept whole after **1 day**;
  **`~/Downloads`** — the browser/AirDrop inbox, swept after **7 days** of disposable types
  only (media/installers/archives allowlist; documents and directories stay for manual
  triage). `screencapture.location` is now unset everywhere (the shared-inbox override left
  with the `macvm` guest, 2026-09-05).
- **`user-folders.nix`** — the `local.folders.{desktop,downloads}` options: unset = the
  macOS system default (`~/Desktop`, `~/Downloads`), override = the relocation seam; an
  invalid (non-absolute) value fails loudly at eval rather than silently falling back.
  Consumed by core.nix's sweeps/screencapture gate — folder paths are never re-derived
  inline.
- **`homebrew.nix`** — the declarative Homebrew **framework**: owns only
  `enable`/`onActivation` with `cleanup = "uninstall"`/`taps`. The actual
  `brews`/`casks`/`masApps` lists live **per host** in `hosts/<host>.nix` so each darwin
  host carries its own app set.
- **`nix-homebrew.nix`** — Homebrew-itself install via `nix-homebrew`.
- **`xcode-license.nix`** (macos only) — runs *before* `brew bundle` to `mas install` Xcode
  when declared in `masApps` and `xcodebuild -license accept`, so formulae are not blocked by
  an unaccepted SDK license (Brewfile order is brews→casks→mas).
- **`github-runner.nix`** — `local.macosGithubRunner`: N hand-rolled launchd daemons running
  **ephemeral, org-level self-hosted GitHub Actions runners**. Built then retired 2026-07-16
  once nix-config's own CI no longer needed one; **revived 2026-08-23 for a different consumer**
  — `dontsell-ai`'s repos, whose macOS + Playwright + Prisma jobs neither GitHub-hosted (no
  hosted-minutes budget on that org) nor the native Linux builder (build-only, ephemeral,
  1 CPU / 8 GiB by default) can serve. `hosts/macos.nix` enables it with `count = 2`.
  - **Hand-rolled on purpose:** nix-darwin's `services.github-runners` hard-asserts
    `nix.enable = true` (it takes the runner's `nix` from `config.nix.package`), which is
    mutually exclusive with Determinate Nix (`nix.enable = false`). This module reproduces
    upstream's launchd setup and substitutes `pkgs.nix` — nothing else differs.
  - **Auth:** a GitHub **App** RS256 private key (the host-decrypted
    `gh-app-dontsell-ai-key.age`), used to mint a fresh ~1 h installation token per
    registration rather than holding a long-lived bearer credential. Scoped to *only*
    "Organization permissions → Self-hosted runners: Read and write".
  - **Security:** `--ephemeral` (one job per registration; launchd restart + re-register makes
    it self-healing), outbound-only. Only trusted push jobs may target `runs-on: [self-hosted,
    …]` — **never fork-PR workflows**, since the daemon inherits the operator's login
    environment. `arg0` is nix-darwin's `/bin/sh -c 'wait4path /nix/store && exec …'` wrapper —
    the launchd-naming rule's **boot-ordering exception** for daemons; the exec'd process is
    still `nix-github-runner-<instance>`.
  - **Labels:** `extraLabels` (default `[ "nix" ]`) is passed as `--labels` **without**
    `--no-default-labels`, so the effective set is `{self-hosted, macOS, ARM64} ∪ extraLabels`
    — GitHub assigns the first three server-side. `nix` is the **positive** toolchain
    discriminator against the Tart-VM lane (`local.tart.githubRunners.*`, which carries `tart` and
    runs in a stock Cirrus guest with no nix/cachix/postgres). Both lanes register into
    `dontsell-ai`'s single `Default` group, so without `nix` the only thing telling this lane
    apart is the *absence* of `tart`, and GitHub has no negative selector. **Widening a label
    set is free; narrowing is not** — `runs-on:` is a hard AND-match, so always: widen → verify
    live on an ONLINE runner for that scope → flip consumers one repo at a time → narrow last.
  - Also pins `postgresql`+pgvector onto the runners' PATH (`modules/shared/home.nix`, `hiPrio`
    to resolve the duplicate `bin/psql`).

- **`ollama-daemon.nix`** — `local.ollamaDaemon`: ONE machine-wide `ollama serve`, so
  every account shares one process and one model store. It exists because a second account
  cannot share home-manager's `services.ollama`: that emits `launchd.agents.ollama`, which
  lives inside ONE login session and keeps its models in that user's home, forcing a choice
  between a duplicate 31 GB store and a server that vanishes when the operator logs out.
  Models live in `/var/lib/ollama/models` (the same `/var/lib` convention `github-runner.nix`
  uses); relocating the existing 31 GB was a RENAME, since /Users and /private/var are
  firmlinked onto the same APFS data volume.

  **upstream-first:** grepped the pinned nix-darwin — `modules/services/` has no `ollama.nix`
  and the string appears nowhere under `modules/`. Nothing models this, so the daemon is
  custom, but built on nix-darwin's own `launchd.daemons` primitive.

  Two details are load-bearing. It uses `command`, not `ProgramArguments`, because the
  boot-ordering exception in [`launchd-naming`](../.claude/rules/launchd-naming.md) applies:
  a `RunAtLoad` daemon whose arg0 is a store path loses the race against determinate-nixd
  mounting `/nix`, exits 78, and never self-heals. And `environmentVariables` carries the
  POWER BUDGET (`OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KEEP_ALIVE=10m`).
  Those moved here from `services.ollama.environmentVariables` in `modules/shared/home.nix` —
  they had to, because that option only ever reaches home-manager's own agent, so the block
  went inert the moment the capsule stopped managing the server. The local-rag capsule gained
  `local.rag.ollama.manageServer` (set false) so it does not stand up a competitor on 11434.

- **`claude-managed-settings.nix`** (macos only, `local.claudeManagedSettings`) — the fleet's
  strongest agent-policy tier: a **root-owned** `/Library/Application Support/ClaudeCode/
  managed-settings.json`, written by `system.activationScripts.postActivation` with `install`
  (so content, mode 0644 and root:wheel are re-asserted every activation, not hoped for) —
  **marker FIRST, policy second**, because activation runs under `set -e`: policy-first meant a
  marker that failed to land stranded a root-owned policy file the kill switch could then never
  delete, while the inverted order's worst partial state is a marker with no policy, which
  `enable = false` cleans up. It also defines `system.activationScripts.checks.text`
  (`mkAfter`) — an **ownership precondition that ABORTS activation with exit 2** if
  `managed-settings.json` exists WITHOUT the `.nix-config-owned` marker beside it, naming both
  paths and telling the operator to rename the foreign file `.before-nix-darwin` (or set
  `enable = false`). It sits in `checks`, not `postActivation`, because `checks` is spliced
  BEFORE /etc, launchd, defaults and Homebrew, so activation can still back out cleanly.
  **What managed scope buys**, claimed only as far as the shipped binary (claude-code 2.1.260)
  evidences it, and split because the two halves lean on different properties: the deny list
  needs UNION, not override — "--disallowedTools and other deny and ask rules from the command
  line or the current session still apply", plus "Cannot delete permission rules from read-only
  settings" for the no-retraction half; `attribution` is value-resolved and needs the LADDER,
  where the strongest honest claim is that every per-key precedence sentence naming the sources
  puts managed first (`processWrapper`: "Honored from managed settings, a --settings/SDK-supplied
  settings file, and user settings, in that precedence order"; `modelPicker`: "the
  highest-precedence of those that defines modelPicker wins outright") and none states the
  reverse. NOT evidence for either, though this page cited it as such: `server-managed > MDM >
  managed-settings.json` describes how managed SOURCES compose AMONG THEMSELVES (first-wins vs
  merge) — a no-op here, since this fleet has exactly one managed source. So the floor still
  holds in a session where `~/.claude` was never materialised or was hand-edited,
  and under `bypassPermissions`, which this fleet's VS Code extension and `claude` terminal
  profile both start in.
  - **Content = the SECRET-VALUE denies + the three `attribution` keys**, restated verbatim
    from `modules/shared/claude-guardrails.nix`. The duplication is the point, not drift:
    `permissions.deny` lists from every scope COMBINE (duplicates dropped), and each scope
    reaches where the other cannot — user scope reaches the devcontainer and any clone on a
    machine this Home Manager config never touched, managed scope reaches a session whose
    `~/.claude` was never written. Deriving one from the other by string-matching was rejected
    for the same reason `claude-guardrails.nix` records twice in its BODY (the `mcpfinder` note
    and the `attribution` note — not its header): a reworded upstream rule would yield a
    well-formed and completely EMPTY floor. The reverse pointer lives where an editor actually
    lands, immediately above the secret-value deny group in that file: *EDIT THIS GROUP, EDIT
    IT TWICE.*
  - **Scope rule for a new entry, one notch stricter than the user floor:** it must already be
    in `claude-guardrails.nix` AND be pure "never print a secret value" / "never sign work as
    an AI". Nothing that merely narrows a workflow, because there is no in-session override
    here — undoing a wrong entry is a rebuild, not a `/permissions` click. That is why the
    imperative-MCP and irreversible-remote groups (`gh pr merge`, force-push) stay at user
    scope.
  - **Path spellings are load-bearing:** only `//` and `~/`. A single leading `/` anchors at
    the settings SOURCE, and what that resolves to for the managed tier is undocumented — a
    `Read(/run/agenix/**)` spelled that way would match nothing, silently. The four `Read`
    rules port verbatim from the user-scope file because they already carry the safe spelling.
  - **The kill switch is real:** `enable = false` DELETES the file rather than merely stopping
    the rewrite, guarded by a `.nix-config-owned` marker beside it so it can never remove an
    MDM payload this fleet did not place. The marker claims the PATH in both directions —
    while it is present, `enable = false` may delete that file; while it is absent, activation
    REFUSES to write one. Refuse, not adopt: adopting would let a rebuild claim ownership of a
    file we never wrote, which `enable = false` would then delete.
  - **upstream-first:** no nix-darwin option writes an arbitrary `/Library` file —
    `environment.etc` is hard-coded to `/etc` (`modules/system/etc.nix`), and
    `environment.launchAgents`/`launchDaemons` to `/Library/Launch*`
    (`modules/system/launchd.nix`); `system.patches` only reverses a diff over files that
    already exist, and `system.defaults.CustomSystemPreferences` writes a preferences DOMAIN,
    not a JSON file at a path. Home Manager's `programs.claude-code` writes under `$HOME` as
    the user. Anthropic's own channel is an MDM configuration profile; this fleet has no MDM.
  - **No `managed-mcp.json` here, deliberately** — deploying that file suppresses the
    claude.ai connectors Claude Code fetches for itself unless `allowAllClaudeAiMcps` is set
    alongside, and this fleet runs four Gmail connectors plus Drive, Calendar and Slack. MCP's
    source of truth stays `modules/shared/mcp.nix` (ADR-003 §5).
  - **Coverage limit + how to verify:** managed settings do NOT reach an Anthropic-hosted
    cloud session (only server-managed ones do), which is a further reason the user- and
    project-scope layers stay put. `nix flake check` cannot see any of this — `/status` inside
    Claude Code must list `Enterprise managed settings (file)` under `Setting sources`; that is
    a step in [`new-mac-runbook.md`](new-mac-runbook.md) § Manual steps Nix can't do. Because
    `pkgs.formats.json` already guarantees the bytes parse, what `/status` confirms is
    PLACEMENT; an unrecognised key stays accepted, listed and enforcing nothing.

### `modules/nixos/`

- **`modules/nixos/core.nix`** — shared NixOS baseline: the `ismail` user + authorized SSH key (the
  operator's static ed25519 key, the sole network login credential on every host), keys-only
  sshd (no password, no root login, no keyboard-interactive), a firewall that opens **no TCP
  port at all** (UDP 5353 only, for mDNS), avahi `<host>.local` publishing, native
  `programs.nix-ld`, zram swap, automatic GC.
  **sshd binds loopback only** — `listenAddresses = 127.0.0.1 + ::1` with `openFirewall = false`
  (clearing `allowedTCPPorts` alone is NOT enough; sshd's own module re-opens the port). So
  `nixpi`'s sshd is reachable *only* from on-host, which in practice means the tunnel connector
  terminating there (`cloudflared access ssh --hostname nixpi.kattakath.com`) — closing the LAN
  path that walked around the Access application entirely. Break-glass is the physical console.
  `nixvm` is only ever the throwaway local `nix run .#nixvm` desktop and has no networked login
  path either.

  **That posture is now a GATE, not just these paragraphs** —
  `checks.<system>.nixpi-security-posture` (2026-09-21, `modules/parts/checks.nix` via
  `mkHostContract`, so it reports every broken leg at once). It is **ungated** — built on
  `aarch64-darwin` as well as `aarch64-linux`, because the edits it guards are made ON the Mac:
  Linux-gating it would let an operator relax `core.nix`, run `/eval` clean, and learn otherwise
  only from CI. Cost measured 2026-09-21: one extra `nixpi` module eval on the darwin leg (~1 s;
  nothing else on that leg forces this config), and no `aarch64-linux` build, because only
  numbers and strings escape into the derivation. A comment cannot fail a build, and
  each of these lines is a one-token edit away from reopening the LAN path that Cloudflare
  Access is meant to be the only way through — Access enforces at the EDGE, so a LAN connection
  to port 22 is not merely unauthenticated, it produces **no access log at all**. 18 legs, each
  naming its own silent-failure mode:
  - `openFirewall = false` — upstream defaults it **true** and feeds `cfg.ports` straight into
    `allowedTCPPorts`, so deleting that one line reopens 22 with no other file changing.
  - `listenAddresses` NON-EMPTY, checked BEFORE the loopback leg: an empty list emits no
    `ListenAddress` line and OpenSSH binds the WILDCARD, while `all isLoopback [ ]` is vacuously
    true. The loopback leg is then a sorted EQUALITY, so it also proves both families are bound.
  - every listen address carries a **string** `addr` — its own leg, and the precondition both
    sorted comparisons need. The submodule declares `addr` as `nullOr str` defaulting to null
    (pinned nixpkgs `sshd.nix:325-328`), so the attribute always EXISTS, `a.addr or ""` never
    fires, and a malformed entry reached `null < "127.0.0.1"` — a throw from inside a
    trivial-builder stack trace instead of this check's own message. Both dependent legs are
    guarded by a lazy `&&`: the rendered leg below forces `extraConfig`, where upstream
    interpolates `addr` straight into a string (`sshd.nix:901`, "cannot coerce null to a
    string" — measured), so guarding only the sort was not enough.
  - the **RENDERED** `ListenAddress` lines are loopback only — a wildcard smuggled through
    `services.openssh.extraConfig` binds exactly as well as one in `listenAddresses`, and no
    option read catches it. This leg parses the MERGED `extraConfig` back into addresses and
    compares sorted. A bare `hasInfix "ListenAddress"` was NOT viable: upstream puts its own
    generated block in that same string at `mkOrder 0` (`sshd.nix:893-902`), so the grep is
    TRUE on a healthy host. The parser lowercases each line (sshd keywords are
    case-insensitive) and accepts `=` as a separator; a leading `#` is not whitespace, so
    comments do not match.
  - no explicit `port` on a listen address — nixpkgs renders `ListenAddress ::1:22`
    UNBRACKETED, OpenSSH reads that as `::0.1.0.34`, the v6 bind fails, and sshd SURVIVES
    (a failed bind is fatal only if every bind fails), so v6 loopback silently vanishes.
  - the allow-list is **four** legs, not one, because four options reach the same iptables
    accept rule. `allowedTCPPorts` is EXACTLY `[ 80 ]` — core.nix's `[ ]` MERGES with
    `hosts/nixpi.nix`'s Caddy ORIGIN port (443 omitted; TLS terminates at Cloudflare).
    `allowedTCPPortRanges` is `[ ]` (`firewall-iptables.nix:182-183`). The per-interface sets
    are read through the INTERNAL `allInterfaces` (`firewall.nix:305-311`) rather than the
    user-facing `interfaces`, because `allInterfaces` is the attrset every one of the four
    accept loops actually walks (`:165`, `:183`, `:195`, `:213`), so a future upstream route
    into those loops surfaces here as a new key instead of slipping past. And
    `trustedInterfaces` is `[ "lo" ]` — a trusted interface accepts EVERYTHING on it, no port
    list consulted (`firewall-iptables.nix:149`), and upstream sets that value itself
    (`firewall.nix:334`), so the leg pins it rather than emptiness. The check's job is to make
    WIDENING loud, not to bless the current width: a legitimate new port means editing the
    literal on purpose. Plus password / keyboard-interactive / root-login denials.
  - `distributedBuilds`, `buildMachines` and the rendered `nix.settings.builders` are three
    SEPARATE legs, because upstream says the first does not inhibit the second (`buildMachines
    != [ ]` alone renders `/etc/nix/machines`) and nulls the third only WHILE `distributedBuilds`
    is false. This is about a leaf host growing **outbound** build trust and a stray machines
    file — not about the Pi compiling, which stays owned by the PreToolUse guard's Rule 1d and
    `deploy.nix`'s `remoteBuild = false`.

  **Not nixpkgs' own `assertions`:** their only natural home is `modules/nixos/core.nix`, which
  `nixvm` and every `lib.mkNixos` consumer also import — baking "exactly one open TCP port" in
  there breaks a stranger's host, the precise leak the `template-consumer` check exists to
  prevent. This is a FLEET contract about one named host. **Not covered:** it is EVAL, not
  runtime — no `sshd -G`, and no `iptables -S` (that, not `nft list ruleset`, is the runtime
  counterpart: nixpi runs the **iptables** backend, `networking.nftables.enable = false`,
  measured); an already-flashed Pi also keeps its current generation until the next deploy.
  Four further paths are known and deliberately ungated: `networking.firewall.extraCommands`,
  the iptables backend's raw escape hatch (`firewall-iptables.nix:235`), already NON-EMPTY on
  nixpi because the nat module contributes its own teardown preamble, so there is no empty
  baseline to assert against; `extraInputRules`, which is not a path on this host at all — it
  exists only in `firewall-nftables.nix` (`:24-26`, rendered at `:179`), so flipping
  `networking.nftables.enable` moves the whole rule set to a renderer none of these legs read
  and needs NEW legs rather than an edit to these; **UDP**, ports and ranges both, since the
  failure this check exists to catch is an unauthenticated unlogged path to sshd and sshd is
  TCP; and the rest of `sshd_config` — a `Port` smuggled through `extraConfig` is harmless
  here (the binds stay loopback, the allow-list is pinned) but a `Match` block relaxing an auth
  setting is invisible. Nothing here stops the Pi compiling locally either (`max-jobs` is
  still `auto`), and the Access application itself lives in Cloudflare's API, where its
  2026-08-20 disappearance was invisible to eval then and still is.
- **`modules/nixos/desktop-vm.nix`** — opt-in `services.desktopVm.enable` (default false): a lightweight X11
  **XFCE** desktop with passwordless autologin (the `loginName` specialArg) plus QEMU/SPICE
  guest integration (`qemuGuest`, `spice-vdagentd`) for the `nixvm` sandbox.
  `hosts/nixvm.nix` enables it **only inside `virtualisation.vmVariant`**, so the desktop
  materialises for the graphical `nix run .#nixvm` / `build-vm` path — the sole way `nixvm` is
  ever booted.

### NixOS modules that are not in `modules/nixos/`

Both are in-tree capsules (`modules/features/`), and both are threaded into
`hosts/nixpi.nix` through `mkNixos` specialArgs as an already-resolved MODULE — never as a
flake, and never imported by path from the host.

- **`modules/features/cloudflared-connector/`** (an IN-TREE CAPSULE, not an input — it was
  the `nix-cloudflared-connector` flake until ADR-002 wave 3 absorbed it) — opt-in
  `local.cloudflaredConnector.enable`
  (default false); hardened `systemd.services.cloudflared-connector` running a
  **remotely-managed (token)** Cloudflare Tunnel — no `cloudflared tunnel login`, no cert.pem.
  Token read from `tokenFile` (module default `/etc/secrets/cloudflared-token`,
  operator-placed), never in git; an activation script warns (doesn't abort) if absent. Only
  `nixpi` enables it — and `nixpi` **overrides `tokenFile` to `/run/cloudflared-token`**, a
  root-only file that `local.firmwareProvisioning` populates at boot from the token
  operator-planted on the SD card's FAT `FIRMWARE` partition. This deliberately replaced
  agenix: agenix binds the token to nixpi's SSH host key, but a fresh SD flash rotates that
  key, breaking decryption and killing the tunnel — the sole remote path in.
  Reached through the flake's own `flake.modules.nixos` registry (flake-parts
  `extras/modules.nix`), threaded into `hosts/nixpi.nix` by `mkNixos` specialArgs as
  `cloudflaredConnectorModule`. Its own eval check came with it
  (`checks.aarch64-linux.cloudflared-connector-module`),
  and `checks.aarch64-linux.nixpi-firmware-names` pins the four unit/`/run` names the next SD
  flash depends on, because a rename there is invisible to `nix flake check` AND to
  `--dry-activate` on an already-provisioned card.
- **`modules/features/firmware-secrets/`** (an IN-TREE CAPSULE — it was extracted from this
  repo into the standalone MIT `nix-firmware-secrets` flake, then absorbed back by ADR-002
  wave 4) — `local.firmwareProvisioning`, a reusable `files.<name>` mechanism: each entry
  becomes a oneshot that, once `/boot/firmware` is mounted, copies an operator-planted file off
  the FAT `FIRMWARE` partition into a root-only `/run` file before its consumer starts
  (`required` fails the unit if absent; else it skips cleanly). `nixpi` uses it for BOTH the
  Cloudflare connector token AND Wi-Fi (`wpa_supplicant.conf`) — host-key-independent secrets a
  fresh SD flash needs, since agenix (which binds to the rotated host key) would lock us out.
  Planted from macOS by the `nixpi-provision`/`nixpi-flash` apps. Reached through
  `flake.modules.nixos` and threaded into `hosts/nixpi.nix` by `mkNixos` specialArgs as
  `firmwareSecretsModule`; its own eval check came with it
  (`checks.aarch64-linux.firmware-secrets-module`). **Two things did NOT come along:** the
  satellite's `apps/firmware-plant.nix` (a second, unused copy of what
  `packages/nixpi-provision.nix` already does — two copies of one procedure is two chances for
  the planted basenames to drift) and its `examples/pi-cloudflared.nix` (a stale sketch;
  `hosts/nixpi.nix` is the real example, and it is evaluated on every PR).

### Web serving on `nixpi`

Uses upstream `services.caddy.virtualHosts` directly (in `hosts/nixpi.nix`), **no wrapper
module**: one `http://<domain>` vhost per `mkNixos`'s `hostedSites` parameter, each
`file_server`ing its `root`. `hostedSites` still defaults to `[ ]` (the parameter stays generic),
but `modules/parts/hosts.nix`'s own `nixpi` call passes the real list directly
(`config.fleet.hostedSites`, `modules/parts/identity.nix`) since the private nix-personal flake
that used to supply it was retired 2026-09-15. It is **two sites** today — `snoringirl.com` and
`ismail.kattakath.com` — down from four: `dontsell.ai`'s apex moved to Vercel 2026-09-06 (its
terranix module deleted 2026-09-14) and `kattakath.com` left for GitHub Pages 2026-09-07.
`ismail.kattakath.com` is the one to be careful about: it was dropped from `hostedSites` on
2026-09-12 as collateral in an unrelated commit **while the site stayed live** (the running
generation and the cf-tunnel state both predated the drop), and was **restored 2026-09-14** —
config catching up to production, not a decision to keep it here. Moving it to GitHub Pages is
still the intent, and it is an ordered migration: the `tofu` apply goes **last**. Until then that
line is what stops a routine deploy dropping the vhost (502) or a `cf-tunnel-apply` deleting the
DNS record (NXDOMAIN) — the ≤2-ingress site-free guard catches neither, because this render has
three entries. Caddy sits **behind** the Cloudflare Tunnel (tunnel → Caddy on :80), so no
public IP/port-forward is needed and TLS terminates at Cloudflare's edge (the `http://` prefix
disables Caddy auto-HTTPS to avoid a redirect loop back through the tunnel).

## `modules/parts/` — the flake engine

**ADR-002 wave 2** moved every flake output out of `flake.nix` and into one file per concern.
`flake.nix` is now **inputs plus a single `flake-parts.lib.mkFlake` call and nothing else**; the
engine is here. These are flake-parts modules and they **may reach anywhere** in the tree — that
is the asymmetry with `modules/features/`, which may not reach out.

They are discovered by **`import-tree`**, not by a hand-written `imports = [ … ]`. One regex with
an alternation covers both trees:

```nix
(import-tree.match ".*/(parts/[^/]+|features/[^/]+/flake-module)\\.nix$").addPath ./modules
```

**The `.match` is mandatory, and one alternation is mandatory too.** `import-tree`'s DEFAULT
filter is *every* `.nix` file not under `/_` (pinned `default.nix:48`), which would feed
home-manager and NixOS modules to the flake-parts module system. And `.match` accumulates with
`and` (pinned `default.nix:234`), so chaining a second `.match` **intersects** the two and loads
nothing — hence one regex, not two calls.

| File | Owns |
|---|---|
| `identity.nix` | `loginName` / `domainName` / `fullName` / `userEmail`, threaded through `specialArgs` — the `identityArgs` that used to be `let` bindings in `flake.nix`. `options.fleet` is a **submodule with a `lazyAttrsOf raw` freeformType**, so the other ~26 fleet attrs still merge across files while `identityArgs` alone is a CLOSED four-field typed submodule: a fifth field now fails here with "option … does not exist" instead of exploding in a template consumer's build, the way `publicMcpPort` did on 2026-09-16. It constrains the DECLARATION only — a consumer's `identity` arrives through `specialArgs`, outside the module type system. Shape copied from flake-parts' own top-level `flake` option. |
| `systems.nix` | flake-parts' `systems` = the two fleet arches. **`x86_64-linux` is deliberately NOT here** — adding it would silently spawn x86 checks, formatter and apps; the devcontainer reaches it with `withSystem "x86_64-linux"`. |
| `compose.nix` | `mkDarwin` / `mkNixos` / `mkHomeManagerModule` — **not translated** to flake-parts, kept verbatim as plain Nix functions in the freeform `flake` attr (ADR-001's blast-radius objection, honoured). Also threads each capsule in as a named specialArg. Its two composition seams (`extraHomeModules`, `hostedSites`) and the nixpi deploy runbook are written up in [`private-home-modules.md`](private-home-modules.md) — the filename is historical (the private `nix-personal` flake it was named for was retired 2026-09-15); the seams and the runbook are current. |
| `hosts.nix` | `darwinConfigurations.macos`, `nixosConfigurations.{nixpi,nixvm}`. |
| `packages.nix` | `perSystem.packages` + every `apps.*`. |
| `checks.nix` | The engine's own checks, including `claude-md-budget`, `capsule-registry`, `deploy-schema`, `bedrock-gate-after-loader`, the two `determinate-daemon` halves and `nixpi-security-posture` (§ `modules/nixos/`). Its one shared helper, `mkHostContract`, reports EVERY broken leg rather than the first — that behaviour, not code reuse, is the bar for reaching for it. |
| `capsules.nix` | The capsule registry and its two internal seams — `capsuleModules` and `capsuleSources` — plus `checks.<system>.capsule-registry`. |
| `terranix.nix` | The `cf-*` / `mcp-public-*` tofu builders. |
| `devshell.nix` | `devShells` + the `git-hooks.nix` wiring. |
| `deploy.nix` | `deploy.nodes.nixpi` (deploy-rs has **no** flakeModule — grepped; this stays hand-written in the freeform `flake` attr). |
| `templates.nix` | `templates.default`. |
| `devcontainer.nix` | The image, via `withSystem "x86_64-linux"`. |
| `lib-option.nix` | The 4-line `mkOption { type = lazyAttrsOf raw; }` declarations for `flake.lib` and `flake.darwinConfigurations`, copied from flake-parts' own `nixosConfigurations.nix:11`. Without them the freeform `types.unique` default would force every seam back into ONE file — silently re-creating the monolith. |
| `touchup.nix` | What the flake does **not** export. A bare `mkFlake` also emits `legacyPackages`, `nixosModules`, `overlays` and `modules`; this repo has never exported any of them, and the decision (plus the one-line path back) is recorded there. |

## `modules/features/` — the six capsules

Seven satellite flakes were absorbed in-tree by **ADR-002** and archived at origin; **six
remain** — `vast-provision` was removed wholesale on 2026-09-12 along with the rest of the
off-fleet GPU control plane. See
[`monoflake-capsule-adr.md`](monoflake-capsule-adr.md), and **§9 of it first** — the correction
record supersedes the design where they disagree.

### The boundary is mechanical, not a convention

| Layer | Mechanism | What it catches |
|---|---|---|
| File | `ast-grep/rules/capsule-must-not-reach-out.yml` (`files: modules/features/**`, `kind: path_expression`, severity **error**) riding the existing `checks.<system>.ast-grep` gate | a `..` path literal anywhere under a capsule — **even one that stays inside it**, which is why `tart-vms`' four module files and `media-cli`'s `package-graph.nix` sit at the capsule ROOT rather than in a nested `modules/` or `lib/` |
| Registry | `checks.<system>.capsule-registry` (`modules/parts/capsules.nix`) asserts `readDir ./modules/features` equals the set `import-tree` actually loaded | a **misnamed entry file** silently dropping a whole capsule with CI green (ADR-002 §4, S3). Verified by renaming `flake-module.nix` → `flake-modules.nix`: the check fails with that message. |
| Option | `lib.evalModules` against a stub host (`darwinStubs`, in `tart-vms`' checks) | an isolation break the two above cannot see — at the cost that the stubs **rot** (ADR-002 §7.7) |

**The gate has an INWARD hole.** `files: modules/features/**` can only see a file *inside* a
capsule reaching out; it cannot see a file *outside* naming a file *inside*. That is real —
`modules/shared/home.nix` has to `callPackage` a `tart-vms` file with the **host's** pkgs — and is
why `capsuleSources` exists (below). ADR-002 §9.3.

### `flake-module.nix` is the only entry, and there are three seams out

Every capsule is entered **only** through `flake-module.nix`. From there it publishes on one of:

| Seam | Type | Used by | Why |
|---|---|---|---|
| `flake.modules.<class>.<name>` | flake-parts' own module registry (`extras/modules.nix:32-73`) | `cloudflared-connector`, `firmware-secrets` (both NixOS) | pure reuse; the `_class` stamp comes free |
| `capsuleModules.<class>.<name>` | `lazyAttrsOf raw` — a definition passed through **UNWRAPPED** (`modules/parts/capsules.nix`) | `keychain-secrets`, `media-cli`, `local-rag` (home-manager), `tart-vms` (darwin) | **measured, not stylistic.** `flake.modules`' element type is `types.deferredModule`, whose merge always wraps in `{ imports = [ … ]; }` (pinned nixpkgs `lib/types.nix`, `deferredModuleWith`), and flake-parts wraps again for any class but `generic`. For a NixOS module that is invisible. For a **home-manager** module it is not: `home.packages` is a LIST, merged in module-collection order = `buildEnv`'s `paths` order = **who wins a filename collision**. Routing `keychain-secrets` through `flake.modules` moved its four CLIs ahead of postgresql and `nix-bedrock-gate` and **changed `darwin-system`'s drvPath**, with byte-identical package derivations. |
| `capsuleSources.<capsule>.<name>` | a **path**, nothing else | `tart-vms` only (`gitlab-tart.nix`) | the inward hole above: `modules/shared/home.nix` must build it with the HOST's pkgs, and publishing the path keeps `flake-module.nix` the only thing outside the capsule that names a file inside it |

`flake.modules` is deliberately **not** re-exported as a public flake output (`touchup.nix`) —
the satellites published `nixosModules.*` to strangers; in-tree the only consumer is
`hosts/nixpi.nix`.

**Two things every capsule dropped on the way in:** its own `treefmt` block and `checks.treefmt`
(this tree has exactly one `nix fmt`), and its own `formatter` / `nixConfig`.

---

### `cloudflared-connector` (wave 3, 241 lines)

The scaffold capsule — the cleanest of the seven, absorbed first precisely because the wave had
to build the boundary machinery around it.

- **Owns:** `services.cloudflaredConnector` — a boot-time, **loginless** Cloudflare Tunnel
  connector for the *remotely-managed (token)* model upstream `services.cloudflared` does not
  support (it only drives locally-managed tunnels, wanting a credentials JSON and in-repo
  ingress). The token is read from an `EnvironmentFile`, so it never reaches argv or the
  world-readable store.
- **Seam:** `flake.modules.nixos.cloudflared-connector`. Consumed by `hosts/nixpi.nix`.
- **Checks:** `checks.aarch64-linux.cloudflared-connector-module` (carried over verbatim).
- **The wave-specific guard it forced:** `checks.aarch64-linux.nixpi-firmware-names` — a rename
  inside this capsule is invisible to `nix flake check` AND to `--dry-activate` on an
  already-provisioned card, and only bites on the **next flash (~40 min)**. It pins the four
  names against the LIVE nixpi config (`firmware-file-cloudflared-token.service`,
  `firmware-file-wifi.service`, `/run/cloudflared-token`, `/run/wpa_supplicant-firmware.conf`),
  plus the two ordering edges and the `EnvironmentFile`. 9 assertions; verified it fails readably
  when the connector unit is renamed.
- `infra/cloudflare/nixpi-tunnel.nix` is the terranix half and is **untouched** by the
  absorption: the connector is the client, the tunnel is the account-side object.

### `firmware-secrets` (wave 4, 363 lines)

- **Owns:** reflash-safe secrets for headless NixOS devices. Plant a secret on the device's FAT
  **firmware** partition from another machine; a boot-time oneshot copies it into a root-only
  `/run` file **before** the consuming service starts.
- **Why it cannot be agenix:** agenix and sops-nix decrypt at activation using the machine's
  **SSH host key**, and re-flashing an SD card **mints a new host key** — so a headless Pi whose
  only remote path is a tunnel whose token *is* one of those secrets is bricked-until-console
  after one reflash. This is the fleet's answer, and `secrets/cloudflared-token.age` is
  operator-only for exactly this reason.
- **Seam:** `flake.modules.nixos.firmware-secrets`. `module.nix` is **byte-identical** to the
  satellite's `modules/firmware-provisioning.nix` (verified with `diff` after `nix fmt`).
- **Checks:** `checks.aarch64-linux.firmware-secrets-module`, carried over verbatim but taking
  `module` as an **argument** — the capsule is entered downward from `flake-module.nix`, never
  upward from a leaf, which is the shape the ast-grep rule enforces.
- **Did NOT come along:** the satellite's `apps/firmware-plant.nix`, a 61-line macOS "cp onto the
  mounted FAT volume" helper duplicating `packages/nixpi-provision.nix` — the `nixpi-provision`
  app [`nixpi-sd-flashing-runbook.md`](nixpi-sd-flashing-runbook.md) actually tells the operator
  to run. Two copies of one procedure is two chances for the planted BASENAMES to diverge.

### `keychain-secrets` (wave 4, 1,336 lines)

- **Owns:** `local.keychainSecrets` — the `secret set/reveal/rm/ls/exec/copy/fp/bind/unbind/adopt/load`
  CLI over the macOS login Keychain, plus a home-manager loader that exports registered secrets
  into **every** shell, including the non-login bash an AI coding agent spawns for its tools.
  Nothing secret — **not even the key names** — reaches the store or git.
- **ADR-004 (2026-09-20), additive:** `local.keychainSecrets.backend.{type,project,prefix}` +
  `refsRelPath`, four new packages (`secrets-status`, `secrets-rehydrate`, `secrets-push`,
  `secrets-resolve` — `packages/secrets-backend.nix`, config read at RUNTIME so the perSystem
  packages and the module install the same drvs) and one new check
  (`keychain-secrets-backend-inert`). With `backend.type = "none"` (the default, and what
  `macos` runs today) the loader, `home.activation` and the `darwin-system` drv were measured
  byte-identical to the pre-ADR-004 tree and no CLI is installed. README § Backend.
- **Seam:** `capsuleModules.homeManager.keychain-secrets` (the raw seam; this is the capsule whose
  measurement produced it).
- **Checks:** `keychain-secrets-module` and `keychain-secrets-clis` (the satellite's four package
  checks folded into one — **building a `writeShellApplication` RUNS SHELLCHECK**, and this
  repo's darwin CI leg builds none of its packages, so dropping them would have been ADR-002
  §7.4's "highest-cost silent loss").
- **Two cross-file contracts, now GATED rather than trusted** — this is a security surface:
  - `local.keychainSecrets.loaderRelPath` is preserved **byte-identical** (name, type,
    default), because `modules/darwin/core.nix` derives `launchd.user.envVariables.BASH_ENV` from
    it **by reference** — the only thing covering a bash spawned by a GUI app or a launchd job.
    The eval check pins that default as a **LITERAL** rather than reading the option back, so the
    assertion is not tautological.
  - `checks.aarch64-darwin.bedrock-gate-after-loader` — the **first-ever** test of the
    `mkAfter 1500` / `mkOrder 1600` ordering dependency. `modules/shared/claude-bedrock-gate.nix`
    writes the same three shell-init options at 1600 and must run **after** this loader's
    `mkAfter` (= 1500), because it READS a variable the loader exports; reversed, it sees an unset
    variable, does nothing, and Claude Code silently keeps a Bedrock route it cannot reach.
    Proven to FIRE by flipping 1600 → 1400. **It lives in `modules/parts/checks.nix`, not in the
    capsule** — a capsule may not reach outside itself, and only the engine sees both halves.
- **`tests/grammar.sh`** came over verbatim (executable bit intact). It is a **live-Keychain
  functional test**, deliberately not a flake check — which is exactly why nothing else would
  have carried it.
- **`SECURITY.md` did not come as a file.** Half of it was a "report a vulnerability" pointer for
  strangers; the real half — the store is **AMBIENT**, so any process in the tree including an AI
  agent can read every exported value with `env` — is merged into
  [`secrets-and-keychain.md`](secrets-and-keychain.md) as *The threat model*, next to the agenix
  vault it is the deliberate counterpart to.

### `tart-vms` (wave 5, 3,255 lines) — the most LIVE surface

`macos` runs three Tart-VM GitHub runners and a GitLab lane off this capsule, and both runner
modules sit in `mkDarwin`'s **base list**, so every darwin composition — nix-personal's
included — evaluates them.

- **Owns:** `local.tart.githubRunners.*` (ephemeral Tart-VM-per-job runners), `local.tart.gitlabRunner`,
  `local.tart.vms.*`, `local.tart.runnerSlots` / `local.tart.runnerStateDir`, and five packages.
- **Seam:** `capsuleModules.darwin` — the RAW seam, for a reason independent of `home.packages`
  ordering: both runner modules do `imports = [ ./slots.nix ]`, and **the module system dedupes
  by PATH identity**. `deferredModule` would hand the base list two anonymous
  `{ imports = [ … ] }` wrappers instead of two deduplicable paths.
- **It imports its OWN nixpkgs** with the satellite's narrowed `allowUnfreePredicate` (exactly
  `tart` / `packer` / `tart-guest-agent`) rather than riding a blanket `allowUnfree`, so a
  **fourth** unfree package arriving via a nixpkgs bump still fails the build. The darwin modules
  keep building against the HOST's pkgs.
- **`capsuleSources.tart-vms.gitlab-tart`** — the one entry on that seam. `modules/shared/home.nix`
  `callPackage`s it with the **host's** pkgs to put five `nix-gitlab-tart-*` slot shims on `PATH`;
  a derivation from this flake's perSystem pkgs would be a different drv.
- **`darwinStubs` STAYS.** It is the OPTION layer of the capsule boundary (ADR-002 §2), not
  scaffolding — deleting it deletes the isolation test. Its rot cost is stated at the check.
- **`/Users/admin` and `/Users/tester` are CORRECT** — a Cirrus GUEST image's account and an
  `evalModules` fixture. `nix-hardcoded-home-path` is severity **error**, so it was scoped first:
  a `not` clause naming three non-operator users (`admin`, `tester`, `me`), each with its reason
  in the rule header and each proved in the rule-test's `valid` list while every real operator
  home stays in `invalid`. The `claude-code-nix` plugin's `nix-home-path-lint` hook carries the same three names.
- **Checks:** five eval checks carried verbatim, five build checks folded into one
  `tart-vms-packages`, plus a NEW `tart-vms-inert` — `compose.nix` had always ASSERTED IN PROSE
  that these modules are inert in every composition, and nothing measured it.
- **`./darwin.nix` (`local.tart.vms.*`) has no consumer today and is kept on purpose:**
  [`macvm-readd-runbook.md`](macvm-readd-runbook.md)'s step 1 *is* that module. Its re-add step is
  now a `compose.nix` line, not a re-added input.
- **Two stale `modules/…` references survive** inside `''…''` shell script bodies
  (`packages/tart-runner.nix:473`, `packages/gitlab-tart.nix:75`). Fixing them changes the script
  text → the drv → `darwin-system`, so they are **recorded** in `flake-module.nix`'s header
  rather than silently rotting.

### `media-cli` (wave 5, 4,559 lines) — the LARGEST, with the narrowest live surface

One option in `modules/shared/home.nix`, and **nothing at all** in nix-personal.

- **Owns:** `local.mediaCli` — eleven media/photo CLIs, a durable launchd work queue
  (~1,300 lines) and four Finder right-click Services. One switch turns all of it on or off:
  `local.mediaCli.enable = false` removes the CLIs, both launchd agents, the Services and the
  companion tools together.
- **Seam:** `capsuleModules.homeManager.media-cli` — the most exposed of any capsule to
  `deferredModule` reordering, since it contributes the Mac's largest single `home.packages`
  block.
- **`package-graph.nix` is ONE copy called TWICE** — by `flake-module.nix` for the checks and by
  `module.nix` for `home.packages`. That is the whole reason the file exists. It sits at the
  capsule **ROOT** rather than under `lib/`, because from `lib/` all eleven `callPackage` lines
  would have had to be `../packages/`.
- **It builds its OWN `nix-media-queue` wrapper and sets `ProgramArguments` itself.** Upstream
  home-manager's `/bin/sh -c 'wait4path … && exec'` arg0 **silently loses TCC read access** to
  the very folders the worker exists to work on
  ([`launchd-naming.md`](../.claude/rules/launchd-naming.md)) — which is why
  `checks.media-cli-module` asserts the arg0 is both `nix-*` **and** a store path, rather than
  being a tautology. *Upstream-first:* grepped the pinned home-manager `modules/launchd/`; the
  only knob is `waitForNixStore` (`default.nix:47-52`), which **drops** wait4path rather than
  moving it inside a named wrapper.
- **The launchd table at the top of `module.nix`** — `QueueDirectories` / `ProcessType` /
  `KeepAlive` / `RunAtLoad` / `StartInterval` — is carried over **verbatim**. It is the record
  that every queue mechanism here is launchd's own, which is what answers *"why hand-roll a job
  queue"* with *"we did not"*.
- **Checks:** six, including `media-cli-queue-state-machine` and `media-cli-inert` (an unset
  `local.mediaCli.enable` must define no agent, no session variable, no activation step and no
  package — the state `nixpi`/`nixvm` are in, since `home.nix` imports the capsule
  unconditionally).
- **NOT re-published, on purpose** (ADR-002 §7.3): the satellite's 11 packages and 9 apps.
  Every CLI reaches the Mac through `home.packages`; a second perSystem-pkgs copy would be eleven
  `nix flake show` rows nothing consumes. `media-cli-packages` builds all eleven so the
  shellcheck coverage the satellite's CI had is kept. One-line path back in `flake-module.nix`.

### `local-rag` (wave 6, 473 lines) — the last satellite

- **Owns:** `local.rag.ollama` + `local.rag.pgvector` — a loopback-only
  Postgres + pgvector + pgsql-http and a loopback-only Ollama, wired by bootstrap SQL into an
  in-DB `public.embed(text)` `SECURITY DEFINER` function, a `public.docs` table and an HNSW
  cosine index. Ingest and retrieval are both **plain SQL**; no API key, nothing leaves the
  machine.
- **The seam the whole wave was gated on:** `modules/shared/mcp.nix`'s
  `env.DATABASE_URI = config.local.rag.pgvector.databaseUri`. That one string is the career
  RAG's only path to the `postgres` MCP server, and `checks.local-rag-module` pins its value as a
  **LITERAL**, so a port/role/db rename fails there instead of quietly returning zero rows.
- **Layout:** the two modules sit at the capsule ROOT, not under `modules/`, so that
  `pgvector-local.nix`'s `imports = [ ./ollama-local.nix ]` stays a **sibling** path. That
  literal is load-bearing — it is how `local.rag.pgvector` single-sources
  `embedModel`/`embedDim` from `local.rag.ollama` even when a consumer imports only the
  postgres half.
- **Deliberately NO `programs.localRag.enable`.** ADR-002 §4 names a wrapping third switch as the
  two-switch regression the brief forbids; each module keeps gating its own
  `config = lib.mkIf (cfg.enable && isDarwin)`. `checks.local-rag-inert` is what makes that design
  honest.
- **No packages** — the satellite had none either; everything it installs is nixpkgs', reached
  through `home.packages` from inside the two modules. Nothing to shellcheck, so no `-packages`
  check was invented to look symmetrical.
- **Seam choice, measured both ways:** `capsuleModules.homeManager.local-rag`, even though this
  capsule measured drv-**identical** on both seams (it contributes nothing to `home.packages`
  directly, so `deferredModule`'s wrapper has nothing to reorder). Chosen for consistency with
  the other two home-manager capsules, and because order-insensitivity here is a property of
  today's contents rather than of the class.

## `packages/`

Core package set:

- **`grok.nix`** — xAI's `grok` CLI, one of the tree's pinned prebuilt vendor binaries. It replaces
  a per-user `curl … | bash` install that put a self-updating Mach-O in each account's
  `~/.grok/bin`, outside the store and outside git. The URL pattern was read out of xAI's own
  install.sh rather than guessed; xAI publishes NO checksum, so the `hash` is our SRI pin,
  cross-checked byte-for-byte against the copy their installer had already placed locally —
  a reproduction of a verified install rather than fresh trust in a URL. `dontFixup` and
  `dontStrip` are load-bearing: nixpkgs' default fixup rewrites Mach-O headers and would
  invalidate xAI's Developer ID signature. Unfree via a predicate naming ONE package, so a
  second unfree arrival fails rather than being waved through. The self-updater is
  deliberately defeated (read-only store, and the `$HOME/.grok/bin` PATH entry is gone) —
  updating is a version+hash bump. Per-user state still lives in `~/.grok`, which is what
  makes one shared binary correct rather than a conflict.
- **`antigravity-cli.nix`** — Google's `agy` CLI, pinned from the Darwin ARM64 archive named
  by the vendor's release manifest. It replaces the moving `curl -fsSL
  https://antigravity.google/cli/install.sh | bash` bootstrapper, so the binary is shared
  through `environment.systemPackages` and updates are reviewed as a version + hash bump.
- **`fal.nix`** — fal.ai as two binaries, because the vendor ships two different things:
  `fal` (their own CLI — a serverless runtime, `fal run`/`fal deploy`) and `fal-gen` (ours, a
  thin wrapper over `fal-client`, since the vendor ships NO inference CLI). Both are ephemeral
  `uv run --with` environments, the same shape as the media-cli capsule's `fidelity-enhance`,
  because none of fal's dependency tree is in nixpkgs. Reads `FAL_KEY` from the login Keychain
  and never prints it. Rejected on the way here: `buildPythonApplication` (hand-packaging a
  serverless runtime's whole tree) and the registry's community fal MCP servers (all
  single-source, confidence 0.40, no update date — not enough for a long-running process
  holding an API key). **This is CLOUD inference**, unlike the rest of the media stack, which
  runs against the local ollama daemon.
- **`devcontainer-image.nix`** — MULTI-ARCH devcontainer OCI image (arm64+amd64,
  `dockerTools.streamLayeredImage`), published to GHCR as a manifest list; arch-parameterized
  loader path inside. It is a **CI/Codespaces artifact, not a local-Mac path**: the `vscode`
  user is pinned to uid/gid 1000 (`updateRemoteUserUID: false`, because fakeNss's
  `/etc/passwd` is read-only), so on a Linux host every file it writes into a mounted workspace
  is owned by uid 1000 — not the Mac account (`ismail` 501).
- **`nixpi-provision.nix`** — macOS-only: the four
  `nixpi-flash`/`nixpi-provision`/`nixpi-wifi-creds`/`nixpi-vault-token`
  `writeShellApplication` flake apps that flash the SD card and plant the token+Wi-Fi onto its
  FIRMWARE partition — the executable companion to the `modules/features/firmware-secrets/`
  capsule's `local.firmwareProvisioning`.
- `key-recovery.nix` — **removed 2026-09-15**, with its `key-backup`/`key-recover` apps and
  the iCloud kit. Early-days scaffolding: key custody is the operator's choice, and this
  fleet's posture is that a lost machine's keypair stays lost, because every agenix secret is
  re-issuable by the vendor that minted it. What it did now lives in `bootstrap.sh` (clone +
  the `loginName` guard + activate) and [`new-mac-runbook.md`](new-mac-runbook.md) (the
  rotate-don't-transport checklist).
- **`activate.nix`** — macOS-only: `activate`, a `darwin-rebuild switch` that re-execs under
  `sudo -H` (Touch ID) instead of dying with "system activation must now be run as root", and
  names the flake dir + `branch@rev` (with `(DIRTY)`) before elevating. Needs no `--flake` or
  `#attr` because `modules/parts/hosts.nix` plants `/etc/nix-darwin/flake.nix`.
- **`spotlight-launchers.nix`** — macOS-only: from-scratch `.app` bundle generator (original
  in-Nix SVG/icns icons via librsvg+libicns) giving the Android emulator a
  Spotlight-visible, focus-or-launch identity; consumed by `modules/shared/home.nix`'s
  `home.file."Applications/*.app"`.
- `macvm-tart.nix` — removed 2026-09-05 with the `macvm` guest; the generic Tart machinery
  it wrapped lives on in the in-tree `modules/features/tart-vms/` capsule (absorbed from
  `nix-tart-vms` by ADR-002 wave 5),
  and the re-add path is [`macvm-readd-runbook.md`](macvm-readd-runbook.md).

The no-Nix stage-1 `bootstrap.sh` (the `curl … | bash` entrypoint) lives at the **repo root** —
it is shellchecked as the `bootstrap-lint` derivation (`checks.<system>.bootstrap-lint`), so
the `curl … | bash` bytes are gated exactly like every in-flake script.

Smaller, single-purpose CLIs:

- **`android-phone.nix`** — macOS-only: deterministic wired/wireless ADB operator
  (`list|pair|connect|disconnect|unpair|tcpip|wireless|mirror|doctor`) plus scrcpy mirroring
  for a PHYSICAL Android device; hardens around two live-reproduced adb bugs, an mDNS-cache
  staleness and duplicate-transport device listings. Its operator knowledge is also a GLOBAL
  skill — `android-phone` in the pinned
  [`kattakath/ai`](https://github.com/kattakath/ai).
- **The media packages are NOT here — they are in the `media-cli` capsule.**
  `media-quick-actions.nix`, `media-queue.nix`, `media-toolkit.nix`, `media-describe.nix`,
  `media.nix`, `media-fix.nix`, `media-fix-extension.nix`, `media-extract-audio.nix` and
  `media-transcode.nix` — plus the two media-*adjacent* tools `obs-fb-setup.nix` and
  `fidelity-enhance.nix` — left for `kattakath/nix-media-cli` on 2026-09-05 (which is where
  the `photo-describe` → `media-describe` renaming happened) and came back on 2026-09-12 as
  `modules/features/media-cli/packages/`, with their reasoning intact in their own headers.
  This repo consumes them as `local.mediaCli` (see § `modules/shared/` above). There is no
  `nix run .#media-describe`: the capsule publishes **no** packages or apps, on purpose — the
  CLIs reach the Mac through `home.packages` and a second perSystem-pkgs copy would be eleven
  `nix flake show` rows nothing consumes. The one-line path back is in the capsule's
  `flake-module.nix` header.

  The two adjacent tools are **opt-in** in that module
  (`fidelityEnhance.enable`, `obsFacebookSetup.enable`) and deliberately stay OUT of the
  `media-toolkit` bundle: that bundle is what the queue worker and the Finder Services put
  on their `PATH`, so every member becomes a runtime dependency of the queue, and a
  uv/Python environment plus a Keychain read have no business there.
- **The four Keychain CLIs are not here either — and never were.** `secret`, `set-secret`,
  `remove-secret` and `pb-conceal` live in **`modules/features/keychain-secrets/packages/`**,
  inside the capsule whose home-manager module installs them, because a capsule owns its own
  derivations (ADR-002 § anatomy). The flake still exports the first three on darwin
  (`nix run .#secret`), with the same `meta.description` strings as before — those are
  declared once in `modules/parts/packages.nix`'s `apps`, which points at
  `config.packages.<name>`. `pb-conceal` is installed by the module but deliberately not
  published.
- **`jobspy.nix`** — a reproducible `uv`-ephemeral wrapper CLI around the `python-jobspy`
  library for scraping job boards.
- **`jsonresume.nix`** — dual-engine `jsonresume <download|print|validate|markdown|text>`
  wrapper (`resumed` for PDF/validate, `resume-cli` where `resumed` falls short); see the
  `jsonresume-tailor` skill.
- **`mermaid-ascii.nix`** — packages `AlexanderGrooff/mermaid-ascii`, not in nixpkgs, for the
  diagrams-as-ASCII convention.
- **`claude-otel-doctor.nix`** — health check for the `local.claudeOtel` collector (launchd
  agent, OTLP port, events-file freshness). See
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`resend-cli.nix`** — the official Resend CLI, not yet in nixpkgs so `npx`-wrapped and
  version-pinned same as `mcp-wordpress`/`telegram-mcp`; injects `RESEND_API_KEY` from the
  login Keychain at run time — wired only via `home.packages`, no matching flake app. The
  lookup is by Keychain **service** `resend.com:api`, not by the env name, so set it with
  `pbpaste | secret set --env RESEND_API_KEY resend.com:api`.
- **`design-tokens/`** / **`email-signature/`** — small self-contained build-script-backed
  packages for their respective assets.

## Userscripts — REMOVED from the fleet entirely (2026-09-14, commit `535f1ef`)

**The fleet declares zero userscripts, and gates none.** That commit deleted the
`kattakath-userscripts` input, every `local.ungoogledChromium.userScripts.scripts` entry and
`checks.<system>.userscripts`; nix-personal (`c013aa5`) deleted `modules/userscripts.nix`, its
own `gitlab:ismailkattakath/userscripts` input and both `checks.userscripts-lint` /
`checks.userscripts-meta` the same day. The scripts are **published to Greasy Fork** (Sleazy
Fork for adult-site scripts) instead — the last one out, `google-photos-icon-nav`, is
`greasyfork.org/scripts/595764`.

**Why publication beat declaration, stated as the trade it is.** A fork-installed copy carries
`@updateURL` and **self-updates**; a Nix-materialised `file://` copy structurally cannot, because
the old pipeline *banned* `@downloadURL`/`@updateURL`/`@installURL` outright — pointed at this
repo they would have let a push to `main` mutate an installed script with no activation. So every
change cost a `@version` bump, a `flake update`, an `activate` and a manual install click, and the
end state was still a script that never updated itself. Publishing inverts that: one upload, and
every install everywhere follows. What was given up is the declarative guarantee — a fresh Mac no
longer ends up with the scripts installed, and the linter no longer runs in this repo's CI (it
still lives in the `page-lab` plugin, and Greasy Fork enforces its own rules at upload).

**The option is deliberately KEPT, with zero scripts.**
`local.ungoogledChromium.userScripts` (`enable` + the `attrsOf (nullOr path)` `scripts` attrset)
stays in [`modules/shared/chromium.nix`](../modules/shared/chromium.nix) — see § `chromium.nix`
above for the materialisation and the reason Chromium allows nothing more declarative.
Violentmonkey is still sideloaded by `enable`; `scripts` is simply empty, and
`xdg.dataFile` is gated on non-empty so an empty attrset writes nothing. It costs nothing and
keeps the seam available if a script ever has to be fleet-pinned again (a private one, say, that
must not go to a public fork).

**The authoring METHOD is unchanged and lives in the plugin.** The portable
[`page-lab` plugin](https://github.com/kattakath/ai/tree/main/plugins/page-lab)
owns the probes, the patterns, the Greasy Fork rulebook and the metadata linter; it **measures
the live page** before it writes a selector, routing on the diff between the state the site
already gives you and the state you want:

| Diff verdict | What it means | What to write |
|---|---|---|
| **DOM-DIFFERS** | a selector/attribute *can* force it | set the attribute or class the site itself sets |
| **DOM-IDENTICAL** | the switch is a **pure CSS media query** — no selector can force it | lift that condition's rules and re-serve them in a **band** |
| **STATE-B-UNREACHABLE** | the state does not exist; you are constructing UI | every invented selector carries its own measured line in the file's WHY block |

The project skill [`userscript-author`](../.claude/skills/userscript-author/SKILL.md) is now
only the *delivery* half — publish, then install — and no longer touches Nix.

**The worked example, kept because the lesson outlives the file.**
`google-photos-icon-nav` makes `photos.google.com` render **its own** narrow-viewport icon rail
at every window width, handing the reclaimed width to the photo grid. *The measurement was the
design:* the DOM is *identical* either side of the responsive breakpoint — same tags, same
classes, same attributes — so the switch is a **pure CSS media query** and nothing a selector can
force. The script therefore lifts Google's own `@media` blocks out of their wrapper and replays
them unconditionally, selected by `conditionText` within an **800–1200px band** (never a
hardcoded pixel; all blocks sharing a width are accumulated, widest wins) and re-applied from a
`document.head` **`childList`** MutationObserver — not from history hooks, and never with
`subtree`, which over this ~1.8 MB DOM would fire thousands of times a scroll. Consequence: the
file contains **not one Google class name**, so the JSCompiler churn (`RSjvib`, `JBVD2d`, …) that
breaks every hand-written Photos userscript cannot break it; an unreadable cross-origin sheet
degrades it to a **no-op**, which is the correct failure. Two page properties still shape it: the
grid is **JS-virtualised** — tile geometry *and* thumbnail request sizes derive from the measured
pane width — so the CSS must be followed by a synthetic `resize`, coalesced in one `rAF`; and only
the pane **wrapper** may ever be shifted, because it is the `position:absolute` containing block
for the main pane, which sits at `left:0` inside it, so moving both would double the offset.

## `infra/` — terranix (Nix → OpenTofu/Terraform JSON)

**Five stacks, and the split is deliberate: a stack is a blast radius, not a category.**

| Stack | State | Breaking it takes down |
|---|---|---|
| `cf-tunnel` | GCS `cf-tunnel/` | the Pi |
| `mcp-public` | GCS `mcp-public/` | the MCP portal |
| `cf-zones` | GCS `cf-zones/` | **mail** |
| `gcp-budget` | GCS `gcp-budget/` | the spend alert |
| `gcp-foundation` | **local** | the bucket the other four live in |

State is the shared, versioned bucket `kattakath-tofu-state`, **encrypted** with a passphrase
read from the login Keychain at run time via `TF_ENCRYPTION` (ADR-005 phase 1 —
[`iac-coverage-adr.md`](iac-coverage-adr.md)). Two of these states hold secrets in plaintext
inside the payload, which is why encryption is not optional. `gcp-foundation` keeps local state
because it *declares* that bucket.

### `infra/cloudflare/zones.nix` + `infra/cloudflare/kattakath-dns.nix`

`kattakath.com`'s 22 DNS records — the module renders, the sibling file is the data. Only this
zone is declared, and the line is drawn by **ownership, not secrecy**: DNS is a public query, so
publishing the operator's own zone discloses nothing `dig` does not, while the other six zones
belong to businesses that are not only his.

Records owned by another stack are deliberately absent (`nixpi`, `upstream`, and `mcp`, which
Cloudflare creates with the portal). Importing one twice is how a plan grows a destroy.

Its guard is shaped for its own failure mode — a **record-count floor** — because the way this
stack hurts you is a shrunken render silently deleting mail, not a bad tunnel. Applied via
`cf-zones-apply`; `cf-zones-plan` is read-only. There is no `cf-zones-destroy`.

### `infra/gcp/foundation.nix`

Enabled APIs, the automation service account, its IAM bindings, and the OpenTofu state bucket.

**Runs as the OPERATOR, not the service account it declares.** Running it as that account would
need `serviceUsageAdmin` + `iam.serviceAccountAdmin` + `projectIamAdmin` — the power to re-grant
itself anything. The privileged bootstrap stays with the human; the narrow stacks use the
least-privileged identity it creates, by **impersonation**, with no key file anywhere.

It also declares `ws-domain-admin`, the Workspace-facing account — the account only. Its
authority would live in the Admin console, which no provider reaches:
[`workspace-runbook.md`](workspace-runbook.md).

### `infra/gcp/budget.nix`

A **5 CAD** spend budget. **An alert, not a cap** — Google offers no hard spending limit on a
billing account, and the currency must match the account's own or the API rejects it as a bare
`400`. Applied via `gcp-budget-apply`.

### `infra/cloudflare/nixpi-tunnel.nix`

Declares `nixpi`'s **remotely-managed** Cloudflare Tunnel itself:

- a `cloudflare_zero_trust_tunnel_cloudflared` (`config_src = "cloudflare"`),
- its ingress (`cloudflare_zero_trust_tunnel_cloudflared_config`: SSH → `ssh://localhost:22`,
  one rule per `hostedSites` entry → the local Caddy at `http://localhost:80`, plus the
  mandatory catch-all `http_status:404`),
- one proxied `cloudflare_dns_record` CNAME per site → `<tunnel-id>.cfargotunnel.com`,
- the connector **token** surfaced as a sensitive `output` (via the
  `cloudflare_zero_trust_tunnel_cloudflared_token` data source).

A pure function of its `hostedSites`/`domainName`/`accountId`/`zoneId` module args (same
shape/default as `mkNixos`); `cf-tunnel-apply`/`cf-tunnel-destroy` pass the fleet's real
`hostedSites` (`config.fleet.hostedSites`), while their `*-destroy` counterparts deliberately
keep the `[ ]` default so tearing the real stack down still needs the explicit
`CF_TUNNEL_ALLOW_SITE_FREE=1` override (`modules/parts/terranix.nix`). Applied/destroyed via the
`cf-tunnel-apply`/`cf-tunnel-destroy`
flake apps (an API credential must be exported first — never in Nix); `cf-tunnel-apply` prints
the token to stdout to be stored via `nix run .#nixpi-vault-token` into
`secrets/cloudflared-token.age`, never written to git/store in plaintext.

### `infra/cloudflare/mcp-public.nix`

The Cloudflare half of the **published MCP gateway** — the other half is
`local.mcpGateway.public` in `modules/shared/mcp.nix`, which puts the opt-in subset of
servers on a SECOND `mcp-proxy` at `127.0.0.1:8097`. Built and live since 2026-09-12; the
design note is [`docs/mcp-public-exposure-design.md`](mcp-public-exposure-design.md).

Renders, from ONE list: a `cloudflared` tunnel + connector for the Mac, ingress to `:8097`, the
proxied CNAME, **one** Access application over the origin hostname, **one** `non_identity`
service-token policy, one portal registration per published server, one `mcp`-type Access
application per server (portal visibility), and the portal's own `mcp_portal` application
carrying the DCR allowlist of which clients may register.

**Exactly two hostnames, and they do not grow per server.** `mcp.<domain>` is the portal that
clients talk to — the only address ever handed out. `upstream.<domain>` is the origin, dialled
only by the portal, with a service token; a browser gets 403 because the policy is
`non_identity` and there is no login path. Remote Workers are published as Cloudflare Worker
**routes** under that same origin (`/servers/<name>/*`), matched at the edge before the tunnel
is consulted, so a Worker and a laptop-local process share one hostname and one `aud`.

Three objects are required to publish one server, and missing any of them fails **silently**: the
registration, its attachment to the portal, and its `mcp`-type Access application. A registration
can sit at `status = "ready"` with its tools discovered and still be invisible to every client —
and testing at the origin cannot detect it, because the origin answers `200` throughout. Verify a
publish through `mcp.<domain>`.

Applied via `mcp-public-apply` / `mcp-public-destroy`, with `mcp-public-token` printing **only**
the raw connector token for piping into `secret set`. State lives in
`$XDG_STATE_HOME/nix-config-mcp-public` (0700/0600 — it holds the connector token and the Access
service-token secret in plaintext). `mcp-public-apply` passes the fleet's real
`publicMcpServers` (`config.fleet.publicMcpServers`); `mcp-public-destroy` deliberately keeps
the `[ ]` default so tearing down the real registrations still needs the explicit
`MCP_PUBLIC_ALLOW_EMPTY=1` override — `mkMcpPublicTofu` refuses a render that publishes 0
servers against state that holds more than 0.

## Claude Code surface

MCP servers have their own doc: [`mcp-gateway.md`](mcp-gateway.md).

### `claude/` + `qwen/` — the GLOBAL agent context (not `.claude/`)

Two top-level directories that are easy to mistake for the project-scoped `.claude/` tree.
They hold the **all-projects, machine-wide** context this repo installs on `macos`:

- **`claude/CLAUDE.md`** → `~/.claude/CLAUDE.md`, via `programs.claude-code.context` in
  `modules/shared/home.nix`. That option **replaced a hand-written `home.file` shim** — the
  upstream-first outcome, not a workaround. Holds the user-level rules that apply in every
  session on this machine (AskUserQuestion-for-decisions, reuse-over-rebuild, diagrams as
  rendered ASCII, secret-value redaction, git authorship). The repo-root `CLAUDE.md` is
  **project**-scoped and layers on top of it.
- **`claude/output-styles/`, `claude/agents/`, `claude/commands/`, `claude/rules/`** — the
  **Brain Signals** kit, wired by `modules/shared/claude-brain.nix` (not `home.nix`) through
  `programs.claude-code.{outputStyles,agents,commands,rules}`: the BLUF-first layered output
  style, its companion calibration rule, the `cartographer` read-only architecture subagent,
  and `/task` (goal-locked execution). Its seven `/explain`-family skills live one level up in
  top-level `skills/` — see § Global skills. MOVED HERE from the private nix-personal flake
  2026-09-12: `claude/CLAUDE.md` already carried the same ADHD/dyslexia answer-shape rule in
  prose, so the rule and the mechanism that satisfies it now live together and cannot drift.
  Every option it writes is `attrsOf`-merging, so a private layer or a fork ADDS entries rather
  than replacing the set; the only two scalars (`settings.outputStyle`,
  `settings.alwaysThinkingEnabled`) are `lib.mkDefault`, so a plain assignment downstream wins.
  Two things it must never do, both of which would destroy that seam for everyone: route extra
  global prose through `context` (already defined as a PATH in `home.nix` — a second path
  definition is a hard eval error, not a merge; use another `rules.<name>`), or reach for the
  `rulesDir`/`agentsDir`/`commandsDir` forms (upstream asserts `rules` XOR `rulesDir`).
- **`qwen/QWEN.md`** → `~/.qwen/QWEN.md` (`home.file`, darwin-only — there is no `programs.qwen`
  module to reach for). The `qwen` counterpart of the same idea, deliberately kept short.

Both are source-path literals (`../../claude/CLAUDE.md`), so they are repo-relative and
content-hashed into the store — see `CLAUDE.md` § Code Style on the two path axes.

### `.claude/commands/`

| Command | What it does |
|---|---|
| `/eval` | stage + `nix flake check` |
| `/hygiene` | LEAN/DRY audit→fix→gate via skill `nix-hygiene` |
| `/update-input` | bump one flake input + commit the lock |
| `/superhook-review` | triage the hook-supervisor log |
| `/pretooluse-review` | triage `Bash`/`Write\|Edit` gate REJECTIONS from the harness's own OTel `tool_decision` stream (`decision`/`source`/`hook_name`), since prompt-type hooks keep no log of their own |
| `/remember-nix` | capture into the harness's native per-project memory store (outside the repo) |
| `/gmail-account` | add/authenticate/remove a Gmail MCP multi-account, see [`gmail-mcp-multi-account-runbook.md`](gmail-mcp-multi-account-runbook.md) |
| `/routing-review` | triage Claude Code's own OTel tool-decision log for deterministic-routing hardening candidates, see [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md) |
| `/mcp-scout` | discover → vet → DECLARATIVELY adopt an MCP server into the gateway via skill `mcp-scout`; imperative installer CLIs / config-writing install tools are never used |
| `/userscript` | measure → replay → **publish** a Violentmonkey userscript, via the `page-lab` plugin's method skill + the project skill `userscript-author` (delivery only since 2026-09-14 — nothing is declared or gated in Nix); **no selector ships that was not dumped from the live page**, and `@require`/`@resource` CDN deps are never used |
| `/fleet-doctor` | fleet-wide consistency sweep (branches/worktrees/PRs/CI/cross-repo pins/GC/host re-activation) across every repo in `.claude/skills/fleet-doctor/fleet-repos.txt`, via skill `fleet-doctor`; composes `nix-hygiene`, `git-purity.md`, `pr-title.md` |

### `.claude/rules/` — always applied

- [`git-purity.md`](../.claude/rules/git-purity.md) — stage `.nix` files before eval.
- [`pr-title.md`](../.claude/rules/pr-title.md) — a PR title is the comma-separated list of the
  components the change touches (first-level `nix flake show` output category for flake outputs,
  or a top-level dot-folder with its dot stripped). Also states the default shape: **one PR per
  change, branched off `main`** — a single ~10 min CI gate per PR keeps them independent (the
  old "one open PR per working session" consolidation policy was retired 2026-08-30; the merge
  queue that later justified it was itself removed 2026-09-22).
- [`launchd-naming.md`](../.claude/rules/launchd-naming.md) — every launchd unit this repo
  authors must expose a `nix-<kebab>` `arg0` basename (never a bare `sh`/`python3`); documents
  the known upstream `/bin/sh` exceptions (`org.nixos.activate-system`,
  `org.nixos.activate-agenix`, `systems.determinate.nix-installer.nix-hook`) that are NOT ours
  and must not be renamed.

### `.claude/hooks/`

Every hook below is **project-scoped** (`.claude/settings.json`): it guards sessions rooted in
this repo only. Two wider tiers carry the fleet-wide floor: user-scope
`modules/shared/claude-guardrails.nix` (§ `modules/shared/`) and, above it on `macos`,
root-owned managed scope in `modules/darwin/claude-managed-settings.nix` (§ `modules/darwin/`).

- **`stop-gate.js`** — Stop gate: blocks until configs evaluate clean.
- **`pretooluse-bash-guard.js`** — `PreToolUse:Bash`: deterministic port of the
  Cloudflare-API-call / Cloudflare-docs / desktop-commander-nudge / approved-CLI policy that
  used to live as a `type: "prompt"` LLM-judged hook; see the file header for the 2026-08-19
  incident that motivated the switch. Also carries **Rule 1c** (a `secret reveal` /
  `security …-w` that would print a secret VALUE into the transcript) and **Rule 1d** (any shape
  that BUILDS on nixpi — `--build-host <pi>`, `deploy --remote-build`, `ssh <pi> nix build`,
  `--builders ssh://<pi>`; the `--target-host` form is deliberately allowed, since it builds
  here and only activates there). Rule 1b — which blocked `deploy` and public-`#macos`
  activation while a private layer existed — was RETIRED 2026-09-15 with that layer.
- **`.claude/hooks/tests/*.sh`** — the guard's case suites (`rule1c-secret-egress.sh`,
  `rule1d-no-build-on-nixpi.sh`), **gated by `claude-config-lint.yml`**. Each asserts BOTH
  halves — the shapes that must block and the shapes that must stay approved — and that the
  hook does not throw. That last assertion is the load-bearing one: `superhook` and the
  script's own `catch` both fail OPEN, so a crash silently disarms every rule at once. Measured
  2026-09-15: retiring Rule 1b removed its constants but left the code referencing them, and
  the guard threw `ReferenceError` on every Bash call — approving everything, including the
  secret-egress and Cloudflare blocks — until these suites were wired into CI. Cases live in a
  FILE rather than an argv because they are execution-shaped by construction and would
  otherwise trip the very rule under test.
- Both are wrapped by **`superhook`** (crash-safety + loop-breaking + logging — the sole
  supervisor for command-type decision hooks). It structurally CANNOT wrap `type: "prompt"`
  hooks, which is why the remaining `Write|Edit` secret-detection gate in
  `.claude/settings.json` stays unsupervised prompt-based — that one is a genuine semantic
  judgment call, unlike the Bash gate's mostly-syntactic rules.
- **`superhook-digest`** — SessionStart digest of supervisor findings. Both it and the
  wrapper are PATH packages built from the pinned `kattakath-ai` input
  (`packages/superhook.nix`); they are no longer files in `.claude/hooks/`.
- **`routing-review-digest.js`** — SessionStart nudge for unreviewed
  `user_temporary`/`user_permanent` Claude Code routing decisions; mirrors
  `superhook-digest` exactly, threshold-gated, see
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`fleet-doctor-digest.js`** — SessionStart nudge when `/fleet-doctor` hasn't run in a while;
  reads only a local timestamp, no network/git calls, so it stays fast on every session start.
- **`autostage-nix`** — PostToolUse git-purity net. EXTRACTED 2026-09-12 to the
  [`claude-code-nix`](https://github.com/kattakath/ai/tree/main/plugins/claude-code-nix) plugin; it arrives as a
  plugin hook, which is why `.claude/settings.json` no longer lists it (keeping both would
  fire it twice).
- **`nix-home-path-lint`** — same plugin, same extraction. PostToolUse, `.nix` only: flags a hardcoded
  `/Users/<name>/`/`/home/<name>/` runtime-path VALUE per the "Paths — two axes" convention —
  advisory, not a hard gate.

Decoder for what these hooks print: [`claude-hook-messages.md`](claude-hook-messages.md).

### `.claude/skills/` — project skills

Active only when working in this repo: `nix-hygiene`, `nixpi-firmware-provision`,
`jsonresume-tailor`, `gmail-mcp-accounts`,
`mcp-scout`, `userscript-author` (the FLEET half only — how a script reaches this Mac now that
nothing is declared in Nix; the method lives in the `page-lab` plugin — see § Userscripts),
`fleet-doctor` (its own `fleet-repos.txt` manifest lists every repo in scope — add
a line there when a new flake is extracted from this repo, nothing else needs to change).
`skills-lock.json` (the `npx skills` CLI lockfile) pins any CLI-vendored ones (currently none —
prefer the flake path below).

### Global skills

Placed at `~/.claude/skills/<name>/` declaratively by `programs.claude-code.skills`
(`modules/shared/home.nix`, darwin-gated) on `darwin-rebuild switch`. Most are sourced from
PINNED `flake = false` inputs (`agent-skills-vercel` = vercel-labs/skills → `find-skills`;
`agent-skills-anthropic` = anthropics/claude-code → the plugin-dev + hookify authoring skills),
**NOT vendored**; `nix flake update` bumps them.

**Since 2026-09-12 the operator's own skills are on that same rail.** `rag`,
`android-phone` and `nix-dev-toolkit` were extracted out of this tree, and since
2026-09-14 live beside the plugins in
[`github:kattakath/ai`](https://github.com/kattakath/ai), pinned as `kattakath-ai`, so the
only difference between "someone else's skill" and "mine" is now who can push to the repo
([`agent-resource-externalization.md`](agent-resource-externalization.md)):

- **`rag`** — local RAG over the pgvector store: how to ingest and query via the `postgres`
  MCP server and the in-DB `embed()` function (the local-rag capsule's
  `local.rag.pgvector` + `local.rag.ollama`).
- **`capability-broker`** — the "have → rank → find → vet → adopt" protocol for any goal
  that needs a capability the session may lack. Inventory first (skills, deferred MCP tools,
  `claude mcp list`, plugins, connectors, CLIs), lightest capability wins, trust tiers gate
  what may happen unattended, and adoption goes through the harness: a new MCP server is a
  vetted record handed to `mcp-scout` in this repo, never a `claude mcp add` (which the
  `claude-guardrails.nix` floor denies anyway). Global because the need shows up in any repo.
- **`android-phone`** — operator knowledge for `packages/android-phone.nix`, global so ADB
  sessions launched from ANY directory know the wrapper's command surface and adb footguns,
  not just sessions rooted in this repo.
- **`nix-dev-toolkit`** — how to make *another* repo self-sufficient with Nix: a working
  `flake.nix` template + `.envrc` (`assets/`), the env-catalogue pattern, a project-local
  Postgres+pgvector stack, and `nix run .#<verb>` lifecycle apps (`references/`). Global
  precisely because the point is to apply it to a repo that does **not** have it yet — its
  `stack-up`/`deploy-prod`/`env-doctor` app names are the template's, **not** flake apps of
  this repo. Carries the Nix/Postgres/Prisma traps (`withPackages` union prefix, socket port,
  the macOS socket-length cap).
- **`harvest`** — the end-of-task half of the loop `capability-broker` starts: gate on worth
  (repeats, hard-won, not already covered), choose skill/subagent/workflow/plugin — or memory
  or project config when it is not an artifact — strip secrets and machine paths, then land it
  as a `kattakath/ai` PR followed by a pin bump here. It mechanises § "Adding to an extracted
  repo" in [`agent-resource-externalization.md`](agent-resource-externalization.md).

**One tree stays vendored, deliberately** — the top-level `skills/` directory:

- **`skills/{explain,compare,map,zoom,why,tldr,diagram}`** — the Brain Signals `/explain`
  family: seven one-file skills that encode the same answer shape as the output style at
  command granularity, which is why they are wired from `modules/shared/claude-brain.nix`
  rather than `home.nix`'s big skills block — and why they did **not** follow the other three
  out. They are one kit with that output style; splitting them across two repos would let the
  two halves drift with nothing to catch it. Declared as RAW path literals, not `"${…}"`
  strings: upstream branches on that (its `mkSkillEntry`) — a real path becomes a plain
  recursive `home.file` entry, a path-like string gets an extra `runCommandLocal` symlink farm.

### The operator's marketplace (EXTRACTED 2026-09-12)

The operator's OWN Claude Code plugin marketplace is
[`github:kattakath/ai`](https://github.com/kattakath/ai) — **not a tree in this repo** since 2026-09-12
([`agent-resource-externalization.md`](agent-resource-externalization.md)). It is pinned as
the `kattakath-ai` input and is the third marketplace alongside `xai-grok-build`
(also a pinned input) and `claude-plugins-official` (HTTPS).

That repo's `.claude-plugin/marketplace.json` lists its plugins with `./plugins/<name>`
relative sources — the shape every owner-operated marketplace on GitHub uses, measured;
external `{{source:github,…,sha}}` entries are what *catalogs* need, and this is not one.
`modules/shared/home.nix` declares it as the `kattakath` entry of
`local.claudePlugins.marketplaces` with `source = "${{kattakath-ai}}"` — an input's
**store path**, which carries none of the relative-literal trap the old `"${{../../plugins}}"`
form did, because a store path is absolute and means the same thing from any file in any
flake. `modules/shared/claude-plugins.nix` registers it and installs the derived
`<plugin>@kattakath` ids through the one `home.activation.claudeCodePlugins` script every
marketplace shares.

`repin` still defaults true (the source starts with `/`) and is still load-bearing: the store
path moves on every content bump and `plugin install` COPIES into `~/.claude/plugins/cache`,
so without the re-pin a bump would serve a previous generation's content forever.

Two plugins:

- **`llmstxt`** — `llms.txt` authoring skill + `/llmstxt` command + a stdlib-only spec
  linter; see the plugin's own `README.md` in [`kattakath/ai`](https://github.com/kattakath/ai).
- **`page-lab`** — userscript authoring AND live-page diagnosis in one unit: the
  measure-before-you-select method, four browser probes, the pre-vetted code patterns, the
  Greasy Fork rulebook, the GM_* portability matrix, a two-way element **picker**, CDP
  diagnosis (performance / network / console), the `/userscript` + `/devtools` + `/pick`
  commands, and `scripts/userscript-meta-lint.sh`. That linter used to be run by
  `checks.<system>.userscripts` here and by nix-personal's twin gate; **both gates went with the
  scripts on 2026-09-14** (§ Userscripts), so the rulebook now has exactly one consumer — the
  plugin's own users — plus Greasy Fork's own checks at upload.
  **Merged 2026-09-07 from `userscript-author` + `chrome-devtools`.** They were split on
  2026-09-06 and cross-referenced, which held only while neither needed the other mid-motion.
  The verb that broke it is **pick**: the operator points at an element, the agent measures
  that exact node, reads its cascade, prototypes the override live, dates it in the `WHY`
  block, lints it, and proves it after install — a motion that crossed the boundary four times
  and needed a seam FILE to narrate the crossing. The cost, stated plainly: the diagnosis half
  is no longer adoptable on its own.
  Carries a `devtools-doctor.sh` preflight, a `page-route.sh` front door that probes the five
  routes (raw CDP / chrome-devtools-mcp / claude-in-chrome / Kapture / operator-paste), and a
  **measured** fact table (`references/facts.md`) where every falsifiable claim has an ID, a
  date and a re-measure recipe — because `chrome-devtools-mcp@1.8.0` exposes **29** of the ~57
  tools its generated docs describe (those are written from `main`), so the entire Extensions
  group and 12 of 13 Memory tools do not exist yet. The MCP server itself is opt-in in
  `modules/shared/mcp.nix` (`local.mcpGateway.chromeDevtools.enable`), in ATTACH mode
  against **Chromium** (it was Opera Air until 2026-09-21, when Opera was removed from
  the Mac); read that option's warning before enabling it. The attach flag is
  **chosen at spawn time** by the `nix-mcp-chrome-devtools` wrapper, because measured
  2026-09-07 no single upstream flag works in both modes a browser can be in: one put into
  debugging from `chrome://inspect/#remote-debugging` 404s every `/json/*` path, so
  `--browser-url` cannot attach; one started with `--remote-debugging-port` serves `/json/*`
  but leaves a **stale** `DevToolsActivePort` whose WebSocket UUID is dead, so `--autoConnect`
  cannot. The wrapper probes `/json/version` first — authoritative when it answers, since it
  carries the live `webSocketDebuggerUrl` — and falls back to the file only when nothing
  answers, which is precisely when the file is fresh. Hence **both** a `port` (probe hint) and
  a `userDataDir` option.

**`seargraph` was deleted, not moved into that repo (2026-09-12).** It was the
`seargraph-langgraph` subagent (LangGraph pipeline design for the private SEARGraph project:
fidelity metrics, constrained optimization, iterative refinement, character embeddings),
wrapped in a plugin as a SCOPING choice — corrected 2026-09-06, the earlier claim that "only a
plugin can ship a subagent" is false. The pinned home-manager DOES expose
`programs.claude-code.agents` (modules/programs/claude-code/options.nix:215, an `agentsDir` at
:341, written by default.nix:334,:337 through lib.nix:38-42 to `${configDir}/agents/<name>.md`).
What that option cannot do is scope the agent: it installs GLOBALLY into `~/.claude/agents/`.

The scoping reasoning was right and the mechanism was wrong. **A project's own
`.claude/agents/` is the canonical way to scope an agent** — no plugin, no marketplace entry,
no Nix wiring, and it cannot be loaded in sessions that have nothing to do with that project.
The file now lives at `SEARGraph/.claude/agents/seargraph-langgraph.md`.

Adding one = a `plugins/<name>/` tree with `.claude-plugin/plugin.json` + a `marketplace.json`
entry **in that repo**, then `nix flake update kattakath-ai` here and its bare name
in `local.claudePlugins.marketplaces.kattakath.plugins`; validate with
`claude plugin validate --strict`. Iterate without the push/update loop via
`nix flake check --override-input kattakath-ai path:../ai`.

**A SECOND source costs one input and its own entries — no new mechanism.**
`local.claudePlugins.marketplaces` is `attrsOf` and `programs.claude-code.skills` is a
plain attrset, so both already take N. The operator's `ismailkattakath/ai` and
`izzykatt/ai` are deliberately NOT pinned here: they aggregate experiments, and an
experiment has no business being always-on global context on the working Mac. Add one
when it has earned that, or scope it to a project instead.

A **skill** that needs no command/hook/MCP/agent surface belongs in
[`kattakath/ai`](https://github.com/kattakath/ai)'s `skills/`, not in a plugin —
reach for a plugin only when the unit is more than a skill. An agent for ONE project belongs
in that project's `.claude/agents/`, per the seargraph record above.

### Project memory

Lives OUTSIDE the repo, in the harness's own per-project store
(`~/.claude/projects/<slug>/memory/`), whose `MEMORY.md` index is loaded into context at the
start of every session with no hook involved. Written via `/remember-nix`. An in-repo
`memory/` tree surfaced by a `memory-loader.js` SessionStart hook was retired 2026-09-06:
the directory never existed, so the hook never emitted anything, while the native store
quietly held the real entries.

## CI, release, publishing

**Three checks exist ONLY on `aarch64-linux`**, so the documented local gate — a bare
`nix flake check`, which is darwin-native on the Mac — never builds them:
`cloudflared-connector-module`, `firmware-secrets-module`, `nixpi-firmware-names`
(measured 2026-09-22: 18 linux checks, 40 darwin, 3 linux-only). Every other linux check
has a darwin twin with identical logic, so the bare command does exercise those.

Build the three locally when you touch what they cover — Determinate's native Linux
builder runs them fine, verified with `--rebuild` so they genuinely executed:

```bash
nix build --no-link .#checks.aarch64-linux.{cloudflared-connector-module,firmware-secrets-module,nixpi-firmware-names}
```

**Not** `nix flake check --all-systems` (builds on). It does reach the linux checks —
proven by `checks.aarch64-linux.pre-commit` emitting builder log lines and a non-zero
BUILDER exit — but that check FAILS on the native Linux builder with
`FileNotFoundError` from pre-commit's treefmt hook, for a builder-environment reason,
not a code one. It passes on CI's real `ubuntu-24.04-arm` runner. A gate that cries
wolf is worse than no gate; same class as the caddy `cp --no-preserve=mode` EPERM.

`.github/workflows/nix-ci.yml` — native multi-system Nix CI on GitHub Actions, ALL on
GitHub-**HOSTED** runners (`ubuntu-24.04-arm` for aarch64-linux, `macos-latest` for
aarch64-darwin; both free & unlimited on public repos). The leg COUNT is no longer a fixed 2:
a `legs` job derives the build matrix from the fleet's own host systems (below), so the
workflow's jobs are `flake-checker` (advisory), `legs`, one `build` leg per host system, and
the aggregate `required-checks`. Each build leg *builds*
the lint/format/structural `checks` — `formatting`, `pre-commit`,
`claude-md-budget`, `ast-grep`, `deploy-schema`, `capsule-registry` — with `nix-fast-build` (it globs `.#checks.<system>`, so a NEW check needs no workflow edit;
pushed to the `kattakath` Cachix cache) and
*evaluates* (no build) its host config toplevel(s). Building host toplevels is deferred to
release time (`build-installers`, also hosted).

**BOTH halves of the coverage invariant are DERIVED, not listed** (2026-09-21) — the legs as
well as the hosts each leg evaluates. One `legs` job (on `macos-latest`, because this evaluator
must reach both systems' configurations) emits
`{include:[{name,runs-on,eval-attrs}]}`, which `build` consumes via
`strategy.matrix: ${{ fromJSON(needs.legs.outputs.matrix) }}`. Legs therefore come FROM hosts:
a leg owning **zero** hosts is structurally impossible, and the reachable failure is the
inverse — a HOST no leg claims hard-fails `legs` with *add its runner to this lookup*. Today
that reproduces the old hard-coded lists exactly (aarch64-linux → `nixpi`+`nixvm`,
aarch64-darwin → `macos`), but a host added to `modules/parts/hosts.nix` now either lands on an
existing leg or stops CI until someone names its runner; previously it was silently untested
until someone remembered this file. It runs as ONE job, not a step inside each leg, because the
check needs the whole host→system list that no single leg can see. The ONE hard-coded fact left
is the system → `runs-on` lookup, which GitHub owns and the flake cannot answer.

**`nix flake show --json --all-systems` IS the source.** An earlier claim here that it could
not serve was re-measured and is false, so the off-the-shelf tool was adopted and both
hand-written `--apply` expressions walking `config.nixpkgs.hostPlatform.system` are retired.
Its flake-schemas `inventory` carries `forSystems` per host child, classified by the
CONFIGURATION's own system — measured on aarch64-darwin: `nixosConfigurations.nixpi →
["aarch64-linux"]`, `darwinConfigurations.macos → ["aarch64-darwin"]`. Two degradations are
real, and each is now a GUARD rather than a reason to reject: without `--all-systems`,
foreign-system children come back `{"filtered": true}` (measured), so classification would
silently follow the RUNNER's arch; and upstream Nix emits the flat legacy shape with no
`inventory` key, which parses to ZERO rows (probed). Both fail the job loudly, so a revert to
`cachix/install-nix-action` cannot quietly ship a fleet with no legs. The empty-attrs test
inside a leg survives as the belt to that derivation's braces (`nix-ci.yml:272-275`) and is a
hard failure, never the old `if: matrix.eval-attrs != ''` skip, which made a vacuous leg go
green while testing nothing. `required-checks` accordingly `needs: [legs, build]` and fails on
**`'skipped'`** as well — a failed `legs` does not fail `build`, it SKIPS it, and skipped is
neither failure nor cancelled, so without that the aggregate gate would report green over zero
legs.

**No workflow in this repo targets a self-hosted runner** — every leg is GitHub-hosted (fork
PRs need no runner fallback), and day-to-day local aarch64-linux builds use Determinate's
native Linux builder on the Mac. Branch protection requires the aggregate `required-checks`
job.

Do **not** read that as "the Mac has no runners": `macos` hosts **six** runner lanes — two
bare-metal ephemeral runners on the **`dontsell-ai`** org
(`modules/darwin/github-runner.nix` above), three ephemeral Tart-VM-per-job runners
(`local.tart.githubRunners.*` — `kattakath`, `silvercreek-ai`, `dontsell-vm`), and one GitLab runner
(`local.tart.gitlabRunner`). None of them serve *this* repo's CI. The facts are about different repos.

Also in `.github/workflows/`: `auto-merge.yml`, `build-devcontainer.yml`,
`build-installers.yml`, `claude*.yml`, `gitleaks.yml`, and `flakehub-publish.yml` — the last
publishes each push to `main` as a rolling release to FlakeHub via
`DeterminateSystems/flakehub-push`, authenticated by OIDC/`id-token: write` with **no** stored
token; per FlakeHub's trusted-platform model, flakes publish only from CI, never ad-hoc from a
laptop. Merge mechanics: [`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md).

## Binary cache (Cachix)

The public `kattakath` cache is consumed by every host (`modules/shared/nix-cache.nix`, wired
in via the flake's module lists) and the devcontainer. Read is public — only the substituter
URL + public key, **NO token on any consumer**. The write credential `CACHIX_AUTH_TOKEN` lives
in exactly two places: a **GitHub Actions secret** (used by `cachix/cachix-action` in
`nix-ci.yml`, `build-devcontainer.yml`, and `build-installers.yml` to push build closures) and
— since 2026-08-21 — the operator's **login Keychain** (registered via `secret set`,
loader-exported like every personal token) for ad-hoc local `cachix push kattakath <paths>`;
never in Nix or git, and consumers still substitute tokenless (read stays public). Note the
token does NOT influence builds or substitution — Nix sandboxes scrub the environment, so it is
only ever consumed by the `cachix` CLI at push time.
