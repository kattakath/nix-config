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
  over a Cloudflare Tunnel connector + Caddy. Generic and **site-free in this public repo** —
  the real hosted sites and dontsell.ai's second tunnel connector are supplied by the private
  nix-personal composition flake (see [`private-home-modules.md`](private-home-modules.md)).
- **`nixvm`** (aarch64-linux) — a throwaway NixOS dev VM materialised **only** as
  `nix run .#nixvm` (a build-vm XFCE desktop — no installed VM, no builder, no runner).
- **`macvm`** (aarch64-darwin) — a Tart guest on Apple Virtualization that shares macos's
  stack with a leaner Homebrew set + the MCP gateway trimmed off, activated *inside* the VM
  under the same operator identity as every other host.
- A matching **Devcontainer** image.

Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## Entry points

### `flake.nix`

Pins `nixpkgs` + `nix-darwin` + `home-manager` + `treefmt-nix` + `git-hooks` +
`raspberry-pi-nix` + `nix-vscode-extensions` + `nix-homebrew` + `agenix` + Claude Code skill
inputs (`agent-skills-vercel`, `agent-skills-anthropic`, both `flake = false`).

Exports:

- `darwinConfigurations."macos"` / `"macvm"` (aarch64-darwin) — `macvm` is a Tart guest VM
  (Apple Virtualization + IPSW) sharing macos's stack with a leaner Homebrew set + the MCP
  gateway trimmed off.
- `nixosConfigurations."nixpi"` / `"nixvm"` (aarch64-linux) — `nixvm` is the throwaway GUI dev
  VM, materialised only via `nix run .#nixvm`.
- `packages` / `devShells` / `checks` / `formatter` per system via a `forAllSystems` helper.
- `deploy.nodes.nixpi` — the deploy-rs remote-activation node (see below).

There is **no `nixpi-installer`** — the LIVE `nixpi` sdImage is secret-free, so it *is* the
flashable artifact, prebuilt in CI as the `nixpi-sd-image` package and published to the
`installer-latest` release; token + Wi-Fi are planted post-flash on the FIRMWARE partition.

The FLEET is two systems: `aarch64-darwin` and `aarch64-linux` — **no x86_64 HOST anywhere**.
The devcontainer image is the sole exception: it also builds `x86_64-linux` (via
`devcontainerSystems`) so it runs on x86_64 GitHub Codespaces.

**Identity** (`loginName = "ismail"`, `domainName = "kattakath.com"`, `fullName`, `userEmail`)
is defined once as `let` bindings (`identityArgs`) and threaded through
`specialArgs`/`extraSpecialArgs`. `mkDarwin` takes an optional per-host `identity` override
(and `mkHomeManagerModule` is a function of it) so a host *could* run under a different
persona, but nothing in the fleet uses it today — `macos`, `macvm`, and `nixpi` all inherit
the same global identity; per-host divergence (leanness, package sets, desktop aesthetics) is
achieved entirely via `networking.hostName`-gated `lib.mkIf`, never via a separate identity.

### `flake.lock`

Pinned input revisions; commit every change, never hand-edit.

**The input diet — `follows` is not optional bookkeeping here.** 33 root inputs pull a
transitive graph, and every duplicate node is another fetch, another eval, another thing
`flake-checker` has to reason about. The lock is held at **60 nodes**; it was **72** before the
dedupe pass. Two mechanisms, and conflating them is the trap:

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
| `git-hooks.inputs.flake-compat.follows = ""` | drop | `outputs = { self, nixpkgs, ... }` never destructures it; `default.nix`/`shell.nix` read the rev from git-hooks' *own vendored* `flake.lock`, and we only ever call `lib.<system>.run`. |
| `firmware-secrets.inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs"` + `follows = "firmware-secrets/flake-parts"` on `keychain-secrets` / `local-rag` / `vast-provision` | dedupe | Our four extracted flakes all call `flake-parts.lib.mkFlake` (forced — never droppable) at the **same rev**, yet each shipped its own flake-parts *and* its own `nixpkgs.lib`: 8 nodes for one library, now 1. The `nixpkgs-lib` half is upstream-blessed — `terranix` already carries that exact line, and flake-parts documents the override behind a 23.05 floor our `nixpkgs.lib` clears by three years. |

**Deliberately left duplicated.** Not everything that looks like a duplicate is one:

- **`raspberrypi/linux` ×3** — three *different* revs; a deliberate kernel-branch matrix that
  raspberry-pi-nix selects from at eval time. A `follows` between them silently swaps the LIVE
  Pi's kernel.
- **Determinate's `nixpkgs` trees** (`nixpkgs-weekly`, nix-src's own, `nixpkgs-23-11`,
  `nixpkgs-regression`) — its build/regression pins, reached through `root.determinate`. Not
  ours to re-point; forcing them rebuilds the daemon closure against an untested nixpkgs.
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

Gated by `checks.<system>.ast-grep` (a `runCommand`, shaped like `vast-lib-drift`) — **not** a
treefmt formatter. treefmt-nix ships no `programs.ast-grep`, and none of these rules has a
mechanical `fix:`, so the honest home is a check. `ast-grep` is also in the devShell (from the
same pinned nixpkgs) for iterating on rules; the binary is `ast-grep` — there is no `sg` alias.

Three rules, each mechanising a convention that was **prompt-only** until now:

| Rule | Lang | Mechanises | Notes |
|---|---|---|---|
| `nix-hardcoded-home-path` | nix | CLAUDE.md § Conventions "Paths — two axes" (runtime half) | The gate half of `.claude/hooks/nix-home-path-lint.js`, which is PostToolUse and so only ever sees *Claude's* writes — a human or flake-bump commit slipped through. Matches `string_fragment` nodes only, so comments and Nix source path literals are exempt by construction rather than by heuristic. Keep the regex in sync with the hook. |
| `launchd-bare-interpreter-arg0` | nix | [`.claude/rules/launchd-naming.md`](../.claude/rules/launchd-naming.md) | Flags `ProgramArguments[0]` / `Program` pointing at a bare `sh`/`bash`/`python3`/`node`/… so Background Task Manager can't list a fleet agent as generic persistence. Only sees units authored *here*; the three known upstream `/bin/sh` daemons live in no `.nix` file and must not be renamed. |
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

