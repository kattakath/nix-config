# nixpi: leaving raspberry-pi-nix — in-place switch vs reflash

Costing for moving `nixpi` (the LIVE Pi 4) off the archived `raspberry-pi-nix` input, written
2026-10-21 alongside the prototype. Sources read at their pinned revs: raspberry-pi-nix
`3e8100d5` (`sd-image/`, `rpi/default.nix`), nixos-hardware `efb6d0d5`
(`raspberry-pi/4/default.nix`, `raspberry-pi/common/{firmware,kernel,config-txt}.nix`) and
nixpkgs' `nixos/modules/installer/sd-card/sd-image.nix`.

`nixpi`'s hardware moved from the archived `raspberry-pi-nix` to nixos-hardware's
`raspberry-pi/4` (kernel 6.6.51 → linux-rpi 6.18.50). The **boot chain** changed, not just the
kernel:

| | raspberry-pi-nix (old) | nixos-hardware + nixpkgs sd-image (new) |
|---|---|---|
| GPU firmware loads | `kernel.img` + `initrd` + `cmdline.txt` off FIRMWARE | `u-boot.bin` off FIRMWARE |
| Generation chosen by | `/sbin/init` on root (`boot.loader.initScript`) | `/boot/extlinux/extlinux.conf` on root |
| FIRMWARE refreshed by | `raspberry-pi-firmware-migrate.service`, at boot | activation script, at every switch |
| Card layout | MBR, `FIRMWARE` 128 MB + `NIXOS_SD` (bootable) | **same** — labels, id `0x2178694e`, bootable p2; size pinned to 128 |

**Verdict: an in-place switch is POSSIBLE, but its first reboot has NO remote undo.**

- **Why possible.** The layout is identical, so nothing needs repartitioning. FIRMWARE stays
  at `/boot/firmware` with label `FIRMWARE`, so the `firmware-secrets` token and Wi-Fi keep
  working. The switch rewrites `config.txt` to `kernel=u-boot.bin`, adds `u-boot.bin` and
  writes extlinux.conf. It leaves `kernel.img`/`initrd`/`cmdline.txt` in place (the installer
  prunes only `*.dtb` and `overlays/*`).
- **Why no undo.** `magicRollback` guards the ACTIVATION, not the next boot. And a rollback
  does not undo the boot chain. The old generation's migrate service skips `config.txt` (its
  state file still matches), and its init-script loader never touches extlinux.conf. So a
  rolled-back Pi still reboots through U-Boot into the NEW generation.
- **Pre-flight (read-only, on the Pi):** `sfdisk -d /dev/mmcblk0` must show p2 `bootable`.
  The runbook's §4c MBR rewrite should keep the flag, but nobody has checked it. Without the flag, U-Boot's
  distro boot scans only p1. `/nix-path-registration` must be ABSENT: nixpkgs' new
  `expand-root-partition` and `register-nix-paths` services both run when it exists. Then
  copy `/boot/firmware` to `/var/lib/firmware-pre-nixos-hardware`.
- **If the reboot hangs:** move the card to the Mac and restore `config.txt` from that copy
  (`kernel=kernel.img`, `ramfsfile=initrd`). The old 6.6 kernel then boots against the NEW
  `start4.elf` and dtbs. That is probably fine, but it is untested.

**Recommended instead: reflash a NEW, f3-tested card** (the live one is counterfeit, §3c of
[`nixpi-sd-flashing-runbook.md`](nixpi-sd-flashing-runbook.md)). Keep the old card untouched as a two-minute physical rollback. A reflash loses the
SD-resident state: the Audiobookshelf database (its backups are on `/mnt/storage`), the
persistent journal, and the SSH host key.

**The kernel is HELD.** `update-flake-lock.yml` excludes `nixos-hardware` from its weekly
allowlist (as it does `grok-build-plugin-cc`), so a bump never moves the LIVE Pi's kernel
unannounced; move it deliberately with `/update-input nixos-hardware`.
