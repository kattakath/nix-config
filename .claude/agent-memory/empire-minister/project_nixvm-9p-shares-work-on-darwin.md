---
name: nixvm-9p-shares-work-on-darwin
description: hosts/nixvm.nix's old comment claimed sharedDirectories are impossible on a darwin host (virtiofsd Linux-only) — FALSE; useVirtiofs is isLinux so darwin falls back to 9p -virtfs. One wireguard share now rides it.
metadata:
  type: project
---

`virtualisation.sharedDirectories` **works on the aarch64-darwin host** for `nixvm`.
Landed 2026-10-06 (`c28e746`) as one read-only share of the operator's WireGuard confs.

**Why:** `hosts/nixvm.nix` carried a comment asserting nixpkgs implements every share via
virtiofs and `hostPkgs.virtiofsd` is Linux-only, so no share could exist. Only the second
half is true. At the real pin (`nixpkgs_2` = `44a91898`),
`nixos/modules/virtualisation/qemu-vm.nix:27` is
`useVirtiofs = hostPkgs.stdenv.hostPlatform.isLinux` — **false** on darwin — so shares fall
back to `-virtfs local,…` (`:1309`) plus a guest `fsType = "9p"` mount (`:1405`), and
`virtiofsd` is never forced. That stale comment forbade a feature for ~a year.

**How to apply:** if a future task needs host↔nixvm file passing, use
`sharedDirectories`, not raw `-fsdev`/`-virtfs` in `qemu.options`.

Mechanics worth not re-deriving:

| Fact | Source |
|---|---|
| `source` is `types.str` and **may be a shell variable** — upstream's own `xchg` default is `"$TMPDIR"/xchg`; it interpolates UNQUOTED into the runner's qemu line (`:360`), so `"$HOME"/…` expands on the Mac | qemu-vm.nix:588, 1235-1250 |
| Keep `lib.mkForce` on the attrset or upstream's `xchg` + `shared` test-driver shares come back | qemu-vm.nix:1235 |
| Every entry is `neededForBoot = true` → append `"nofail"` | qemu-vm.nix:1406 |
| Append `nofail` to **`virtualisation.fileSystems`**, NOT `fileSystems` — the latter is published wrapped in `mkVMOverride` (priority 10) and list merging keeps only highest-priority defs, so a normal-priority append there is silently DISCARDED | qemu-vm.nix:1396, 463 |
| `nofail` only bites because `boot.initrd.systemd.enable` is true here. The SCRIPTED stage-1 strips every `x-` option and `mountFS` calls `fail` (emergency shell) on a non-zero `mount` — it honours `nofail` nowhere | stage-1-init.sh:393, 418 |

`useNixStoreImage = true` was NOT changed. Its old justification was the same wrong virtiofs
claim; the honest replacement is "measured-working config, and a 9p host-store mount from a
macOS store into a Linux guest has never been tried here." Untested, not impossible.

See [[project-nixvm-wireguard-mount-not-wg-quick-option]].
