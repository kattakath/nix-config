# Re-adding the `macvm` Tart guest

`macvm` (the aarch64-darwin Tart sandbox guest) was **removed from this flake on
2026-09-05** — deliberately, as a thin layer over machinery that survives the
removal, so bringing it back is a bounded, mechanical exercise. This runbook is
the durable re-add path (it survives refactors where a `git revert` would not).

## What survives the removal

| Asset | Where it lives now |
|---|---|
| ALL generic Tart machinery — lifecycle CLI (`tart-vm`), plug-and-play `bootstrap`, packer golden-image `bake`, `tart-guest-agent` packaging, a `tart.vms.<name>` darwin module | [`github:kattakath/nix-tart-vms`](https://github.com/kattakath/nix-tart-vms) (independent repo, FlakeHub-published, CI'd) |
| A baked, operator-neutral **golden image** (`tahoe-golden`) | `~/.tart/vms/` on the macos host (imperative artifact — check `tart list` before assuming) |
| The removed thin layer, verbatim | git history — the removal commit is tagged in the PR that cites this runbook; `git show <removal>^:hosts/macvm.nix` etc. |

## Re-add procedure

1. **Input back** (3 lines in `flake.nix` + `nix flake update nix-tart-vms`;
   lock diet 60 → 61):

   ```nix
   nix-tart-vms.url = "github:kattakath/nix-tart-vms";
   nix-tart-vms.inputs.nixpkgs.follows = "nixpkgs";
   nix-tart-vms.inputs.flake-parts.follows = "flake-parts";
   ```

2. **Host profile back**: restore `hosts/macvm.nix` from the removal commit
   (adjust for drift — e.g. option renames since; it consumed
   `local.folders.downloads` and the guest agent via `mkDarwin` specialArgs)
   and re-register `darwinConfigurations.macvm = mkDarwin { … }` plus the
   `#macvm` activation app.

3. **Veneer back**: restore `packages/macvm-tart.nix` (thin aliases over
   `tart-vm --vm macvm`) + its `packages`/`apps` wiring — or skip the veneer
   and use `nix run github:kattakath/nix-tart-vms#tart-vm -- <sub> --vm macvm`
   directly; the veneer only adds fleet defaults (identity, Downloads share,
   legacy `MACVM_*` env names).

4. **Home/host trimmings back** (each was tagged with a "left with the macvm
   host, 2026-09-05" comment at its removal site): the `vpn` operator +
   its `home.packages` gate, `macvmTartStart` + the Spotlight "Mac VM"
   launcher, the ssh `Host macvm` block, the macvm screencapture shared-inbox
   override in `modules/darwin/core.nix`, `.claude/{commands/vpn.md,`
   `skills/{macvm-tart,wireguard-vpn}}`, `docs/{macvm-tart-runbook,wireguard-vpn}.md`.

5. **Private layer**: nix-personal's `darwinConfigurations.macvm` +
   `apps.macvm` (removed in its own commit the same day).

6. **VM itself**: `tart clone tahoe-golden macvm` (if the golden image
   survived) — else `nix run .#macvm-tart-bake` — then
   `macvm-tart-start` + `macvm-tart-bootstrap` (identity injects from
   `identityArgs`; the image is operator-neutral by design).

## Traps encoded during removal (do not relearn)

- The guest's `~/Downloads` must be the VirtioFS **symlink** into the host's;
  never rotate it guest-side (`mv` across filesystems = `cp`+`rm` — would copy
  host bytes into the guest and unlink them on the host). The macos-only gate
  on the sweeps in `core.nix` was kept for exactly this reason.
- `masApps` fails activation on a host with no App Store login — keep the
  guest's `masApps = { }`.
- Guest captures on the guest's own Desktop are stranded — that's why the
  screencapture override pointed at the shared Downloads inbox.
- `tart-vm`'s grammar is `<subcommand> --vm NAME` (subcommand first).