`deploy.nodes.nixpi` (defined in `flake.nix` right after `nixosConfigurations`):

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

⚠ **`deploy --targets .#nixpi` from THIS repo would deploy a site-free Pi** — the same class of
trap as `darwin-rebuild switch --flake .#macos`. This node ships here as the **engine**, not the
deployment: the private nix-personal flake is the intended caller and reuses these settings
against *its* `nixosConfigurations.nixpi` (see
[`private-home-modules.md`](private-home-modules.md)), so the rollback semantics/timeouts/ssh
plumbing are single-sourced here. Magic rollback does **not** protect against this — it reverts
an *unreachable* host, and a site-free Pi is reachable.

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

It is added via `deployChecksFor system` folded into `forAllSystems`, guarded by
`lib.optionalAttrs (deploy-rs.lib ? ${system})`, **not** the README's `mapAttrs …
deploy-rs.lib` — deploy-rs exports `lib` for four systems, and that idiom would create
`checks.x86_64-linux` + `checks.x86_64-darwin`, which this flake permits nowhere.

### devShell

Entered with `nix develop` (in the devcontainer or on a nix host). There is **no**
`.envrc`/direnv auto-load — run `nix develop` explicitly.

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
`aarch64-linux` `activate` for nixpi's closure on Determinate's ~1-CPU Linux builder.
Deliberately **not** warmed via `checks`: `checks` is strictly lint-only (`nix flake check`,
`/eval`, `nix-ci.yml` all build it), and paying a Rust build on every `/eval` to save it on a
rare fresh-machine `nix develop` is the worse trade.

### `secrets/secrets.nix`

agenix recipients rules — **two** committed secrets on **two different models**:

- `secrets/cloudflared-token.age` (nixpi's Cloudflare tunnel token) — encrypted to the
  **operator's key alone**, the **operator-only vault** model: the operator decrypts it on the
  Mac to plant on the SD card's FAT `FIRMWARE` partition, and it is NEVER decrypted on nixpi.
- `secrets/gh-app-dontsell-ai-key.age` (the `macos` runner's GitHub App RS256 private key) —
  recipients are operator **+ the `macos` host key**, so this one IS **host-decrypted at
  activation** into `/run/agenix/`. The host-decryption path is live; do not describe it as
  unused.

Both are safe to commit. Full rules: [`secrets-and-keychain.md`](secrets-and-keychain.md).

## `hosts/` — per-host entry profiles

- **`macos.nix`** — the darwin client host. Imports `../modules/darwin/github-runner.nix` and
  enables `services.macosGithubRunner` with `count = 2` for the **`dontsell-ai`** org (see that
  module's section below) — nix-config's *own* CI is fully GitHub-hosted and uses no runner, but
  this Mac is not runner-free. Carries its own Homebrew brew/cask/masApps lists, incl. a
  `libreoffice` cask backing the docx/pptx/xlsx/pdf Claude Code skills' `soffice` dependency.
- **`macvm.nix`** — Tart aarch64-darwin guest: leaner Homebrew, no masApps, MCP gateway +
  desktop aesthetics off, red accent tell. Same operator identity as every host, no `identity`
  override; activated *inside* the VM as `ismail`. Host→guest SSH is Apple's sshd via
  `services.openssh` + keys-only operator key + ALF off. Host control plane
  `packages/macvm-tart.nix` / `nix run .#macvm-tart-*`; clipboard sync + `tart exec` /
  `tart ip --resolver=agent` RPC via the `packages/tart-guest-agent.nix`-backed
  `launchd.user.agents.tart-guest-agent`. Runbook: [`macvm-tart-runbook.md`](macvm-tart-runbook.md).
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
    (both are `aarch64-linux`). Workaround: realise the toplevel **on the Pi** — the only
    derivations left after substitution are text assembly (`Caddyfile-formatted`, unit files,
    `etc`, `activate`, `system`), zero compilation, so this does not violate "never build heavy
    on the Pi". Ship the tracked private tree over (`git ls-files | tar`, ~3 MiB), then
    `nixos-rebuild switch --flake path:~/nix-personal#nixpi` locally on the Pi; it substitutes
    the rest straight from Cachix/cache.nixos.org instead of pushing ~436 MiB through the
    tunnel. `--builders`/`--max-jobs 0` are **not** an option: the operator is `Trusted: 0`
    against the local daemon, so client-side builder settings are silently ignored.
    - **Do not compare store paths across the two hosts** while doing this. The Mac
      evaluates nix-personal as a **git** flake and the shipped copy on the Pi is a
      **path** flake, so `self` differs and the two produce **different `nixos-system-nixpi`
      derivations for identical content** (measured: `520mq98p…` on the Mac vs `24jhkclg…`
      on the Pi, same `26.11.…d2f6794` label). Only Mac-vs-Mac or Pi-vs-Pi comparisons mean
      anything. To prove a change is closure-neutral, diff the **Mac-side** `drvPath` across
      the two revs; to prove the Pi didn't move, check that `nixos-rebuild` reports the same
      `/run/current-system` and that `nix-env --list-generations` did **not** add a generation
      (`nix-env --set` to an unchanged path creates none).
- **`nixvm.nix`** — a SLIM throwaway aarch64-linux dev VM: no disko, no runner, no install;
  materialised only as the graphical `nix run .#nixvm` build-vm, whose guest builds locally on
  the native Linux builder or substitutes from Cachix.

## `modules/` — reusable modules split by platform

Platform branching lives **here** behind `lib.mkIf`, not duplicated across hosts.

### `modules/shared/`

`modules/shared/{home.nix,mcp.nix,chromium.nix,desktop-aesthetics.nix,nix-cache.nix,nix-ld-libraries.nix,wireguard-configs.nix,claude-otel.nix,hm-launchd/}`
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
  wired. Also declares Spotlight-visible, focus-or-launch `.app` bundles for the Android
  emulator and `macvm` (`home.file."Applications/Android Emulator.app"` / `"Mac VM.app"`,
  backed by `packages/spotlight-launchers.nix`, macos-only).
