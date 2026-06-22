---
name: utm-vm-provision
description: >
  Create and configure a UTM virtual machine on macOS, minimizing GUI work. Use when asked to
  "make a VM", "set up a UTM VM", "create an x86_64/ARM VM", provision a NixOS/Linux guest, or
  automate UTM. The reliable path for a BOOTABLE VM is GUI-create (or import a known-good .utm),
  then config.plist editing via plutil for headless tweaks. Covers disk sizing, VirtIO interfaces,
  ISO attach, vmnet-shared/ARP networking, and host→guest port forwarding. Pairs with
  nixos-flake-install for the in-guest OS install.
---

# UTM VM Provisioning (macOS)

## Two ways to get a running NixOS VM

1. **Preferred — import a prebuilt qcow2** (no ISO, no in-guest install, no OOM-RAM risk).
   Build the disk image from the flake on **any Nix-on-Linux box that targets aarch64-linux**,
   copy it to the Mac, and point a UTM VM at it:
   ```bash
   # on an aarch64-linux machine with nix+flakes:
   nixos-rebuild build-image --flake .#nixbox --image-variant qemu-efi
   #   → result/nixos-image-efi-qcow2-*.qcow2  (UEFI qcow2, UTM-importable)
   ```
   **Full NixOS is NOT required — just Nix + flakes on Linux for the right arch.** This repo's
   **devcontainer** qualifies (`nix:1` feature, `nix-command flakes`, Debian base): on an M3 Mac it
   builds aarch64 natively. Also fine: the `nixbox` VM itself, or CI. Only a bare macOS host can't
   (no nix, not Linux). Caveats: the builder spins up its own QEMU guest — without `/dev/kvm` it
   uses slow TCG emulation, and (per the RAM lesson) give the container enough memory + a few GB of
   scratch disk.
   Then create a UTM VM (GUI, aarch64/`virt`, UEFI) and replace its `Data/<UUID>.qcow2` with the
   built image (UTM quit; keep the filename or update `Drive.<disk>.ImageName`). The image already
   contains the full `nixbox` system — boot straight into it, no partitioning or `nixos-install`.
2. **Install from ISO** — create a VM, boot the minimal ISO, partition + `nixos-install` over SSH.
   Slower and has the ≥6 GB-RAM-or-corruption pitfall; use only if you can't build the image.
   See **nixos-flake-install** for the full ISO flow.

The rest of this skill covers creating/shaping the VM bundle (needed for both paths) and the
recovery toolkit.

## Gotchas (read first)

- **Create the VM in the UTM GUI** (or `import` a known-good `.utm`), then plutil-edit
  `config.plist` for headless tweaks, then `utmctl` to run. This is the only proven-bootable path.
- **`utmctl` controls existing VMs only** — list/status/start/stop/clone/delete/ip-address. It
  **cannot create or mutate config**. `utmctl attach` is a **non-functional stub** in UTM 4.7.5
  (`WARNING: attach command is not implemented yet!`) — there is **no CLI serial console**.
- **Quit UTM before editing `config.plist`** — UTM rewrites it on exit and clobbers your edits.
- **AppleScript `make` is unreliable for a bootable VM** (made VMs failed to boot) — fallback only.
- `utmctl delete` has **no confirmation**.
- Realized target in this repo: **aarch64 / UTM target `virt`** (Apple Silicon native).

Bundle path: `~/Library/Containers/com.utmapp.UTM/Data/Documents/<name>.utm/` containing
`config.plist`, `Data/<UUID>.qcow2`, `efi_vars.fd`. The **bundle display name ≠ NixOS hostname**:
the real VM is `NixOS.utm` running hostname `nixbox`. Paths below use `nixbox.utm` illustratively —
substitute your actual bundle name from `ls ~/Library/Containers/com.utmapp.UTM/Data/Documents/`.

## 1. Create the VM (GUI)

Create in the UTM GUI or `import virtual machine` a known-good `.utm`; pick architecture (aarch64,
target `virt`). Then quit UTM and apply tweaks below.

Fallback (de-emphasized — may not boot, and leaves IDE drives / `e1000` NIC / oversized qcow2 to
fix): `osascript -e 'tell application "UTM" to make new virtual machine with properties {backend:qemu, configuration:{name:"nixbox", architecture:"aarch64", memory:6144, cpu cores:4}}'`

## 2. Quit UTM before editing

```bash
osascript -e 'tell application "UTM" to quit'
sleep 3; pgrep -x UTM && echo "still running — wait" || echo "quit OK"
```

