# Private home-manager modules — composition contract

This public flake is the **fleet engine**. Personal or sensitive home-manager
stacks (anything you do not want in a public tree) live in a **separate private
flake** and plug in through a fixed contract.

## Boundary

| Layer | Lives where | Contains |
|---|---|---|
| **Engine** | `github:kattakath/nix-config` (public) | hosts, shared profile, `lib.mkDarwin` / `lib.mkHomeManagerModule` / `lib.mkNixos` / `lib.cfTunnelConfig` |
| **Private stack** | your private forge (GitLab/GitHub) | home-manager modules and real hosted-site content — only you should see these |
| **Contract (darwin)** | `extraHomeModules` on `lib.mkDarwin` | list of HM modules; public hosts pass `[]` |
| **Contract (nixpi)** | `hostedSites` + `extraModules` on `lib.mkNixos` | real site list (`{ domain; zoneId ? null; root; www ? true; ownTunnel ? false }`) + any bespoke modules; public `nixosConfigurations.nixpi` passes neither, defaulting to `[]`/no extras |

**No private stack is referenced from this repository** — not as a flake input, not
as a path, not as a URL. The public `flake.lock` never locks a private repo. This
also means nixpi's own `hostedSites` content (site HTML/assets, real Cloudflare
zone ids) now lives **only** in the private nix-personal composition
flake — see `nixosConfigurations.nixpi` below.

## Contract

1. Private flake depends on **this** flake as an input (not the other way around).
2. Private flake rebuilds the host via the exported builder:

   ```nix
   # private flake (illustrative)
   {
     inputs.nix-config.url = "github:kattakath/nix-config";

     outputs =
       { self, nix-config, ... }:
       {
         homeManagerModules.default = ./modules/my-private.nix;

         darwinConfigurations.macos = nix-config.lib.mkDarwin {
           system = "aarch64-darwin";
           hostname = "macos";
           # Optional: identity override, extraModules, …
           extraHomeModules = [
             self.homeManagerModules.default
           ];
         };
       };
   }
   ```

3. Activate **from the private flake** (not from public `.#macos` when you need the
   private modules):

   ```bash
   # SSH (preferred — no token in the URL)
   darwin-rebuild switch --flake 'git+ssh://git@gitlab.com/<you>/<private>.git#macos'

   # or a local clone
   darwin-rebuild switch --flake ~/path/to/private#macos
   ```

4. Public `darwin-rebuild switch --flake github:kattakath/nix-config#macos` remains
   the **fleet-only** path (no private modules).

## Shape and values — the tier contract

The operator's rule, adopted 2026-09-13 and enforced since: **the private flake must not
contribute to the shape of config at all — it extends only.** Shape is determined here,
generically; public-safe specifics also live here; only discreet specifics live privately.

