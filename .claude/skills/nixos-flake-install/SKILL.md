---
name: nixos-flake-install
description: >
  Install NixOS onto a freshly-booted machine/VM from this flake repo (nixosConfigurations
  nixbox / nixrpi). Use when asked to "install NixOS", run nixos-install, partition a disk for
  NixOS, or bring up a new host from the flake. Covers driving the install over SSH from the
  live ISO, label-based partitioning (boot/nixos), the ≥6 GB RAM prerequisite (low RAM causes
  silent install corruption), installing a private flake via rsync, and post-install host-key
  handoff to agenix-host-rekey.
---

# NixOS flake install (this repo)

Installs `nixosConfigurations.<host>` from `github:ismailkattakath/nix-config` onto a target.
`nixos-install` pulls nixpkgs from the **flake's own lock** (this flake tracks `nixos-unstable`),
so the installer ISO version is irrelevant — a 25.05 minimal ISO installs an unstable system fine.

## ⚠ PREREQUISITE: ≥6 GB RAM, install from a clean wipe (LOW RAM = SILENT CORRUPTION)

**Give the VM at least 6 GB RAM.** A `nixos-install` on a **2 GB** VM was OOM-killed mid-build;
Nix then marked the **partial store paths valid**, so retries — even with swap added and
`--cores 1 -j 1` — finished the `toplevel` **without rebuilding the damaged paths**. The result:
the system *boots* but `systemd-journald` / `-udevd` / `-networkd` fail in a loop. `udevd` dead
⇒ no NIC ⇒ no network ⇒ host unreachable (ARP shows `(incomplete)`).

**FIX: provision ≥6 GB RAM and install from a CLEAN WIPE.** Do **not** try to limp along with a
swapfile on a 2 GB VM — it does not save a store already poisoned with partial valid paths.
Also: a swapfile created on `/mnt` lands on the **target root** — remove it before finalizing.

## What the host configs expect (verified against the repo)

- **Partitions by LABEL** (`hosts/nixbox.nix`, `hosts/nixrpi.nix`):
  `/dev/disk/by-label/nixos` (ext4 root) and `/dev/disk/by-label/boot` (vfat EFI).
- **User** `izzy`: wheel, passwordless sudo, the project SSH key; **key-only SSH, no root login**
  (`modules/nixos/core.nix`).
- **DHCP** on all interfaces; **systemd-boot** + EFI.
- `hosts/nixbox.nix` already bakes in the **VirtIO initrd + UEFI `fileSystems`** (see Step 4) — no
  patch needed for `nixbox`.
- One known gap to handle (below): the **agenix host-key chicken-and-egg** for `*-tunnel-creds.age`.

## Step 1 — Reach a shell on the target

Console works, but driving over SSH is far easier. On the live ISO (set a password at the UTM
console first — the ISO has **no** preset password, and the login is **`root`**, not the `nixos`
user):

```bash
sudo systemctl start sshd
sudo passwd root         # temporary — discarded on reboot; the ISO needs a password to allow SSH
ip -4 addr               # note the IP (under UTM Shared/vmnet-shared this is a real 192.168.64.x)
```

UTM **Shared** mode (`vmnet-shared`) gives the guest a **real routable IP** on `192.168.64.x`
(`bridge100`) — no port-forward needed. Discover it from the Mac via ARP using the guest MAC
(`plutil -extract Network.0.MacAddress raw <bundle>/config.plist`):

```bash
arp -an | grep -i "<guest-MAC>"      # → ? (192.168.64.x) at <mac> on bridge100
```

