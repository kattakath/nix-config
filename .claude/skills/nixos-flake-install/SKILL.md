---
name: nixos-flake-install
description: >
  Install NixOS onto a freshly-booted machine/VM from this flake repo (nixosConfigurations
  nixbox / nixrpi). Use when asked to "install NixOS", run nixos-install, partition a disk for
  NixOS, or bring up a new host from the flake. Covers driving the install over SSH from the
  live ISO, label-based partitioning (boot/nixos), the VirtIO initrd patch, and post-install
  host-key handoff to agenix-host-rekey.
---

# NixOS flake install (this repo)

Installs `nixosConfigurations.<host>` from `github:ismailkattakath/nix-config` onto a target.
`nixos-install` pulls nixpkgs from the **flake's own lock** (this flake tracks `nixos-unstable`),
so the installer ISO version is irrelevant — a 25.05 minimal ISO installs an unstable system fine.

## What the host configs expect (verified against the repo)

- **Partitions by LABEL** (`hosts/nixbox.nix`, `hosts/nixrpi.nix`):
  `/dev/disk/by-label/nixos` (ext4 root) and `/dev/disk/by-label/boot` (vfat EFI).
- **User** `izzy`: wheel, passwordless sudo, the project SSH key; **key-only SSH, no root login**
  (`modules/nixos/core.nix`).
- **DHCP** on all interfaces; **systemd-boot** + EFI.
- Two known gaps to handle (below): **no hardware-config / VirtIO initrd**, and the
  **agenix host-key chicken-and-egg** for `*-tunnel-creds.age`.

## Step 1 — Reach a shell on the target

Console works, but driving over SSH is far easier. On the live ISO:

```bash
sudo systemctl start sshd
sudo passwd root         # temporary — discarded on reboot; the ISO needs a password to allow SSH
ip -4 addr               # note the IP (≈10.0.2.15 under UTM shared NAT)
```

From the Mac, via the UTM port-forward (`2222→22`): `ssh -p 2222 root@localhost`.
(Key-only/no-root-login in the repo applies to the *installed* system, not the live ISO.)

## Step 2 — Partition (UEFI, GPT, labels)

Disk is `/dev/vda` on a VirtIO VM (`lsblk` to confirm). **Destructive** — verify the device first.

```bash
parted /dev/vda -- mklabel gpt
parted /dev/vda -- mkpart ESP fat32 1MiB 512MiB
parted /dev/vda -- set 1 esp on
parted /dev/vda -- mkpart primary 512MiB 100%

mkfs.fat -F32 -n boot  /dev/vda1      # LABEL=boot  (matches fileSystems."/boot")
mkfs.ext4      -L nixos /dev/vda2      # LABEL=nixos (matches fileSystems."/")

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot /mnt/boot
```

## Step 3 — Get the flake

```bash
nix --extra-experimental-features 'nix-command flakes' \
  flake clone github:ismailkattakath/nix-config --dest /tmp/nixcfg
# (`nix-env -iA nixos.nixFlakes` is obsolete on current ISOs — use the flag instead.)
```

## Step 4 — VirtIO initrd patch (REQUIRED for VMs)

`hosts/<host>.nix` hardcodes `fileSystems` but imports **no** `hardware-configuration.nix` and
sets **no** initrd modules — its own comment says to replace it on real hardware. On VirtIO the
root won't mount at boot without the modules. Either generate hardware config
(`nixos-generate-config --root /mnt` and import its output), or add inline before installing:

```nix
# add to hosts/<host>.nix
boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod" ];
```

Stage it (`git add -A` inside /tmp/nixcfg — **flakes ignore untracked files**).

## Step 5 — Install

```bash
nixos-install --flake /tmp/nixcfg#nixbox --no-root-passwd
reboot
```

`--no-root-passwd` is correct here: login is via izzy's SSH key. Expect any `cloudflared` /
`*-tunnel-creds` agenix unit to **fail on first boot** — that secret is encrypted only to the
personal key, not the host key yet. SSH login is unaffected.

## Step 6 — Verify + hand off the host key

```bash
ssh izzy@<VM-IP> -i ~/.ssh/id_ed25519        # (or `ssh -p 2222 izzy@localhost`)
cat /etc/ssh/ssh_host_ed25519_key.pub          # needed for the next step
```

Then run the **agenix-host-rekey** skill to add this host key as a recipient and re-encrypt the
host-scoped tunnel creds so `services.cloudflared` activates on the next rebuild.
