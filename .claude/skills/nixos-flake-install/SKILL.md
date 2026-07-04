---
name: nixos-flake-install
description: >
  Bootstrap NixOS onto a freshly-booted VM from this flake repo. Use when asked to "install NixOS",
  bootstrap a host, partition a disk for NixOS, or bring up nixarm/nixamd from the flake. A single
  `nix run github:ismailkattakath/nix-config#<hostname>` command (the flake's bootstrap app) replaces
  the old three-step sequence of disko + git clone + nixos-install. Covers driving the bootstrap over
  SSH from the live ISO, the ≥6 GB RAM prerequisite, and post-install host-key handoff to agenix-host-rekey.
---

# NixOS flake bootstrap (this repo)

Bootstraps a NixOS host from `github:ismailkattakath/nix-config` via a single command. Two hosts
support this flow:

- **`nixarm`** — aarch64-linux, UTM/QEMU `virt` (Apple Silicon). Run from an **aarch64 live ISO**.
- **`nixamd`** — x86_64-linux, QEMU TCG emulation (slow but functional on Apple Silicon). Run from
  an **x86_64 live ISO**.

`nixos-install` pulls nixpkgs from the **flake's own lock** (tracks `nixos-unstable`), so the
installer ISO version is irrelevant. (`nixrpi` is a Raspberry Pi 4 SD-image host — not installable
via this flow.)

> **Faster alternative — skip the ISO install entirely.** Build a prebuilt qcow2 with
> `nixos-rebuild build-image --flake .#nixarm --image-variant qemu-efi` (on aarch64-linux) and
> import it into UTM — no partitioning, no in-guest install, no OOM-RAM pitfall. See
> **utm-vm-provision** › "Two ways to get a running NixOS VM". Use the ISO flow below only when
> you can't build/import an image.

## ⚠ PREREQUISITE: ≥6 GB RAM + clean wipe (LOW RAM = SILENT CORRUPTION)

A `nixos-install` on a **2 GB** VM gets OOM-killed mid-build; Nix then marks the **partial store
paths valid**, so retries — even with swap and `--cores 1 -j 1` — finish `toplevel` **without
rebuilding the damaged paths**. Result: the system *boots* but journald / udevd / networkd loop-fail
⇒ no NIC ⇒ unreachable (ARP shows `(incomplete)`). **Provision ≥6 GB RAM and install from a clean
wipe.** Do **not** limp along with swap — it cannot save an already-poisoned store. A swapfile on
`/mnt` also lands on the **target root** — remove it before finalizing.

## What `hosts/nixarm.nix` expects (verified)

- **Disk layout declared via disko** in `disko.devices`: GPT, 512 MiB ESP (vfat, label `boot`) +
  rest ext4 (label `nixos`). Run `disko --mode disko` (step 2) — it partitions, formats, and mounts
  in one step. No manual `parted`/`mkfs`/`mount` needed.
- **systemd-boot + UEFI**; **DHCP** on all interfaces.
- **Already bakes in VirtIO initrd** — `boot.initrd.availableKernelModules =
  [ "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod" ]`. **No initrd patch needed for
  nixarm** (see step 4 — patch is only for a brand-new generic host lacking these).
- **User `ismail`**: wheel, passwordless sudo, project SSH key; **key-only SSH, no root login**
  (`modules/nixos/core.nix`) — applies to the *installed* system, not the live ISO.
- One gap handled post-boot: the **agenix host-key chicken-and-egg** for `*-tunnel-token.age`.

## 1. Reach a shell on the target (SSH from the live ISO)

The ISO has **no preset password** and the login is **`root`** (not the `nixos` user). At the UTM
console:

```bash
sudo systemctl start sshd
sudo passwd root        # temporary, discarded on reboot — needed so SSH allows login
ip -4 addr              # under vmnet-shared this is a real 192.168.64.x
```

Find the IP from the Mac via ARP (guest MAC from `plutil -extract Network.0.MacAddress raw
<bundle>/config.plist`):

```bash
arp -an | grep -i "<guest-MAC>"      # → ? (192.168.64.x) at <mac> on bridge100
```

macOS `ssh` can't pipe a password — use `sshpass`, then install your pubkey for key auth:

```bash
sshpass -p "<console-pw>" ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@192.168.64.x
ssh root@192.168.64.x 'mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys' < ~/.ssh/id_ed25519.pub
```

(Port-forward `2222→22` → `ssh -p 2222 root@localhost` is an alternative; the direct vmnet-shared IP
is what the verified install used. See **utm-vm-provision** for networking setup.)

## 2. Bootstrap (single command)

The flake exposes a per-host bootstrap app that calls `disko-install` — partitions, formats, mounts,
and runs `nixos-install` in one shot. No git clone, no separate disko step, no `--no-root-passwd` to
remember (hardcoded by `disko-install`). **Destructive — verify `/dev/vda` is the target disk first.**

```bash
# nixarm (aarch64 ISO):
nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixarm

# nixamd (x86_64 ISO):
nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixamd
```

`--extra-experimental-features` is required on the bare ISO (flakes not enabled by default); once the
configured system boots it is no longer needed. The command fetches the flake from GitHub directly —
no local clone required.

**If you need to bootstrap from an unpublished local branch**, clone + rsync from the Mac, then pass
the local path to `disko-install` manually:

```bash
rsync -az --delete --exclude '.git/hooks' --exclude 'memory/' --exclude 'result' \
  -e "ssh -i ~/.ssh/id_ed25519" ./ root@<ip>:~/nix-config/
# on the VM:
sudo nix --extra-experimental-features 'nix-command flakes' run \
  github:nix-community/disko#disko-install -- --flake ~/nix-config#nixarm --disk vda /dev/vda
```

## 3. Verify + hand off the host key

```bash
ssh ismail@<VM-IP> -i ~/.ssh/id_ed25519
cat /etc/ssh/ssh_host_ed25519_key.pub        # needed for the next step
```

→ Run the **agenix-host-rekey** skill to add this host key as a recipient and re-encrypt the
tunnel token so the `cloudflared-connector` unit activates on the next rebuild.

## Recovery toolkit

- **Which OS booted?** The ISO **regenerates its SSH host key every boot**; the installed key is
  **stable**. Compare: `ssh-keyscan -t ed25519 <ip> | ssh-keygen -lf -`. The ISO also has `/iso`
  present and accepts `root` + the console password; the installed system rejects that login.
- **Repair an installed system from the ISO** — mount + chroot:
  ```bash
  mount /dev/disk/by-label/nixos /mnt
  nixos-enter --root /mnt -c '<cmd>'        # GID-change warnings are harmless
  ```
  Read the **effective** sshd config with `sshd -T` **inside the chroot** — not
  `/mnt/etc/ssh/sshd_config`, and not the live ISO's own config.
- **Force-boot the ISO / fix bloated `efi_vars.fd`** — UTM-side; see the Recovery toolkit in
  **utm-vm-provision** (detach `Drive.1`, move aside the bloated NVRAM).
