Part of the [repo map](../repo-map.md) — the full fleet architecture.

## Entry points

### `flake.nix`

**Since ADR-002 wave 2 this file is inputs + ONE `flake-parts.lib.mkFlake` call** — down from
2,254 lines, and smaller again since, as removed subsystems took their comments with them.
The count is deliberately not restated here: nothing gates it, so a number in prose only
rots. `wc -l flake.nix` is the answer. Every output is defined in [`modules/parts/`](engine.md#modulesparts--the-flake-engine),
one file per concern, discovered by `import-tree`. Nothing below moved *semantically*; the
acceptance test for that wave was an **empty `nix flake show --json` diff** plus byte-identical
host toplevels.

Pins `nixpkgs` + `nix-darwin` + `home-manager` + `treefmt-nix` + `git-hooks` + **`flake-parts`**
+ **`import-tree`** + `raspberry-pi-nix` + `nix-vscode-extensions` + `nix-homebrew` + `agenix` +
Claude Code skill inputs (`agent-skills-vercel`, `agent-skills-anthropic-official`, both `flake = false`).
**`flake-parts` is a DIRECT input** with `nixpkgs-lib.follows = "nixpkgs"` — it cannot be
`follows = ""`, because flake-parts does `inherit (nixpkgs-lib) lib` (`lib.nix:12`), so rebinding
that name to THIS flake makes it the `lib` of a thing with no `lib`. It was already forced and
undroppable before wave 2 (six of the seven satellites called `mkFlake`); now it is declared here
rather than borrowed from an arbitrary satellite anchor. **There are no satellite inputs left.**

Exports:

- `darwinConfigurations."macos"` (aarch64-darwin).
- `nixosConfigurations."nixpi"` / `"nixvm"` (aarch64-linux) — `nixvm` is the disposable GUI dev
  VM, materialised only via `nix run .#nixvm`. The exported base (non-`vmVariant`) toplevel is
  an EVAL SUBSTRATE only — it carries no `virtualisation.diskImage` and is never booted.
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

**The input diet — `follows` is not optional bookkeeping here.** 31 root inputs pull a
transitive graph, and every duplicate node is another fetch, another eval, another thing
`flake-checker` has to reason about. The lock sits at **56 nodes** today; it bottomed out at
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
[`flakehub-input-freshness.md`](../flakehub-input-freshness.md) § Shape vs. revisions.

### `treefmt.nix`

Single source of truth for formatting + lint-fix (nixfmt + statix + deadnix). Drives
`nix fmt`, the `checks.formatting` CI gate, and the pre-commit hook — change a tool here and
every entrypoint follows.

Scope is deliberately **tools that rewrite files**. Non-rewriting structural lint is a separate
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

Six rules, each mechanising a convention that was **prompt-only** until now (all
`severity: error`, so a match FAILS the build — "report-only" means only that none of them
rewrites a file):

| Rule | Lang | Mechanises | Notes |
|---|---|---|---|
| `nix-hardcoded-home-path` | nix | CLAUDE.md § Conventions "Paths — two axes" (runtime half) | The gate half of the [`claude-code-nix`](https://github.com/kattakath/ai/tree/main/plugins/claude-code-nix) plugin's `nix-home-path-lint` hook, which is PostToolUse and so only ever sees *Claude's* writes — a human or flake-bump commit slipped through. Matches `string_fragment` nodes only, so comments and Nix source path literals are exempt by construction rather than by heuristic. Keep the regex in sync with the hook. |
| `launchd-bare-interpreter-arg0` | nix | [`.claude/rules/launchd-naming.md`](../../.claude/rules/launchd-naming.md) | Flags `ProgramArguments[0]` / `Program` pointing at a bare `sh`/`bash`/`python3`/`node`/… so Background Task Manager can't list a fleet agent as generic persistence. Only sees units authored *here*; the three known upstream `/bin/sh` daemons live in no `.nix` file and must not be renamed. |
| `capsule-must-not-reach-out` | nix | ADR-002's capsule boundary (§ `modules/features/`) | Scoped by `files:` to `modules/features/**`; flags a `path_expression` escaping the capsule's own directory. The file-layer half of the boundary — `checks.<system>.capsule-registry` is the option-layer half. Blind to overlays, `specialArgs` and runtime-built store paths (ADR-002 §7.6, §9.3). |
| `home-must-not-cross-layers` | nix | the `modules/home/` layer boundary (`662db6a`, 2026-09-14) | The Home Manager profile may reach **down** into `packages/`, `skills/` and `claude/` — never **across** into `modules/features/`, nor **up** into `modules/parts/`, `hosts/` or `infra/`. |
| `activation-must-not-touch-secrets` | nix | ADR-004 §2.5 ([`secrets-recovery-and-identity-adr.md`](../secrets-recovery-and-identity-adr.md)) | A `home.activation` / `system.activationScripts` / `system.userActivationScripts` string that names `secrets-{rehydrate,push,resolve,status}` or `gcloud secrets`/`gcloud auth`. Activation must never touch a secret backend; the CLIs are operator-invoked after `gcloud auth login`. Eval-time twin: `checks.aarch64-darwin.keychain-secrets-backend-inert`. |
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

`deploy.nodes.nixpi` (defined in [`modules/parts/deploy.nix`](../../modules/parts/deploy.nix)):

| Setting | Value | Why |
|---|---|---|
| `magicRollback` | `true` | The Pi activates behind a watchdog and **reverts itself** unless the deployer reconnects over a *second* ssh session and confirms. A change that kills sshd / the tunnel connector / networking becomes a failed deploy, not a physical SD-card pull (`nixpi-sd-flashing-runbook.md`, ~40 min). |
| `autoRollback` | `true` | Roll back if the activation script itself fails. |
| `remoteBuild` | `false` | **The Pi must never build.** Closures are built on the Mac / CI and `nix copy`'d, substituting from Cachix on the destination. |
| `fastConnection` | `false` | Keeps `--substitute-on-destination`, so the Pi pulls most paths straight from Cachix instead of over the tunnel. |
| `activationTimeout` / `confirmTimeout` | `600` / `120` | Upstream defaults are too tight for a Pi 4 over a Cloudflare Tunnel, and a timeout here does not mean "slow" — it means an unattended **rollback of a good deploy**. |
| `hostname` | `nixpi.${domainName}` | The tunnelled name, not `nixpi.local` — see the ssh block in `modules/home/default.nix`. |
| `sshUser` / `profiles.system.user` | `loginName` / `root` | SSH in as the operator (keys-only), activate as root via passwordless `wheel` sudo (`modules/nixos/core.nix`), so no `interactiveSudo`. |

`sshOpts` is deliberately **empty**. deploy-rs space-joins `sshOpts` into `NIX_SSHOPTS`, which
nix then re-splits on whitespace, so a spaced `-o ProxyCommand=…` is mangled for the `nix copy`
leg. `~/.ssh/config` is the one place a spaced `ProxyCommand` survives **both** legs — hence
the declarative `Host nixpi.<domain>` block in `modules/home/default.nix` (store-path
`cloudflared`, `StrictHostKeyChecking = accept-new` because a reflash mints a new host key).
That block replaces the old "hand-edit `~/.ssh/config`" instruction in the runbooks, which was
unfollowable — the file is a read-only `/nix/store` symlink.

**Two invocation traps, both of which fail without saying so.** `deploy-rs` is consumed as a
flake **lib**, so the `deploy` CLI exists only inside the devShell: `nix develop -c` is not a
style preference. Measured 2026-09-16 — a bare `deploy` outside the devShell **exits 1 with
EMPTY output**, a silent failure rather than a `command not found`. And a bare `deploy` with no
`--targets` **fans out over EVERY node in `deploy.nodes`**, so always name the target.

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
enabled fleet-wide in `modules/home/default.nix`; this repo alone opts out, since `2fa73b9`.)

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

All four are safe to commit. Full rules: [`secrets-and-keychain.md`](../secrets-and-keychain.md).