| Tier | Owns | Lives |
|---|---|---|
| **1. Shape** | option declarations, module mechanisms, composition builders, activation logic, CLIs, package definitions | here, public |
| **2. Public values** | concrete settings that are fine in the open (defaults, fleet hostnames, this repo's own URL) | here, public |
| **3. Discreet values** | the same *kind* of settings, for things that should not be public (personal sites, org accounts, zone ids) | private flake |

**The falsifiable form:** delete the private flake entirely and this repo must still
evaluate, build and activate a coherent (if less personalised) system. Verified 2026-09-13:
`nix build .#darwinConfigurations.macos.system` succeeds standalone. Every break under that
test is a shape leak.

### The mechanical test

A file in the private flake is SHAPE (and must move here) if it declares an option, defines
a package/app/CLI/derivation, contains activation or ordering logic, decides structure (a
format, a schema, a registry layout), or is the only place a behaviour is described. It is
VALUES (and may stay) if it only sets an option declared here, adds a key/element to an
`attrsOf`/`listOf` owned here, supplies a literal, or passes `extraHomeModules` /
`extraModules` / parameters into a builder exported here.

Two deliberate refinements, both judged rather than mechanical:

- **Private applications are content, not config shape.** A personal tool whose very domain
  is discreet cannot move here without defeating the point; it plugs into the public
  `home.packages` seam like any other value. The contract governs configuration structure,
  not the visibility of every program the operator runs.
- **Trivial glue is values-adjacent.** A private `checks.*` that wraps a public rulebook
  around a private input in a few policy-free lines stays private, because a public check
  structurally cannot read a private input. The rulebook must still come from here — one
  rulebook, two gates, one per visibility.

### Worked seams, in increasing size

| Seam | Shape (here) | Values (private) |
|---|---|---|
| plugin marketplace | `local.claudePlugins.marketplaces` (attrsOf) + install mechanism | one added key |
| RAG domain table | `local.rag.pgvector.extraSql` + the pgvector stack | one private table |
| page-lab site register | alias format + per-alias stack descriptions, in the plugin | alias→host file via `home.file` |
| activation CLI | `lib.mkActivateCli` → `packages/activate.nix` (moved here 2026-09-13) | two checkout paths |
| remote NixOS switch | `lib.mkRemoteNixosSwitchApp` (moved here 2026-09-13) | flake, hostname, remote |
| hosts | `lib.mkDarwin` / `lib.mkNixos` | `extraHomeModules`, `hostedSites` |

### Adding a private value without contributing shape

1. Find or declare the public option/parameter **here** first — generic, defaulted, documented.
2. Set it in the private flake with values only; the module carries a header saying which
   public seam it fills and why the value is discreet.
3. Prove removability: the standalone system build above must still pass without it.

### nixpi (real sites)

Same contract, `lib.mkNixos` instead of `lib.mkDarwin`:

```nix
# private flake (illustrative)
nixosConfigurations.nixpi = nix-config.lib.mkNixos {
  system = "aarch64-linux";
  hostname = "nixpi";
  hostedSites = [
    { domain = "snoringirl.com"; zoneId = "…"; root = ./sites/snoringirl; }
    # a subdomain of the apex zone, so no www vhost/redirect:
    { domain = "ismail.kattakath.com"; zoneId = "…"; root = ./sites/ismail-landing; www = false; }
  ];
  extraModules = [
    raspberry-pi-nix.nixosModules.raspberry-pi
    raspberry-pi-nix.nixosModules.sd-image
  ];
};
```

**Removing a site from this list is an OUTWARD, ORDERED change — never a tidy-up.**
Measured 2026-09-12: `ismail.kattakath.com` was dropped from `hostedSites` as collateral in an
unrelated commit, and nothing failed — the site stayed up, because nixpi's *running generation*
and the cf-tunnel OpenTofu state both predated the drop. Config said gone, production said
serving, and they were one command apart from diverging in two different directions: the next
nixpi deploy would have dropped the Caddy vhost while Cloudflare kept routing (**502**), and the
next `cf-tunnel-apply` would have deleted the DNS record outright (**NXDOMAIN**). The site-free
guard catches neither — it refuses only at ≤2 ingress entries, and that render had three. The
entry was **restored 2026-09-14**, config catching up to production. The rule: retire a site by
standing up the new origin first, cutting DNS over, and only then removing the line — with the
`tofu` apply **last**.

`ownTunnel = true` is a **shape marker only** — `hostedSites` never triggers
tunnel-provisioning code on its own. A site whose zone lives in a different
Cloudflare account (dontsell.ai's DontSell account vs. the primary Personal
account) needs its own `cloudflared` connector, since a `cfargotunnel.com`
CNAME only resolves within the same account as the tunnel. That bespoke unit
is hand-written (`local.cloudflaredConnector` is a singleton, so a second
tunnel can't reuse its option surface) and travels via `extraModules`, not a
generic loop over `hostedSites`. **No site uses it today** — dontsell.ai was
the only one, and it left nixpi on 2026-09-06 when its apex moved to Vercel;
its connector module and, on 2026-09-14, its terranix zone module were both
deleted. The marker stays because the engine still honours it; for the exact shape
of such a unit (systemd service + its firmware-file token entry), recover
nix-personal's `modules/nixpi-dontsell-tunnel.nix` from git history — it was itself
moved there wholesale from what used to be hardcoded in this repo's `hosts/nixpi.nix`.

Deploy nixpi from the private flake (build locally, switch remotely — nixpi has
no local build capacity and is reached only via the Cloudflare Tunnel's SSH
ingress):

```bash
nixos-rebuild switch --flake ~/path/to/private#nixpi --target-host ismail@nixpi.kattakath.com
```

**Preferred in principle: deploy-rs with magic rollback.** `nixos-rebuild --target-host`
has no undo — a generation that breaks sshd, the tunnel connector, or networking leaves
the Pi simply *gone*, recoverable only by pulling the SD card and reflashing
(`docs/nixpi-sd-flashing-runbook.md`, ~40 min). The public engine therefore
exports a `deploy.nodes.nixpi` (`magicRollback`/`autoRollback` on, `remoteBuild`
off) and a private flake is its **intended caller** — re-export the node against
*your* `nixosConfigurations.nixpi` so the rollback semantics, timeouts and ssh
plumbing stay single-sourced in the public tree:

> **What nix-personal actually runs today (2026-09-13):** it does **not** re-export the
> node. With `remoteBuild` off, deploy-rs builds the Pi closure on the Mac, and nixpkgs'
> caddy `Caddyfile-formatted` derivation EPERMs on Determinate's native Linux builder
> (`repo-map.md` § `hosts/`), so its `nix run .#nixpi` is a
> `nixos-rebuild switch --target-host … --build-host nixpi` — built ON the Pi, **no magic
> rollback**. The snippet below is the target shape once the closure builds off-Pi again.

```nix
# private flake — reuse the public node's settings, swap the target config
deploy.nodes.nixpi = nix-config.deploy.nodes.nixpi // {
  profiles.system = nix-config.deploy.nodes.nixpi.profiles.system // {
    path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.nixpi;
  };
};
# For the schema check, copy the public tree's `deployChecksFor` (aarch64-only, and it
# strips string context off `profiles.*.path`) rather than the README's
# `mapAttrs … deploy-rs.lib`, which emits x86_64 checks and build-depends on the Pi's
# whole closure.
```

```bash
deploy --targets ~/path/to/private#nixpi              # magic rollback armed
deploy --targets ~/path/to/private#nixpi --dry-activate  # rehearse first
```

`deploy` with **no** `--targets` fans out over every node — always name the target.
And never `deploy --targets github:kattakath/nix-config#nixpi`: that node points at
the site-free public config, so a *successful* deploy takes all four sites down.
Magic rollback will not catch it (it reverts an **unreachable** host; a site-free Pi
is reachable).

Reaching `nixpi.kattakath.com` needs a Cloudflare Access SSH proxy (it's a
tunnelled hostname, not directly reachable). The public engine now declares this:
`modules/shared/home.nix` ships a `Host nixpi.kattakath.com` block with
`ProxyCommand <store-path>/bin/cloudflared access ssh --hostname %h`, so plain
`ssh`, `nixos-rebuild --target-host`, and both deploy-rs legs (`ssh` for activation,
`nix copy` for the closure) all just work after activation — no hand-edit, which was
never possible anyway since `~/.ssh/config` is a read-only `/nix/store` symlink.
Do **not** try to pass the ProxyCommand through deploy-rs' `sshOpts`: deploy-rs
space-joins them into `NIX_SSHOPTS` and nix re-splits on whitespace, mangling it for
the copy leg. `NIX_SSHOPTS="-F <config>"` remains the one-off escape hatch.

**This depends on a Cloudflare Zero Trust *Access Application* existing for
`nixpi.kattakath.com`** (Zero Trust → Access → Applications) — a real Cloudflare
resource, separate from the tunnel's ingress rule that routes the hostname to
`ssh://localhost:22`. `infra/cloudflare/nixpi-tunnel.nix` (terranix) manages the
tunnel/ingress/DNS declaratively but does **not** manage this Access
Application — it was created by hand, once, outside Nix, and on 2026-08-20 it
was found **missing entirely** (`cloudflared access ssh` failed with `failed to
find Access application`, while the public sites on the same tunnel kept
serving fine — DNS/tunnel/Caddy health doesn't imply this exists). Likely lost
during an earlier tunnel/ingress change. If this happens again: Zero Trust →
Access → Applications → Create → type `Self-hosted`, domain
`nixpi.kattakath.com`, reuse the existing `mcp-allow-operator` policy (`email
== ismail@kattakath.com`) rather than creating a new one. Worth eventually
modeling as a real `cloudflare_zero_trust_access_application` resource in the
terranix module so this can't silently disappear again — not done yet.

**Do not** pass
`--build-host localhost` — nixos-rebuild treats `--build-host` as a host to
`ssh` into unconditionally, even the literal string `localhost`, and macos runs
no local sshd by design. Per `nixos-rebuild --help`: *"If --build-host is not
explicitly specified or empty, building will take place locally"* — omitting
the flag is exactly what you want.

A planting gap that used to matter here is now closed: this repo's public
`nixpi-flash`/`nixpi-provision` apps (`packages/nixpi-provision.nix`) plant only the
**primary** `cloudflared-token` onto a freshly flashed SD card's FIRMWARE partition.
The only second token that ever needed a manual plant was dontsell.ai's, and that
tunnel is retired — so one token is now the whole story.

## Ops checklist

1. Create a **private** repo on GitLab (or GitHub); do not put personal modules here.
   This fleet’s private composition flake is **`gitlab.com/ismailkattakath/nix-personal`**
   (never a flake input of the public tree — activate *from* that repo).
2. Export `homeManagerModules.*` and `darwinConfigurations.macos` that call
   `nix-config.lib.mkDarwin { extraHomeModules = [ … ]; }` — no `identity` override
   needed; the host inherits the global `identityArgs` (`ismail`). (While the `macvm`
   guest existed — removed 2026-09-05 — the private flake declared a matching
   `darwinConfigurations.macvm` the same way.)
3. Prefer `git+ssh://…` flake URLs so credentials never appear in `flake.lock` URLs.
4. Pin `nix-config` by revision in the private `flake.lock` (same discipline as other inputs).
5. When the private stack grows, keep **one** private composition flake (or a small
   set of `homeManagerModules.*` attrs) — do not re-open a public PR for personal
   modules.

### Day-to-day activate (with private modules)

```bash
# macos (private #macos app escalates and sets root HOME)
nix run ~/Developer/gitlab.com/ismailkattakath/nix-personal#macos
```

Fleet-only (no private modules): `github:kattakath/nix-config#macos`.

## WireGuard (and other private *files*)

Private **keys / `.conf` bodies** should not use `home.file.source = ./secret.conf`
even in a private flake — Nix copies them into the **world-readable store**.

Prefer:

1. Operator plant directory outside git (this fleet: `~/.local/share/wireguard-configs`
   → HM activation sync to `~/.config/wireguard` via `local.wireguardConfigs` in the
   public engine — confs never evaluated as Nix paths).
2. Or a private flake that only ships the *module* and still `cp`s from a host-local
   path at activation.

## Userscripts — a merged attrset, not a second option

`local.ungoogledChromium.userScripts.scripts` (public engine,
`modules/shared/chromium.nix`) is an **attrset seam** rather than an `extraHomeModules`
parameter: the public repo declares its scripts from `userscripts/`, nix-personal's
`modules/userscripts.nix` adds its own from *its* `userscripts/`, and Home Manager merges
the two. Nothing public names the private repo, and no `mkNixos`-style parameter is needed.

- **Keys must be distinct across the two repos.** A repeated key is an eval **conflict**,
  not an override — which is the desired behaviour: two repos silently fighting over one
  script name would be worse than a failed switch. `lib.mkForce null` on a key is the
  supported way for the private layer to *suppress* a public script.
- **A userscript body is not a private file** in the § WireGuard sense, so
  `source = ./userscripts/foo.user.js` is fine here — but only because it holds no secret.
  The store is world-readable regardless of which flake the path came from, so a userscript
  must never carry a token, cookie, or account identifier.

## Bedrock identity — no longer a seam (deprecated)

`local.claudeBedrock.{region,profile}` (`modules/shared/claude-bedrock-gate.nix`) was an
**option seam** filled by nix-personal's `modules/claude-bedrock.nix`, with `~/.aws/config`
store-symlinked from its `aws-sso.nix`. nix-personal is sunsetting, so the identity left
**every** repo instead of moving into this one:

- **`~/.aws/config` is runtime-owned** by the `aws` CLI (`aws configure sso`). The gate reads
  the active profile's `region` from it and the shell hook exports `AWS_REGION`; select a
  non-default profile with a `[default]` profile or `secret set AWS_PROFILE <name>`.
- **The options stay, deprecated, only so the private layer keeps evaluating** until its last
  activation. A value warns, because it pins `AWS_*` into `settings.json` and overrides the
  file. Never give them a value in nix-config.
- **`adoptAwsConfig` converts the old store symlink into a real file** on the first activation
  where no module declares it, so dropping `aws-sso.nix` cannot delete the profiles.
- **The on/off switch was never in this seam.** `CLAUDE_CODE_USE_BEDROCK` lives in the macOS
  login Keychain, because a Nix-declared `env` entry would apply to every session and destroy
  the runtime toggle. There is deliberately no `local.claudeBedrock.enable`.

## Brain Signals — a seam with nothing private left in it

`programs.claude-code.{outputStyles,agents,commands,rules,skills}` (public engine,
`modules/shared/claude-brain.nix`) is the third seam shape in this document: **upstream's
own merging options, used directly.** No `local.*` option was invented, because none was
needed — every one of those classes is `attrsOf`, so a private layer or a fork ADDS keys
and the public entries survive untouched.

nix-personal's `modules/claude-brain.nix` and its `claude/` tree were **deleted** 2026-09-12
rather than reduced to values: the whole kit is an accessibility calibration, and the same
ADHD/dyslexia answer-shape rule was already public in `claude/CLAUDE.md`. Keeping the
mechanism private meant the rule and the thing that satisfies it could drift with nothing to
catch it, and meant a forker got the rule with no way to meet it.

- **Extendable, and the only two scalars are `mkDefault`.** `settings.outputStyle` and
  `settings.alwaysThinkingEnabled` are single values — a scalar can be replaced, never
  extended — so nix-config sets them with `lib.mkDefault` and a plain assignment downstream
  wins with no `mkForce`. Everything else merges per key.
- **Two ways to destroy this seam, both easy to reach for.** (1) `context` is
  `either lines path` and `home.nix` already defines it as a PATH; a *second* path definition
  is a hard eval error, not a merge — extra global prose must arrive as another
  `rules.<name>`. (2) The `rulesDir`/`agentsDir`/`commandsDir` forms are asserted mutually
  exclusive with their inline twins upstream, and setting `skills` to a bare path collapses
  `either` to `mergeOneOption`. Keep the attrs branch everywhere.

## Claude Code plugins — a keyed attrset, the fourth seam shape

`local.claudePlugins.marketplaces` (public engine, `modules/shared/claude-plugins.nix`) is an
`attrsOf submodule` keyed by marketplace name: the public repo declares its three
(`xai-grok-build`, `claude-plugins-official`, `kattakath-nix-config`) and nix-personal's
`modules/personal-plugins.nix` adds `ismailkattakath-personal`. Same shape as § Userscripts —
a merged attrset, not an `extraHomeModules` parameter.

Before 2026-09-12 nix-personal instead carried a near-verbatim 80-line COPY of the whole
activation script, ordered `entryAfter [ "claudeCodePlugins" ]` so the two would not race on
mutable `~/.claude`. One `attrsOf` option replaced both the copy and the race.

- **Extendable in two dimensions.** Adding a marketplace is a new key; `plugins` is a
  `listOf`, so the private layer can also append a plugin to a marketplace the PUBLIC repo
  declares, without forking its list.
- **`source` is the one scalar, deliberately.** A marketplace has exactly one source, so two
  differing definitions *should* be a loud conflict rather than a silent pick. nix-config
  sets its three with `lib.mkDefault`, so a private layer can still repoint one (a fork of
  the official marketplace, say) with a plain assignment.
- **The path literal must NOT move.** `source = "${../plugins}"` is a Nix source path
  literal, resolved relative to the `.nix` file it is written in. In nix-personal it must
  stay in nix-personal; moved to the public repo it would silently point at *this* repo's
  `plugins/` tree and serve the wrong marketplace under the private name. An assertion in
  the public module rejects anything that is not a `/nix/store` path or an `https://` URL,
  which catches the other half of the trap (`toString ../plugins`, an impure `~/Developer`
  path that pins nothing).
- **The private plugin TREE stays private, on purpose.** Its one plugin teaches
  nix-personal's `activate` CLI, which the public repo does not ship — a public skill for a
  binary that does not exist there is doc drift by construction. Keeping it private also
  keeps the N-marketplace seam exercised on every switch.

## What this is not

- Not an in-tree `private/` directory (that is still a public git trace).
- Not a flake input on this public flake (that would leak the private repo name into
  `flake.lock` for every clone/CI job).
- Not required for the fleet's *baseline*: a clean Mac bootstrap and the CI-published
  nixpi sdImage both stay on public `#macos` / `#nixpi` alone — Caddy runs with zero
  vhosts, no personal HM modules. The real production nixpi (**two** live sites today)
  and a Mac with personal modules both require activating from the private
  nix-personal flake instead.