## 3. Configure via plutil

```bash
PLIST=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixbox.utm/config.plist

plutil -replace Drive.1.Interface  -string VirtIO          "$PLIST"  # disk → /dev/vda
plutil -replace Drive.0.Interface  -string USB             "$PLIST"  # CD over USB boots reliably
plutil -replace Network.0.Hardware -string virtio-net-pci  "$PLIST"  # NIC (NixOS DHCP binds cleanly)
plutil -lint "$PLIST"                                                # always validate
```

Confirm a key: `plutil -extract Drive.0.Interface raw "$PLIST"`.

**Serial console:** set its `Mode` to **`Terminal`** (not Ptty) — this avoids the `-2700` error on
`utmctl start`. But a `Terminal` serial is reachable **only in the UTM GUI window**; there is no CLI
console (`utmctl attach` is a stub).

## 4. Attach an ISO

```bash
BUNDLE=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixbox.utm
cp /path/to/installer.iso "$BUNDLE/Data/installer.iso"
plutil -replace Drive.0.ImageName -string installer.iso "$BUNDLE/config.plist"
plutil -replace Drive.0.ImageType -string CD            "$BUNDLE/config.plist"
```

## 5. Networking — vmnet-shared gives a real routable IP (no port-forward)

UTM **Shared** mode = `vmnet-shared` → guest gets a **real routable IP** (`192.168.64.x` on
`bridge100`). SSH straight to it. The live ISO has no guest agent, so `utmctl ip-address` fails —
find the IP via ARP using the guest MAC:

```bash
MAC=$(plutil -extract Network.0.MacAddress raw "$PLIST")
arp -an | grep -i "$MAC"        # → ? (192.168.64.x) at <mac> on bridge100
# ssh izzy@192.168.64.x   (or root@... on the live ISO)
```

**Alternative — port-forward `2222→22`** (then `ssh -p 2222 root@localhost`):

```bash
plutil -insert  Network.0.PortForward.0 -dictionary "$PLIST"
plutil -replace Network.0.PortForward.0.Protocol     -string  TCP  "$PLIST"
plutil -replace Network.0.PortForward.0.HostAddress  -string  ""   "$PLIST"
plutil -replace Network.0.PortForward.0.HostPort     -integer 2222 "$PLIST"
plutil -replace Network.0.PortForward.0.GuestAddress -string  ""   "$PLIST"
plutil -replace Network.0.PortForward.0.GuestPort    -integer 22   "$PLIST"
```

## 6. Disk sizing

UTM's bundled `qemu-img` is a non-executable `.framework` dylib. To **resize**: `brew install qemu`,
then `qemu-img resize "$BUNDLE/Data/<UUID>.qcow2" 20G`. To merely **read** the qcow2 virtual size
(BE-u64 at byte offset 24):

```bash
SIZE=$(xxd -s 24 -l 8 -p "$BUNDLE/Data/<UUID>.qcow2")
python3 -c "print(int('$SIZE',16)//1024**3, 'GiB')"
```

qcow2 is sparse, so an oversized virtual disk is harmless — leave it alone.

## 7. Boot and inspect

```bash
open -a UTM; sleep 5; utmctl list   # reopen so it picks up edits
utmctl start  nixbox                # Terminal-mode serial → no -2700
utmctl status nixbox                # → started
utmctl ip-address nixbox            # ⚠ empty on live ISO (no guest agent) — use ARP (step 5)
```

→ Continue with **nixos-flake-install** for the in-guest OS install.

## Recovery toolkit (UTM-side)

Keep a `config.plist.bak` before destructive edits; always quit UTM first.

- **Force-boot the ISO instead of the disk** (UEFI ignores QEMU `bootindex` once an NVRAM boot entry
  exists): detach the disk so only the CD is bootable, then re-attach from the backup afterward.
  ```bash
  cp "$BUNDLE/config.plist" "$BUNDLE/config.plist.bak"
  osascript -e 'tell application "UTM" to quit'; sleep 3
  plutil -remove Drive.1 "$BUNDLE/config.plist"   # drop disk; CD remains bootable
  ```
- **Bloated NVRAM** — `efi_vars.fd` can balloon (saw 1.8 GB; healthy ~640 KB). Move it aside and
  UTM regenerates a clean one:
  ```bash
  osascript -e 'tell application "UTM" to quit'; sleep 3
  mv "$BUNDLE/Data/efi_vars.fd" "$BUNDLE/Data/efi_vars.fd.bloated"
  ```
