# Re-adding the `macvm` Tart guest

`macvm` (the aarch64-darwin Tart sandbox guest) was **removed from this flake on
2026-09-05** — deliberately, as a thin layer over machinery that survives the
removal, so bringing it back is a bounded, mechanical exercise. This runbook is
the durable re-add path (it survives refactors where a `git revert` would not).

## What survives the removal

| Asset | Where it lives now |
|---|---|
| ALL generic Tart machinery — lifecycle CLI (`tart-vm`), plug-and-play `bootstrap`, packer golden-image `bake`, `tart-guest-agent` packaging, a `local.tart.vms.<name>` darwin module | **`modules/features/tart-vms/`, in THIS repo.** It was `github:kattakath/nix-tart-vms` until ADR-002 wave 5 absorbed it as a capsule; the origin repo is archived. `local.tart.vms.*` (`modules/features/tart-vms/darwin.nix`) is the one module in the fleet with **no consumer today**, kept precisely so this runbook still has a step 1. |
| A baked, operator-neutral **golden image** (`tahoe-golden`) | `~/.tart/vms/` on the macos host (imperative artifact — check `tart list` before assuming) |
| The removed thin layer, verbatim | git history — the removal commit is tagged in the PR that cites this runbook; `git show <removal>^:hosts/macvm.nix` etc. |

## Re-add procedure

1. **Module back — no input, no lock change.** The `local.tart.vms.<name>` module is
   already in-tree and already registered by the capsule
   (`modules/features/tart-vms/flake-module.nix`, `capsuleModules.darwin.tart-vms`);
   it is simply not in any composition. Add it to `mkDarwin`'s base list in
   `modules/parts/compose.nix`, next to the two runner modules:

   ```nix
   inherit (config.capsuleModules.darwin) tart-github-runner tart-gitlab-runner tart-vms;
   # … then in mkDarwin's `modules = [ … ]`:
   tart-vms
   ```

   Keep it a bare PATH in that list, not a wrapper — both runner modules
   `imports = [ ./slots.nix ]` and the module system dedupes by path identity.

2. **Host profile back**: restore `hosts/macvm.nix` from the removal commit
   (adjust for drift — e.g. option renames since; it consumed
   `local.folders.downloads` and the guest agent via `mkDarwin` specialArgs)
   and re-register `darwinConfigurations.macvm = mkDarwin { … }` plus the
   `#macvm` activation app.

3. **Veneer back**: restore `packages/macvm-tart.nix` (thin aliases over
   `tart-vm --vm macvm`) + its `packages`/`apps` wiring — or skip the veneer
   and use `nix run .#tart-vm -- <sub> --vm macvm`
   directly; the veneer only adds fleet defaults (identity, Downloads share,
   legacy `MACVM_*` env names).

4. **Home/host trimmings back** (each was tagged with a "left with the macvm
   host, 2026-09-05" comment at its removal site): the `vpn` operator +
   its `home.packages` gate, `macvmTartStart` + the Spotlight "Mac VM"
   launcher, the ssh `Host macvm` block, the macvm screencapture shared-inbox
   override in `modules/darwin/core.nix`, `.claude/{commands/vpn.md,`
   `skills/{macvm-tart,wireguard-vpn}}`, `docs/{macvm-tart-runbook,wireguard-vpn}.md`.

5. **Private layer — UNFOLLOWABLE as written; there is no private layer.** This
   step used to say "restore nix-personal's `darwinConfigurations.macvm` +
   `apps.macvm`". That flake was retired 2026-09-15 and its values folded into
   `hosts/macos.nix` + `modules/parts/identity.nix`, so there is no second repo
   to edit. Both halves live in THIS flake now, and step 2 already covers them:
   the host attribute goes in `flake.darwinConfigurations`
   (`modules/parts/hosts.nix`), and the `#macvm` activation app goes back beside
   `apps.macos` in `modules/parts/packages.nix` — its removal comment still marks
   the exact site.

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