- **`mcp.nix`** — the claude-code MCP-server config. See [`mcp-gateway.md`](mcp-gateway.md).
- **`chromium.nix`** — `programs.ungoogledChromium`, real-Mac-only: the declarative surface for
  the Homebrew `ungoogled-chromium` cask. Installs **no** browser (`programs.chromium.package =
  null`) — nixpkgs' `chromium`/`ungoogled-chromium` are `*-linux` only, so the `.app` must be a
  cask; this module contributes only the files Chromium reads out of its user-data dir, via
  upstream HM `programs.chromium` (no custom shell), plus two recommended-level policies and
  the LaunchServices default-browser claim. Five surfaces, five sideloaded extensions:
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
    **This attrset is the public/private seam:** `modules/shared/home.nix` declares the public
    scripts from `userscripts/`, nix-personal adds its own via `extraHomeModules`, and the two
    merge — so keys must be distinct across the two repos, since the module system treats a
    repeated key as a **conflict**, not an override.

    **Nix owns the files, never Violentmonkey's database**, and that is a Chromium wall rather
    than a shortcut. bitbloxhub's Firefox pattern (enterprise policy → `browser.storage.managed`
    → a Violentmonkey *fork* that parses it at startup) does **not** port: the fork's hook is
    Firefox-gated, Chromium only populates `chrome.storage.managed` for extensions declaring a
    `storage.managed_schema` (Violentmonkey declares none), and the *forced* policy level the
    fork would need lives in MDM-owned `/Library/Managed Preferences/org.chromium.Chromium.plist`,
    unreachable from Home Manager (the **recommended** level is reachable — see
    `hideBookmarkBar` below — but it cannot lock a value, which is what that trick relies on).
    A userscript is installed by **navigating** to it, so install stays one click
    per script off the index page — and **no script has an update channel, public or private.**
    `checks.<system>.userscripts` in `flake.nix` bans `@downloadURL`/`@updateURL`/`@installURL`
    outright, so **every** change is a `@version` bump plus that same click-through; Violentmonkey
    then falls back to `lastInstallURL`, which is exactly the `file://` path Nix wrote. The keys
    are banned because Greasy Fork strips them on upload anyway, and pointed at this repo they
    would let a push to `main` mutate an installed script with no activation.
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
- **`desktop-aesthetics.nix`** — the macOS desktop look, split in two:
  - **Terminal.app** is UNGATED on every darwin host — 16pt type on EVERY profile + stock
    `Pro` as default/startup, driven through Terminal's own AppleScript `settings set` API
    since Terminal owns `com.apple.Terminal` and clobbers direct plist writes. Guarded on
    Terminal already running so a rebuild never launches it (`ps`, not `pgrep` — the latter
    can't see it from activation). This repo used to VENDOR an "Ubuntu" profile + generator
    here; dropped once stock `Pro` proved fine, the type size being the only part worth
    declaring.
  - The **custom wallpaper** stays behind `local.desktopAesthetics.enable` (default true;
    `macvm` sets it false to keep the stock desktop as a visual tell).
- **`nix-cache.nix`** — the Cachix binary-cache option (see § Binary cache below).
- **`nix-ld-libraries.nix`** — the shared nix-ld library list.
- **`wireguard-configs.nix`** — operator-managed WG confs synced to `~/.config/wireguard`, no
  autostart. See [`wireguard-vpn.md`](wireguard-vpn.md).
- **`claude-otel.nix`** — `services.claudeOtel`, real-Mac-only: a local OTel Collector
  receiving Claude Code's native OpenTelemetry `tool_decision`/`tool_result` events over
  localhost OTLP, writing a rotating JSONL for `/routing-review` to mine for
  deterministic-routing hardening candidates. See
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`hm-launchd/`** — replaces stock HM launchd so every agent's `ProgramArguments[0]`
  basename is `nix-<activity>` (macOS BTM rule — tags nix-config origin; **never** a bare
  interpreter like `sh`/`python3`; wait4path stays inside the wrapper). This is **mandatory
  for every launchd unit this repo authors**: HM user agents are auto-wrapped here, and any
  hand-written `launchd.daemons`/`launchd.agents` MUST point `arg0` at a
  `writeShellScriptBin "nix-<activity>"` wrapper (canonical:
  `telegramMcp`/`wpMcp`/`cloudflaredConnector` in `mcp.nix`) — codified as the always-applied
  [`launchd-naming.md`](../.claude/rules/launchd-naming.md) rule, which also documents the
  three known-upstream `/bin/sh` exceptions that are NOT ours and must never be renamed.

### `modules/darwin/`

`modules/darwin/{core.nix,homebrew.nix,nix-homebrew.nix,xcode-license.nix,github-runner.nix}`

- **`core.nix`** — macOS system defaults (dock/finder/NSGlobalDomain, Touch ID for sudo,
  `stateVersion = 5`). On **macos only**: login openers (`nix-*` BTM wrappers) + hourly
  `~/Downloads` rotation into `~/.Trash` (`nix-file-rotation-downloads`; files **and**
  directories, 30d staged retention → 7d steady state; paired with
  `finder.FXRemoveOldTrashItems` so Trash self-purges). `~/Downloads` is the single staging
  inbox — `screencapture.location` points at it, so ⇧⌘4 screenshots and ⇧⌘5 recordings land
  there too — and it is shared R/W into macvm via Tart VirtioFS, where the guest symlinks its
  own `~/Downloads` to it and must **never** rotate it (`mv` across filesystems = `cp` + `rm`).
- **`homebrew.nix`** — the declarative Homebrew **framework**: owns only
  `enable`/`onActivation` with `cleanup = "uninstall"`/`taps`. The actual
  `brews`/`casks`/`masApps` lists live **per host** in `hosts/<host>.nix` so macos and macvm
  carry different app sets.
- **`nix-homebrew.nix`** — Homebrew-itself install via `nix-homebrew`.
- **`xcode-license.nix`** (macos only) — runs *before* `brew bundle` to `mas install` Xcode
  when declared in `masApps` and `xcodebuild -license accept`, so formulae are not blocked by
  an unaccepted SDK license (Brewfile order is brews→casks→mas).
- **`github-runner.nix`** — `services.macosGithubRunner`: N hand-rolled launchd daemons running
  **ephemeral, org-level self-hosted GitHub Actions runners**. Built then retired 2026-07-16
  once nix-config's own CI no longer needed one; **revived 2026-08-23 for a different consumer**
  — `dontsell-ai`'s repos, whose macOS + Playwright + Prisma jobs neither GitHub-hosted (no
  hosted-minutes budget on that org) nor the native Linux builder (build-only, ephemeral,
  1-CPU/8 GB) can serve. `hosts/macos.nix` enables it with `count = 2`.
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
    environment. `arg0` is `nix-github-runner-<instance>` per the launchd-naming rule.
  - Also pins `postgresql`+pgvector onto the runners' PATH (`modules/shared/home.nix`, `hiPrio`
    to resolve the duplicate `bin/psql`).

