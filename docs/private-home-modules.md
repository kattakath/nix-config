# Composition seams — `extraHomeModules` / `hostedSites`, and the nixpi runbook

**History:** this doc used to describe the contract for a separate private
composition flake (`gitlab.com/ismailkattakath/nix-personal`) that supplied
discreet values — real hosted-site content, employer AWS/AI-gateway details,
extra personal identities — through two seams on `lib.mkDarwin`/`lib.mkNixos`.
That flake was **fully retired 2026-09-15**: every value it held is now
folded directly into this repo (`hosts/macos.nix`, `modules/parts/identity.nix`)
as plain public Nix. See ADR-003 §10 for the correction record.

The two seams themselves are unchanged and still real — just currently unused,
since there's no second composition calling into them:

- **`lib.mkDarwin { extraHomeModules }`** — a list of extra home-manager
  modules merged into the Mac's home-manager config (`modules/parts/compose.nix`).
  Public hosts pass none today.
- **`lib.mkNixos { hostedSites }`** — the list of sites `hosts/nixpi.nix`'s
  Caddy serves and `infra/cloudflare/nixpi-tunnel.nix` provisions tunnel
  ingress/DNS for. Shape: `{ domain; zoneId ? null; root; www ? true;
  ownTunnel ? false }` (`root` = a path Caddy `file_server`s). This repo's own
  `modules/parts/hosts.nix` now passes the real list directly via
  `config.fleet.hostedSites` (`modules/parts/identity.nix`).

Either seam would still work for a *second* composition (another host, another
operator) — nothing here requires exactly one caller. The `identity`/`identity
override` and `extraModules` seams on `mkDarwin`/`mkNixos` are the same shape,
for the same reason.

## nixpi's `hostedSites` — the runbook

**Removing a site from this list is an OUTWARD, ORDERED change — never a
tidy-up.** Measured 2026-09-12: `ismail.kattakath.com` was dropped from
`hostedSites` as collateral in an unrelated commit, and nothing failed — the
site stayed up, because nixpi's *running generation* and the cf-tunnel
OpenTofu state both predated the drop. Config said gone, production said
serving, and they were one command apart from diverging in two different
directions: the next nixpi deploy would have dropped the Caddy vhost while
Cloudflare kept routing (**502**), and the next `cf-tunnel-apply` would have
deleted the DNS record outright (**NXDOMAIN**). The site-free guard
(`modules/parts/terranix.nix`) catches neither — it refuses only at ≤2 ingress
entries, and that render had three. The entry was **restored 2026-09-14**,
config catching up to production. The rule: retire a site by standing up the
new origin first, cutting DNS over, and only then removing the line — with the
`tofu` apply **last**.

`ownTunnel = true` is a **shape marker only** — `hostedSites` never triggers
tunnel-provisioning code on its own. A site whose zone lives in a different
Cloudflare account needs its own `cloudflared` connector, since a
`cfargotunnel.com` CNAME only resolves within the same account as the tunnel.
Such a unit is hand-written (`local.cloudflaredConnector` is a singleton, so a
second tunnel can't reuse its option surface) and travels via `extraModules`,
not a generic loop over `hostedSites`. **No site uses it today** —
`dontsell.ai` was the only one, and it left nixpi on 2026-09-06 when its apex
moved to Vercel; its connector module and terranix zone module were both
deleted. The marker stays because the engine still honours it.

Deploy nixpi (build locally, switch remotely — nixpi has no local build
capacity and is reached only via the Cloudflare Tunnel's SSH ingress):

```bash
nixos-rebuild switch --flake .#nixpi --target-host ismail@nixpi.kattakath.com
```

**Preferred in principle: deploy-rs with magic rollback** (`modules/parts/deploy.nix`
exports `deploy.nodes.nixpi`, `magicRollback`/`autoRollback` on, `remoteBuild`
off). `nixos-rebuild --target-host` has no undo — a generation that breaks
sshd, the tunnel connector, or networking leaves the Pi simply *gone*,
recoverable only by pulling the SD card and reflashing
(`docs/nixpi-sd-flashing-runbook.md`, ~40 min).

> **What actually runs today:** with `remoteBuild` off, deploy-rs would build
> the Pi closure on the Mac, and nixpkgs' caddy `Caddyfile-formatted`
> derivation EPERMs on Determinate's native Linux builder
> (`repo-map.md` § `hosts/`) — so the real deploy path is
> `nixos-rebuild switch --build-host nixpi` (built **on** the Pi, **no** magic
> rollback), not the deploy-rs node. The node activates once the Pi closure
> can build off-Pi again (or it grows `remoteBuild = true`).

```bash
deploy --targets .#nixpi              # magic rollback armed, once buildable off-Pi
deploy --targets .#nixpi --dry-activate  # rehearse first
```

`deploy` with **no** `--targets` fans out over every node — always name the
target.

Reaching `nixpi.kattakath.com` needs a Cloudflare Access SSH proxy (it's a
tunnelled hostname, not directly reachable). `modules/shared/home.nix` ships a
`Host nixpi.kattakath.com` block with
`ProxyCommand <store-path>/bin/cloudflared access ssh --hostname %h`, so plain
`ssh`, `nixos-rebuild --target-host`, and both deploy-rs legs (`ssh` for
activation, `nix copy` for the closure) all just work — no hand-edit, which
was never possible anyway since `~/.ssh/config` is a read-only `/nix/store`
symlink. Do **not** try to pass the ProxyCommand through deploy-rs' `sshOpts`:
deploy-rs space-joins them into `NIX_SSHOPTS` and nix re-splits on whitespace,
mangling it for the copy leg. `NIX_SSHOPTS="-F <config>"` remains the one-off
escape hatch.

**This depends on a Cloudflare Zero Trust *Access Application* existing for
`nixpi.kattakath.com`** (Zero Trust → Access → Applications) — a real
Cloudflare resource, separate from the tunnel's ingress rule that routes the
hostname to `ssh://localhost:22`. `infra/cloudflare/nixpi-tunnel.nix`
(terranix) manages the tunnel/ingress/DNS declaratively but does **not**
manage this Access Application — it was created by hand, once, outside Nix,
and on 2026-08-20 it was found **missing entirely** (`cloudflared access ssh`
failed with `failed to find Access application`, while the public sites on
the same tunnel kept serving fine — DNS/tunnel/Caddy health doesn't imply this
exists). Likely lost during an earlier tunnel/ingress change. If this happens
again: Zero Trust → Access → Applications → Create → type `Self-hosted`,
domain `nixpi.kattakath.com`, reuse the existing `mcp-allow-operator` policy
(`email == ismail@kattakath.com`) rather than creating a new one. Worth
eventually modeling as a real `cloudflare_zero_trust_access_application`
resource in the terranix module so this can't silently disappear again — not
done yet.

**Do not** pass `--build-host localhost` — nixos-rebuild treats `--build-host`
as a host to `ssh` into unconditionally, even the literal string `localhost`,
and macos runs no local sshd by design. Per `nixos-rebuild --help`: *"If
--build-host is not explicitly specified or empty, building will take place
locally"* — omitting the flag is exactly what you want.