**Logging into the live ISO from macOS** (macOS `ssh` can't pipe a password) — use `sshpass`:

```bash
sshpass -p "<console-pw>" ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@192.168.64.x
# then install your pubkey for key auth:
ssh root@192.168.64.x 'mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys' < ~/.ssh/id_ed25519.pub
```

(Key-only/no-root-login in the repo applies to the *installed* system, not the live ISO.)
A port-forward (`2222→22`, `ssh -p 2222 root@localhost`) is an alternative, but the direct
vmnet-shared IP is what the verified install used.

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

**Public repo** — clone directly:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  flake clone github:ismailkattakath/nix-config --dest /tmp/nixcfg
# (`nix-env -iA nixos.nixFlakes` is obsolete on current ISOs — use the flag instead.)
```

**Private repo (this repo)** — the VM **cannot** fetch `github:owner/repo` anonymously (the
GitHub API returns **404**). Instead, rsync your working tree into the VM and install from the
local path. From the Mac:

```bash
rsync -az --delete \
  --exclude '.git/hooks' --exclude 'memory/' --exclude 'result' \
  -e "ssh -i ~/.ssh/id_ed25519" ./ root@<ip>:/tmp/nixcfg/
```

Then on the VM (**flakes ignore untracked files**, so stage):

```bash
git config --global --add safe.directory /tmp/nixcfg
cd /tmp/nixcfg && git add -A
```

## Step 4 — VirtIO initrd: already baked into `nixbox`

`hosts/nixbox.nix` **already** includes the VirtIO initrd and UEFI `fileSystems`:
`boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod" ]`
plus systemd-boot. **No patch is needed for `nixbox`.**

The patch guidance below applies **only if you are creating a brand-new generic host** that lacks
these modules — without them, the root won't mount at boot on VirtIO. Either generate hardware
config (`nixos-generate-config --root /mnt` and import its output), or add inline before
installing, then stage (`git add -A` inside /tmp/nixcfg):

```nix
# add to a NEW hosts/<host>.nix that lacks initrd modules (NOT needed for nixbox)
boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod" ];
```

## Step 5 — Install

```bash
nixos-install --flake /tmp/nixcfg#nixbox --no-root-passwd
reboot
```

`--no-root-passwd` is correct here: login is via izzy's SSH key. Expect any `cloudflared` /
`*-tunnel-creds` agenix unit to **fail on first boot** — that secret is encrypted only to the
personal key, not the host key yet. SSH login is unaffected.

**Before finalizing, remove any swapfile you created on `/mnt`** — it lands on the **target
root** and ships with the installed system. (And recall the prerequisite: don't rely on swap to
survive a low-RAM install — use ≥6 GB RAM and a clean wipe.)

## Step 6 — Verify + hand off the host key

```bash
ssh izzy@<VM-IP> -i ~/.ssh/id_ed25519        # (or `ssh -p 2222 izzy@localhost`)
cat /etc/ssh/ssh_host_ed25519_key.pub          # needed for the next step
```

Then run the **agenix-host-rekey** skill to add this host key as a recipient and re-encrypt the
host-scoped tunnel creds so `services.cloudflared` activates on the next rebuild.

## Recovery toolkit (when the wrong OS booted or the install looks broken)

- **Which OS booted?** The ISO **regenerates its SSH host key every boot**; the installed
  system's key is **stable**. Compare fingerprints:
  `ssh-keyscan -t ed25519 <ip> | ssh-keygen -lf -`. The ISO also has `/iso` present and accepts
  `root` / the console-set password; the installed system rejects that login.
- **Repair an installed system from the ISO.** Mount the root and chroot:
  ```bash
  mount /dev/disk/by-label/nixos /mnt
  nixos-enter --root /mnt -c '<cmd>'
  ```
  GID-change warnings are harmless host/guest `/etc/group` noise. To read the **effective** sshd
  config, run `sshd -T` **inside the chroot** — do NOT read `/mnt/etc/ssh/sshd_config` directly,
  and do NOT confuse it with the live ISO's own `sshd_config`.
- **Force-boot the ISO instead of the disk / fix bloated NVRAM** — these are UTM-side; see the
  Recovery toolkit in the **utm-vm-provision** skill (detach `Drive.1`, move aside a bloated
  `efi_vars.fd`).