### `modules/nixos/`

- **`modules/nixos/core.nix`** — shared NixOS baseline: the `ismail` user + authorized SSH key (the
  operator's static ed25519 key, the sole network login credential on every host), keys-only
  sshd (no password, no root login), firewall (TCP 22, UDP 5353 for mDNS), avahi
  `<host>.local` publishing, native `programs.nix-ld`, zram swap, automatic GC. `nixpi`'s sshd
  is reached over the Cloudflare tunnel
  (`cloudflared access ssh --hostname nixpi.kattakath.com`); `nixvm` is only ever the throwaway
  local `nix run .#nixvm` desktop, so it has no networked login path.
- **`modules/nixos/desktop-vm.nix`** — opt-in `services.desktopVm.enable` (default false): a lightweight X11
  **XFCE** desktop with passwordless autologin (the `loginName` specialArg) plus QEMU/SPICE
  guest integration (`qemuGuest`, `spice-vdagentd`) for the `nixvm` sandbox.
  `hosts/nixvm.nix` enables it **only inside `virtualisation.vmVariant`**, so the desktop
  materialises for the graphical `nix run .#nixvm` / `build-vm` path — the sole way `nixvm` is
  ever booted.

### NixOS modules consumed as flake inputs

- **the `nix-cloudflared-connector` flake** — opt-in `services.cloudflared-connector.enable`
  (default false); hardened `systemd.services.cloudflared-connector` running a
  **remotely-managed (token)** Cloudflare Tunnel — no `cloudflared tunnel login`, no cert.pem.
  Token read from `tokenFile` (module default `/etc/secrets/cloudflared-token`,
  operator-placed), never in git; an activation script warns (doesn't abort) if absent. Only
  `nixpi` enables it — and `nixpi` **overrides `tokenFile` to `/run/cloudflared-token`**, a
  root-only file that `services.firmwareProvisioning` populates at boot from the token
  operator-planted on the SD card's FAT `FIRMWARE` partition. This deliberately replaced
  agenix: agenix binds the token to nixpi's SSH host key, but a fresh SD flash rotates that
  key, breaking decryption and killing the tunnel — the sole remote path in.
- **`services.firmwareProvisioning`** — reusable `files.<name>` mechanism: each entry becomes
  a oneshot that, once `/boot/firmware` is mounted, copies an operator-planted file off the
  FAT `FIRMWARE` partition into a root-only `/run` file before its consumer starts (`required`
  fails the unit if absent; else it skips cleanly). This module was **EXTRACTED from this repo
  into a standalone MIT flake** — `nix-firmware-secrets`
  (github:kattakath/nix-firmware-secrets) — and `nixpi` now consumes it as a flake input
  (`firmware-secrets.nixosModules.default`, threaded via `mkNixos` specialArgs in `flake.nix`,
  imported in `hosts/nixpi.nix`) rather than a vendored copy; the repo dogfoods its own
  extraction. `nixpi` uses it for BOTH the Cloudflare connector token AND Wi-Fi
  (`wpa_supplicant.conf`) — host-key-independent secrets a fresh SD flash needs, since agenix
  (which binds to the rotated host key) would lock us out. Planted from macOS by the
  `nixpi-provision`/`nixpi-flash` apps.

### Web serving on `nixpi`

Uses upstream `services.caddy.virtualHosts` directly (in `hosts/nixpi.nix`), **no wrapper
module**: one `http://<domain>` vhost per `mkNixos`'s `hostedSites` parameter (see
[`private-home-modules.md`](private-home-modules.md)), each `file_server`ing its `root`. This
public repo passes no `hostedSites` (`[ ]` default), so the public
`nixosConfigurations.nixpi` boots Caddy with **zero vhosts** — the real production sites
(`kattakath.com`, `snoringirl.com`, `ismail.kattakath.com`, `dontsell.ai`) live only in the
private layer. Caddy sits **behind** the Cloudflare Tunnel (tunnel → Caddy on :80), so no
public IP/port-forward is needed and TLS terminates at Cloudflare's edge (the `http://` prefix
disables Caddy auto-HTTPS to avoid a redirect loop back through the tunnel).

## `packages/`

Core package set:

- **`devcontainer-image.nix`** — MULTI-ARCH devcontainer OCI image (arm64+amd64,
  `dockerTools.streamLayeredImage`), published to GHCR as a manifest list; arch-parameterized
  loader path inside.
- **`nixpi-provision.nix`** — macOS-only: the four
  `nixpi-flash`/`nixpi-provision`/`nixpi-wifi-creds`/`nixpi-vault-token`
  `writeShellApplication` flake apps that flash the SD card and plant the token+Wi-Fi onto its
  FIRMWARE partition — the executable companion to the `nix-firmware-secrets` flake's
  `services.firmwareProvisioning`.
- **`macvm-tart.nix`** — macOS-only: host Tart control plane for `macvm` (create from IPSW,
  doctor, ensure, start/stop/ssh/ip); disk under `~/.tart/`, never in the store. See
  [`macvm-tart-runbook.md`](macvm-tart-runbook.md).
