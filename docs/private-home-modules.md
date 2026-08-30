# Private home-manager modules — composition contract

This public flake is the **fleet engine**. Personal or sensitive home-manager
stacks (anything you do not want in a public tree) live in a **separate private
flake** and plug in through a fixed contract — the same boundary as Vast
provisioner repos (`provision.sh` + marker) vs this repo's generic
`vast-template-apply`.

## Boundary

| Layer | Lives where | Contains |
|---|---|---|
| **Engine** | `github:kattakath/nix-config` (public) | hosts, shared profile, `lib.mkDarwin` / `lib.mkHomeManagerModule` / `lib.mkNixos` / `lib.cfTunnelConfig` |
| **Private stack** | your private forge (GitLab/GitHub) | home-manager modules, real hosted-site content, and dontsell.ai's bespoke tunnel — only you should see these |
| **Contract (darwin)** | `extraHomeModules` on `lib.mkDarwin` | list of HM modules; public hosts pass `[]` |
| **Contract (nixpi)** | `hostedSites` + `extraModules` on `lib.mkNixos` | real site list (`{ domain; zoneId ? null; root; www ? true; ownTunnel ? false }`) + any bespoke modules (e.g. dontsell.ai's second tunnel connector); public `nixosConfigurations.nixpi` passes neither, defaulting to `[]`/no extras |

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
2. Export `homeManagerModules.*` and `darwinConfigurations.macos` / `macvm` that call
   `nix-config.lib.mkDarwin { extraHomeModules = [ … ]; }` — no `identity` override
   needed for either host; both inherit the global `identityArgs` (`ismail`).
3. Prefer `git+ssh://…` flake URLs so credentials never appear in `flake.lock` URLs.
4. Pin `nix-config` by revision in the private `flake.lock` (same discipline as other inputs).
5. When the private stack grows, keep **one** private composition flake (or a small
   set of `homeManagerModules.*` attrs) — do not re-open a public PR for personal
   modules.

### Day-to-day activate (with private modules)

```bash
# macos (private #macos app escalates and sets root HOME)
nix run ~/Developer/gitlab.com/ismailkattakath/nix-personal#macos

# macvm (from the host) — guest usually has no GitLab SSH, so sync the private
# clone then activate the path flake:
NP=~/Developer/gitlab.com/ismailkattakath/nix-personal
CFG=~/Developer/github.com/kattakath/nix-config
tar -C "$NP" --exclude result --exclude .direnv -cf - . |
  nix run "$CFG#macvm-tart-ssh" -- 'mkdir -p ~/nix-personal && tar -C ~/nix-personal -xf -'
nix run "$CFG#macvm-tart-ssh" -- nix run /Users/ismail/nix-personal#macvm
```

Fleet-only (no private modules): `github:kattakath/nix-config#macos` / `#macvm`.

## Analogy to Vast provisioners

| Vast | Private home modules | Private hosted sites (nixpi) |
|---|---|---|
| Public bootstrap / `vast-*` apps in this repo | Public `lib.mkDarwin` + `extraHomeModules` | Public `lib.mkNixos` + `hostedSites`/`extraModules` |
| Private `owner/stack` repo with `provision.sh` | Private flake with HM modules | Private flake's `sites/` + `modules/nixpi-dontsell-tunnel.nix` |
| Template holds no secrets | Public tree holds no private module URLs | Public tree holds no real zoneIds / site content |
| Activate instance via Vast | Activate Mac via private flake `#macos` | Activate nixpi via private flake `#nixpi` (remote switch) |

## WireGuard (and other private *files*)

Private **keys / `.conf` bodies** should not use `home.file.source = ./secret.conf`
even in a private flake — Nix copies them into the **world-readable store**.

Prefer:

1. Operator plant directory outside git (this fleet: `~/.local/share/wireguard-configs`
   → HM activation sync to `~/.config/wireguard` via `local.wireguardConfigs` in the
   public engine — confs never evaluated as Nix paths).
2. Or a private flake that only ships the *module* and still `cp`s from a host-local
   path at activation.

See `docs/macvm-tart-runbook.md` (WireGuard section).

## What this is not

- Not an in-tree `private/` directory (that is still a public git trace).
- Not a flake input on this public flake (that would leak the private repo name into
  `flake.lock` for every clone/CI job).
- Not required for the fleet's *baseline*: a clean Mac bootstrap and the CI-published
  nixpi sdImage both stay on public `#macos` / `#nixpi` alone — Caddy runs with zero
  vhosts, no dontsell tunnel, no personal HM modules. The real production nixpi (4
  live sites + dontsell.ai) and a Mac with personal modules both require activating
  from the private nix-personal flake instead.
