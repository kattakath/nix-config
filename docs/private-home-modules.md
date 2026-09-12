# Private home-manager modules — composition contract

This public flake is the **fleet engine**. Personal or sensitive home-manager
stacks (anything you do not want in a public tree) live in a **separate private
flake** and plug in through a fixed contract.

## Boundary

| Layer | Lives where | Contains |
|---|---|---|
| **Engine** | `github:kattakath/nix-config` (public) | hosts, shared profile, `lib.mkDarwin` / `lib.mkHomeManagerModule` / `lib.mkNixos` / `lib.cfTunnelConfig` |
| **Private stack** | your private forge (GitLab/GitHub) | home-manager modules, real hosted-site content, and dontsell.ai's bespoke tunnel — only you should see these |
| **Contract (darwin)** | `extraHomeModules` on `lib.mkDarwin` | list of HM modules; public hosts pass `[]` |
| **Contract (nixpi)** | `hostedSites` + `extraModules` on `lib.mkNixos` | real site list (`{ domain; zoneId ? null; root; www ? true; ownTunnel ? false }`) + any bespoke modules; public `nixosConfigurations.nixpi` passes neither, defaulting to `[]`/no extras |

**No private stack is referenced from this repository** — not as a flake input, not
as a path, not as a URL. The public `flake.lock` never locks a private repo. This
also means nixpi's own `hostedSites` content (site HTML/assets, real Cloudflare
zone ids for `kattakath.com`, `snoringirl.com`, `ismail.kattakath.com`, and
`dontsell.ai`'s tunnel) now lives **only** in the private nix-personal composition
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

### nixpi (real sites + dontsell.ai's tunnel)

Same contract, `lib.mkNixos` instead of `lib.mkDarwin`:

```nix
# private flake (illustrative)
nixosConfigurations.nixpi = nix-config.lib.mkNixos {
  system = "aarch64-linux";
  hostname = "nixpi";
  hostedSites = [
    { domain = "kattakath.com"; zoneId = "…"; root = ./sites/landing; }
    # … snoringirl.com, ismail.kattakath.com …
    { domain = "dontsell.ai"; root = ./sites/dontsell-landing; ownTunnel = true; }
  ];
  extraModules = [
    raspberry-pi-nix.nixosModules.raspberry-pi
    raspberry-pi-nix.nixosModules.sd-image
    ./modules/nixpi-dontsell-tunnel.nix # dontsell.ai's own connector — see below
  ];
};
```

`ownTunnel = true` is a **shape marker only** — `hostedSites` never triggers
tunnel-provisioning code on its own. A site whose zone lives in a different
Cloudflare account (dontsell.ai's DontSell account vs. the primary Personal
account) needs its own `cloudflared` connector, since a `cfargotunnel.com`
CNAME only resolves within the same account as the tunnel. That bespoke unit
is hand-written (`services.cloudflared-connector` is a singleton, so a second
tunnel can't reuse its option surface) and travels via `extraModules`, not a
generic loop over `hostedSites` — see nix-personal's
`modules/nixpi-dontsell-tunnel.nix` for the exact unit + firmware-file entry
(moved here wholesale from what used to be hardcoded in this repo's
`hosts/nixpi.nix`).

Deploy nixpi from the private flake (build locally, switch remotely — nixpi has
no local build capacity and is reached only via the Cloudflare Tunnel's SSH
ingress):

```bash
nixos-rebuild switch --flake ~/path/to/private#nixpi --target-host ismail@nixpi.kattakath.com
```

**Preferred: deploy-rs with magic rollback.** `nixos-rebuild --target-host` has no
undo — a generation that breaks sshd, the tunnel connector, or networking leaves
the Pi simply *gone*, recoverable only by pulling the SD card and reflashing
(`docs/nixpi-sd-flashing-runbook.md`, ~40 min). The public engine therefore
exports a `deploy.nodes.nixpi` (`magicRollback`/`autoRollback` on, `remoteBuild`
off) and the private flake is its **intended caller** — re-export the node against
*your* `nixosConfigurations.nixpi` so the rollback semantics, timeouts and ssh
plumbing stay single-sourced in the public tree:

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

One planting gap to know about: this repo's public `nixpi-flash`/`nixpi-provision`
apps (`packages/nixpi-provision.nix`) only plant the **primary** `cloudflared-token`
onto a freshly flashed SD card's FIRMWARE partition. dontsell.ai's second token
(`cloudflared-token-dontsell`) needs its own plant step — currently manual (`cp`
onto the mounted FIRMWARE partition) — until/unless nix-personal automates it.

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

`programs.ungoogledChromium.userScripts.scripts` (public engine,
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

## Bedrock identity — an option seam, values only

`local.claudeBedrock.{region,profile}` (public engine,
`modules/shared/claude-bedrock-gate.nix`) is the same **option seam** shape as
`local.wireguardConfigs`: the public repo owns the mechanism — the declarations, the
`~/.claude/settings.json` `env` writing, and the runtime `nix-bedrock-gate` — and
nix-personal's `modules/claude-bedrock.nix` is reduced to the two values.

- **Both default to `null`, and that is load-bearing.** The gate's first detector is
  "AWS_REGION resolves nowhere → the private layer is not active". A non-null public
  default turns it permanently green on a public-only activation and reproduces the exact
  outage the gate exists to prevent. Never give them a value in nix-config.
- **Overridable, not extendable — deliberately.** One AWS identity per host, so a `listOf`
  would misdescribe the shape, and two differing definitions *should* be a loud conflict.
  No `mkDefault` is needed: an option `default` is not a definition, so the private layer's
  plain assignment wins outright. Extensibility is not lost downstream — the sink
  `programs.claude-code.settings.env` is a recursive attrs type, so any module may still
  add other env keys.
- **The on/off switch is not in this seam at all.** `CLAUDE_CODE_USE_BEDROCK` lives in the
  macOS login Keychain, because a Nix-declared `env` entry would apply to every session and
  destroy the runtime toggle. There is deliberately no `local.claudeBedrock.enable`.

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
  vhosts, no dontsell tunnel, no personal HM modules. The real production nixpi (4
  live sites + dontsell.ai) and a Mac with personal modules both require activating
  from the private nix-personal flake instead.