- **`key-recovery.nix`** — macOS-only: the `key-backup`/`key-recover` apps, stage 2 of Mac
  bootstrap/recovery, shellcheck-gated. `key-recover` clones, HARD-FAILS unless the login
  `id -un` == the flake's `loginName` (via the `#identity.loginName` output), then RESTORES
  from an iCloud kit or `--fresh`-FOUNDS a new operator identity, and activates `#macos`.
- **`vast-bootstrap.sh`** + **`templates/provisioner/provision-lib.sh`** — the two files a
  live Vast instance still fetches over raw HTTP from THIS repo at boot (see § Vast.ai below
  for why the `vast-*` CLI logic itself is no longer vendored here).
- **`spotlight-launchers.nix`** — macOS-only: from-scratch `.app` bundle generator (original
  in-Nix SVG/icns icons via librsvg+libicns) giving the Android emulator and `macvm` a
  Spotlight-visible, focus-or-launch identity; consumed by `modules/shared/home.nix`'s
  `home.file."Applications/*.app"`.
- **`tart-guest-agent.nix`** — macvm-only: `fetchurl` derivation for cirruslabs' ad-hoc-signed
  guest-agent binary (clipboard sync + `tart exec` / `tart ip --resolver=agent` RPC), run via
  `hosts/macvm.nix`'s `launchd.user.agents.tart-guest-agent`.

The no-Nix stage-1 `bootstrap.sh` (the `curl … | bash` entrypoint) lives at the **repo root** —
it is shellchecked as the `key-recovery-bootstrap` derivation and `key-backup` publishes it
into the iCloud kit as the offline copy.

Smaller, single-purpose CLIs:

- **`android-phone.nix`** — macOS-only: deterministic wired/wireless ADB operator
  (`list|pair|connect|disconnect|unpair|tcpip|wireless|mirror|doctor`) plus scrcpy mirroring
  for a PHYSICAL Android device; hardens around two live-reproduced adb bugs, an mDNS-cache
  staleness and duplicate-transport device listings. Its operator knowledge is also a GLOBAL
  skill, `skills/android-phone`.
- **`media-quick-actions.nix`** (macOS) — Finder right-click → **Services** entries for
  the media-toolkit CLIs, generated as Automator `.workflow` bundles. The submenu is
  **Services**, not "Quick Actions": Finder's Quick Actions submenu is fed by App Extensions
  and Shortcuts actions (`defaults read pbs` → `FinderActive` lists only `APPEXTENSION-*` and
  `is.workflow.actions.*`), which an Automator service cannot join. New or changed entries
  need **`killall Finder`** — activation links them and `pbs` registers them, but a running
  Finder keeps serving its old menu, which looks exactly like a failed install. A Quick Action is only
  two plists (`Contents/Info.plist` + `Contents/document.wflow`), so `lib.generators.toPlist`
  authors them and no Automator.app is involved. Linked into `~/Library/Services` by
  `home.nix` (an INLINE module in `imports` — one attrset cannot define both `home.file` and
  `home.file."x"`). The load-bearing key is `inputMethod = 1`, which passes the selection as
  `"$@"` — the default pipes stdin, giving a script that runs and silently does nothing.
  Verified: macOS registers and runs a bundle reached through a **symlink**, so the store-path
  source needs no copy-into-place (`mac-app-util` / home-manager's `copyApps`, the usual fix
  for Nix-symlinked `.app` bundles, are not needed here).
- **`media-toolkit.nix`** — `symlinkJoin` bundling the media-file CLIs below
  (`fix-google-video` + `extract-audio`) as ONE entry for `home.packages`, so the set
  cannot drift as CLIs are added; each stays its own derivation with its own
  `nix run .#<name>`. Membership rule: a CLI that **transforms a media file** on this
  machine. `obs-fb-setup` (writes an OBS config profile, reads a Keychain secret) and
  `fidelity-enhance` (MCP referee for an agentic image loop) are media-*adjacent* and stay
  separate — folding them in would leave the name meaning only "vaguely about media".
- **`extract-audio.nix`** — `extract-audio [--mp3|--copy|--wav|--flac] <file>...` pulls the
  audio track out of a video. **Defaults to MP3**, which plays everywhere. `--copy` is the
  lossless path (the audio is already a finished encode, so transcoding is a second lossy
  generation, and copying needs no decode — ~16000x realtime measured); that path is what
  makes the container the real problem solved here, since `-c:a copy` fails into a container
  that does not accept the codec, so it maps codec→extension (`.m4a` for AAC/ALAC, `.ogg` for
  Vorbis, `.wav` for PCM, `.mka` as the catch-all). Idempotent; preserves timestamps.
- **`fix-google-video.nix`** — detects and re-encodes video files with editor-incompatible
  codecs (most commonly VP9-in-MP4, the flavor Google Photos' download button serves for
  videos not backed up at Original quality) into H.264+AAC via VideoToolbox with a libx264
  fallback, idempotent.
- **`jobspy.nix`** — a reproducible `uv`-ephemeral wrapper CLI around the `python-jobspy`
  library for scraping job boards.
- **`jsonresume.nix`** — dual-engine `jsonresume <download|print|validate|markdown|text>`
  wrapper (`resumed` for PDF/validate, `resume-cli` where `resumed` falls short); see the
  `jsonresume-tailor` skill.
- **`mermaid-ascii.nix`** — packages `AlexanderGrooff/mermaid-ascii`, not in nixpkgs, for the
  diagrams-as-ASCII convention.
- **`obs-fb-setup.nix`** — macOS-only: configures an OBS "Facebook" profile, stream key read
  live from the Keychain, never in git/store.
- **`vpn.nix`** — the WireGuard `vpn` operator CLI. See [`wireguard-vpn.md`](wireguard-vpn.md).
- **`claude-otel-doctor.nix`** — health check for the `services.claudeOtel` collector (launchd
  agent, OTLP port, events-file freshness). See
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`fidelity-enhance.nix`** — macOS-only: the referee for an agentic image-editing loop. Grok
  Imagine generates, this judges each result against the ORIGINAL via SSIM/LPIPS/ArcFace-identity
  and returns retry/next-step/done plus prompt guidance. Ships `fidelity-enhance-mcp` (stdio
  MCP server) + `fidelity-enhance` (CLI) from one ephemeral `uv` env, Python 3.12 pinned for
  torch/insightface wheel coverage; exposed via `home.packages` + `nix run .#fidelity-enhance`.
- **`resend-cli.nix`** — the official Resend CLI, not yet in nixpkgs so `npx`-wrapped and
  version-pinned same as `mcp-wordpress`/`telegram-mcp`; injects `RESEND_API_KEY` from the
  login Keychain at run time — wired only via `home.packages`, no matching flake app.
- **`design-tokens/`** / **`email-signature/`** — small self-contained build-script-backed
  packages for their respective assets.
- **`hyperframes-selfhost(.nix)`** — see [`hyperframes-selfhost.md`](hyperframes-selfhost.md).
- **`packages/runpod-provision.nix`** — the RunPod analogue of the Vast subsystem
  (`runpod-template-apply`, macOS-only): since the official `runpod/comfyui` image has no
  Vast-style provisioning hook, it overrides `dockerEntrypoint`/`dockerStartCmd` with a wrapper
  that clones a private `comfyui-workflows`-shaped repo and runs its `runpod/provision.sh`
  before handing off to the image's `/start.sh`; secrets are RunPod **account** secrets
  (`{{ RUNPOD_SECRET_name }}`), never baked into the template.

## `userscripts/` — the PUBLIC Violentmonkey scripts

Plain `.user.js` files, one per site, referenced by name from
`modules/shared/home.nix`'s `programs.ungoogledChromium.userScripts.scripts`. The option, the
materialisation, and the reason Chromium allows nothing more declarative all live in
[`modules/shared/chromium.nix`](../modules/shared/chromium.nix) — see § `chromium.nix` above.
Private counterparts live in nix-personal's own `userscripts/` and merge into the same attrset
([`private-home-modules.md`](private-home-modules.md)); **keys must not collide across the two
repos.** Those private scripts are **NOT gated** — `checks.<system>.userscripts` globs
`${self}/userscripts/*.user.js`, i.e. this tree only, and owning the *option* buys the consumer
nothing. Measured 2026-08-31: nix-personal's `civitai-declutter` had shipped with **no
`@license`** and the check never saw it. A private script is gated only by running the same
assertions by hand.

**Authoring path — skill [`userscript-author`](../.claude/skills/userscript-author/SKILL.md),
driven by `/userscript`; never freehand.** It **measures the live page** with claude-in-chrome
before it writes a selector, then routes on the diff between the state the site already gives you
and the state you want:

| Diff verdict | What it means | What to write |
|---|---|---|
| **DOM-DIFFERS** | a selector/attribute *can* force it | set the attribute or class the site itself sets |
| **DOM-IDENTICAL** | the switch is a **pure CSS media query** — no selector can force it | lift that condition's rules and re-serve them in a **band** |
| **STATE-B-UNREACHABLE** | the state does not exist; you are constructing UI | every invented selector carries its own measured line in the file's WHY block |

The metadata block is **seeded from an already-gated script**, never hand-typed, so the contract
lives in exactly one place — which `checks.<system>.userscripts` proves on every PR **for scripts
in this tree**, and for a private one only if you mirror it by hand (above). Escalation is
mechanical, not a judgment call: at a **4th script**, the first TS/JSX need, or `GM_*` plus a
settings UI, the skill **stops** and proposes adopting `vite-plugin-monkey` as its own PR — this
tree never grows a bundler of its own, and never commits minified output.

- **`google-photos-icon-nav.user.js`** — makes `photos.google.com` render **its own**
  narrow-viewport icon rail at every window width, handing the reclaimed width to the photo grid.
  **The measurement is the design:** the DOM is *identical* either side of the responsive
  breakpoint — same tags, same classes, same attributes — so the switch is a **pure CSS media
  query** and there is nothing a selector can force. So the script lifts Google's own `@media`
  blocks out of their wrapper and replays them unconditionally, selected by `conditionText`
  within an **800–1200px band** (never a hardcoded pixel; all blocks sharing a width are
  accumulated, widest wins) and re-applied from a `document.head` **`childList`** MutationObserver
  — not from history hooks, and never with `subtree`, which over this ~1.8 MB DOM would fire
  thousands of times a scroll. Consequence: the file contains **not one Google class name**, so
  the JSCompiler churn (`RSjvib`, `JBVD2d`, …) that breaks every hand-written Photos userscript
  cannot break it; an unreadable cross-origin sheet degrades it to a **no-op**, which is the
  correct failure — the page renders stock, nothing is mangled. Two page properties still shape
  it: the grid is **JS-virtualised** — tile geometry *and* thumbnail request sizes derive from the
  measured pane width — so the CSS must be followed by a synthetic `resize`, coalesced in one
  `rAF`; and only the pane **wrapper** may ever be shifted, because it is the `position:absolute`
  containing block for the main pane, which sits at `left:0` inside it, so moving both would
  double the offset.

## `infra/` — terranix (Nix → OpenTofu/Terraform JSON)

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
shape/default as `mkNixos` — see [`private-home-modules.md`](private-home-modules.md)); the
public `cfTunnelConfig`/`cf-tunnel-apply`/`cf-tunnel-destroy` flake apps pass none, rendering
an ingress with zero sites, while the private nix-personal flake calls `lib.cfTunnelConfig`
directly with the real site list. Applied/destroyed via the `cf-tunnel-apply`/`cf-tunnel-destroy`
flake apps (an API credential must be exported first — never in Nix); `cf-tunnel-apply` prints
the token to stdout to be stored via `nix run .#nixpi-vault-token` into
`secrets/cloudflared-token.age`, never written to git/store in plaintext.

### `infra/hyperframes/stack.nix`

See [`hyperframes-selfhost.md`](hyperframes-selfhost.md).

### The Vast.ai GPU-template provisioning subsystem

The **`vast-provision` flake input** (`github:kattakath/nix-vast-provision`, EXTRACTED FROM
THIS REPO — phase 2 of the extraction, phase 1 backported local-only features upstream first)
plus the locally-vendored `packages/vast-bootstrap.sh` and
`packages/templates/provisioner/provision-lib.sh`.

**Off-fleet control plane** darwin flake apps (parallel to the Cloudflare `cf-tunnel-*` apps —
the tooling runs on the Mac, it provisions external x86_64 cloud GPUs; **Vast is NOT a fleet
host**). The CLI *logic* —

- `vast-template-apply` (create/REPLACE a template by name — delete+create, since Vast's PUT is
  broken),
- `vast-repo-check` (validate a provisioner repo's `.provisioner-template.json` marker),
- `vast-account-vars-set` (sync read-only `VAST_*` Keychain tokens → Vast account env vars),
- `vast-ssh-key-set` (register the operator SSH key on the Vast account),
- `vast-init-repo` (scaffold a provisioner repo — now from the extracted flake's own baked
  scaffold),
- `vast-rent` (rents a live, **BILLED** GPU instance from a template by name/hash — the one
  command in the kit that spends real money)

— is `callPackage`d straight from the input's store path
(`"${vast-provision}/packages/vast-provision.nix"` in `flake.nix`), with
`orgName`/`repoName`/`rev` OVERRIDDEN to nix-config's own identity: dogfooding, but the raw-URL
construction must still point HERE, since a live Vast instance fetches
`packages/vast-bootstrap.sh` and `packages/templates/provisioner/provision-lib.sh` over raw
HTTP from THIS repo at boot (`PROVISIONING_SCRIPT`/`PROVISION_LIB_URL`) — both stay vendored
here for that reason, and `checks.<system>.vast-lib-drift` diffs them against the input's own
copies so the two can never silently diverge.

No stack-specific manifest content (a concrete ComfyUI workflow, etc.) is ever vendored in this
public repo — that belongs in a private aggregator repo
(`--repo gitlab:... --workflow-name NAME`), never committed here. Templates use `runtype=args` + `OPEN_BUTTON_PORT` +
`PORTAL_CONFIG` on `vastai/base-image`; instances boot `PROVISIONING_SCRIPT` → the raw-URL
`vast-bootstrap.sh` (pinned to this flake's rev) → clone a private provisioner repo → run its
self-contained `provision.sh` (e.g. a ComfyUI stack). Secrets never touch the template — they
are Vast account-level env vars. See
[`vastai-template-provisioning.md`](vastai-template-provisioning.md).

## Claude Code surface

MCP servers have their own doc: [`mcp-gateway.md`](mcp-gateway.md).

### `.claude/commands/`

| Command | What it does |
|---|---|
| `/eval` | stage + `nix flake check` |
| `/hygiene` | LEAN/DRY audit→fix→gate via skill `nix-hygiene` |
| `/update-input` | bump one flake input + commit the lock |
| `/superhook-review` | triage the hook-supervisor log |
| `/pretooluse-review` | triage the `PreToolUse`/`Write\|Edit` prompt-hook attempt/outcome log written by `pretooluse-log.js`, since those hooks have no logging of their own |
| `/remember-nix` | capture into project memory |
| `/vpn` | operate WireGuard via the fleet `vpn` CLI — macvm-only, see [`wireguard-vpn.md`](wireguard-vpn.md) |
| `/gmail-account` | add/authenticate/remove a Gmail MCP multi-account, see [`gmail-mcp-multi-account-runbook.md`](gmail-mcp-multi-account-runbook.md) |
| `/routing-review` | triage Claude Code's own OTel tool-decision log for deterministic-routing hardening candidates, see [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md) |
| `/mcp-scout` | discover → vet → DECLARATIVELY adopt an MCP server into the gateway via skill `mcp-scout`; imperative installer CLIs / config-writing install tools are never used |
| `/userscript` | measure → replay → declare → gate a Violentmonkey userscript via skill `userscript-author`; **no selector ships that was not dumped from the live page**, and `@require`/`@resource` CDN deps are never used |
| `/fleet-doctor` | fleet-wide consistency sweep (branches/worktrees/PRs/CI/cross-repo pins/GC/host re-activation) across every repo in `.claude/skills/fleet-doctor/fleet-repos.txt`, via skill `fleet-doctor`; composes `nix-hygiene`, `git-purity.md`, `pr-title.md` |

### `.claude/rules/` — always applied

- [`git-purity.md`](../.claude/rules/git-purity.md) — stage `.nix` files before eval.
- [`pr-title.md`](../.claude/rules/pr-title.md) — a PR title is the comma-separated list of the
  components the change touches (first-level `nix flake show` output category for flake outputs,
  or a top-level dot-folder with its dot stripped). Also states the default shape: **one PR per
  change, branched off `main`** — the merge queue serializes them, so PRs are independent (the
  old "one open PR per working session" consolidation policy was retired 2026-08-30).
- [`launchd-naming.md`](../.claude/rules/launchd-naming.md) — every launchd unit this repo
  authors must expose a `nix-<kebab>` `arg0` basename (never a bare `sh`/`python3`); documents
  the known upstream `/bin/sh` exceptions (`org.nixos.activate-system`,
  `org.nixos.activate-agenix`, `systems.determinate.nix-installer.nix-hook`) that are NOT ours
  and must not be renamed.

### `.claude/hooks/`

- **`stop-gate.js`** — Stop gate: blocks until configs evaluate clean.
- **`pretooluse-bash-guard.js`** — `PreToolUse:Bash`: deterministic port of the
  Cloudflare-API-call / Cloudflare-docs / desktop-commander-nudge / approved-CLI policy that
  used to live as a `type: "prompt"` LLM-judged hook; see the file header for the 2026-08-19
  incident that motivated the switch.
- Both are wrapped by **`superhook.js`** (crash-safety + loop-breaking + logging — the sole
  supervisor for command-type decision hooks). It structurally CANNOT wrap `type: "prompt"`
  hooks, which is why the remaining `Write|Edit` secret-detection gate in
  `.claude/settings.json` stays unsupervised prompt-based — that one is a genuine semantic
  judgment call, unlike the Bash gate's mostly-syntactic rules.
- **`superhook-digest.js`** — SessionStart digest of supervisor findings.
- **`routing-review-digest.js`** — SessionStart nudge for unreviewed
  `user_temporary`/`user_permanent` Claude Code routing decisions; mirrors
  `superhook-digest.js` exactly, threshold-gated, see
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`fleet-doctor-digest.js`** — SessionStart nudge when `/fleet-doctor` hasn't run in a while;
  reads only a local timestamp, no network/git calls, so it stays fast on every session start.
- **`memory-loader.js`** — SessionStart context surfacing.
- **`autostage-nix.js`** — PostToolUse git-purity net.
- **`nix-home-path-lint.js`** — PostToolUse, `.nix` only: flags a hardcoded
  `/Users/<name>/`/`/home/<name>/` runtime-path VALUE per the "Paths — two axes" convention —
  advisory, not a hard gate.
- **`pretooluse-log.js`** — PreToolUse+PostToolUse observer for `Bash`/`Write|Edit`; logs
  attempt/executed pairs to `.claude/hooks/pretooluse.log` for `/pretooluse-review`; never
  influences the decision.

Decoder for what these hooks print: [`claude-hook-messages.md`](claude-hook-messages.md).

### `.claude/skills/` — project skills

Active only when working in this repo: `nix-hygiene`, `nixpi-firmware-provision`, `macvm-tart`,
`vast-instance-log-tail`, `jsonresume-tailor`, `wireguard-vpn`, `gmail-mcp-accounts`,
`mcp-scout`, `userscript-author` (its `probes.md` + `patterns.md` flat siblings are the
measurement instruments and the pre-vetted reuse ladder — see § `userscripts/`),
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

A small exception is **vendored in-repo**: the top-level `skills/` directory holds skills wired
into the same `programs.claude-code.skills` option alongside the flake-input-sourced ones —
forks of upstream skills that needed a local patch (`skills/brag`, `skills/brags-review`,
`skills/rag` — see `skills/brag/FORK-NOTES.md` for the vendoring rationale) plus originals
authored here:

- **`skills/android-phone`** — operator knowledge for `packages/android-phone.nix`, global so
  ADB sessions launched from ANY directory know the wrapper's command surface and adb
  footguns, not just sessions rooted in this repo.
- **`skills/nix-dev-toolkit`** — how to make *another* repo self-sufficient with Nix: a
  working `flake.nix` template + `.envrc` (`assets/`), the env-catalogue pattern, a
  project-local Postgres+pgvector stack, and `nix run .#<verb>` lifecycle apps
  (`references/`). Global precisely because the point is to apply it to a repo that does
  **not** have it yet — its `stack-up`/`deploy-prod`/`env-doctor` app names are the
  template's, **not** flake apps of this repo. Carries the Nix/Postgres/Prisma traps
  (`withPackages` union prefix, socket port, the macOS socket-length cap).

### `plugins/`

This repo's OWN Claude Code plugin marketplace (`kattakath-nix-config`), the third alongside
`xai-grok-build` (pinned flake input) and `claude-plugins-official` (HTTPS).
`plugins/.claude-plugin/marketplace.json` lists each in-repo plugin; `modules/shared/home.nix`
pins it as a **Nix source path** (`localPluginsMarketplace = "${../../plugins}"`) and installs
its ids via the same `claudePluginIds` + `home.activation.claudeCodePlugins` path as every
other plugin. Because it is a source path, the store path changes whenever plugin content
changes — activation keys the marketplace re-pin (and a reinstall of the copies under
`~/.claude/plugins/cache`) off exactly that, so an in-repo plugin can never serve a previous
generation's content.

Today, three:

- **`plugins/llmstxt`** — `llms.txt` authoring skill + `/llmstxt` command + a stdlib-only spec
  linter; see `plugins/llmstxt/README.md`.
- **`plugins/seargraph`** — the `seargraph-langgraph` **subagent** (LangGraph pipeline
  design/implementation for the SEARGraph project: fidelity metrics, constrained optimization,
  iterative refinement, character embeddings). It is a plugin rather than a vendored skill for
  one structural reason: `programs.claude-code.skills` has no `agents/` capability — only a
  plugin can ship a subagent.
Adding one = a `plugins/<name>/` tree with `.claude-plugin/plugin.json` + a `marketplace.json`
entry + its id in `claudePluginIds`; validate with `claude plugin validate --strict`. A
**skill** that needs no command/hook/MCP/agent surface still belongs in top-level `skills/` —
reach for a plugin only when the unit is more than a skill.

### `memory/`

**Gitignored** project memory (decisions/findings/values/evolution): the candid "why" behind
the repo, surfaced each session by `memory-loader.js`. Never `git add`.

## CI, release, publishing

`.github/workflows/nix-ci.yml` — 2-leg Nix CI on GitHub Actions, ALL on GitHub-**HOSTED**
runners (`ubuntu-24.04-arm` for aarch64-linux — evaluates `nixpi`+`nixvm`; `macos-latest` for
aarch64-darwin — evaluates `macos`; both free & unlimited on public repos). Each leg *builds*
the lint/format/structural `checks` — `formatting`, `pre-commit`, `vast-lib-drift`, `ast-grep`,
`deploy-schema` — with `nix-fast-build` (it globs `.#checks.<system>`, so a NEW check needs no workflow edit;
pushed to the `kattakath` Cachix cache) and
*evaluates* (no build) its host config toplevel(s). Building host toplevels is deferred to
release time (`build-installers`, also hosted).

**No workflow in this repo targets a self-hosted runner** — every leg is GitHub-hosted (fork
PRs need no runner fallback), and day-to-day local aarch64-linux builds use Determinate's
native Linux builder on the Mac. Branch protection requires the aggregate `required-checks`
job.

Do **not** read that as "the Mac has no runners": `macos` does host two ephemeral self-hosted
runners, registered to the **`dontsell-ai`** org, for *that* org's CI — see
`modules/darwin/github-runner.nix` above. The two facts are about different repos.

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
