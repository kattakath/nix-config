---
name: utm-vm-provision
description: >
  Create and configure a UTM virtual machine on macOS, minimizing GUI work.
  Use when asked to "make a VM", "set up a UTM VM", "create an x86_64/ARM VM", provision a
  NixOS/Linux guest, or automate UTM. The reliable path for a BOOTABLE VM is GUI-create
  (or import a known-good .utm), then config.plist editing via plutil for headless tweaks.
  Covers disk sizing, VirtIO interfaces, ISO attach, the vmnet-shared/ARP networking reality,
  and host→guest port forwarding. Pairs with nixos-flake-install for the in-guest OS install.
---

# UTM VM Provisioning (macOS)

Create a bootable UTM VM, then shape it from the CLI. UTM exposes two automation surfaces with a
hard split in capability — know which does what:

| Surface | Can do | Cannot do |
|---|---|---|
| `utmctl` (CLI, on PATH via Homebrew + `/Applications/UTM.app/Contents/MacOS/utmctl`) | list, status, **start/stop**, **ip-address** (needs guest agent), clone, delete | **create a VM**; mutate config; **`attach` is a non-functional stub** — UTM 4.7.5 prints `WARNING: attach command is not implemented yet!`, so there is NO CLI serial console |
| UTM **AppleScript** (`osascript -e 'tell application "UTM" …'`) | `import virtual machine`, read properties, enumerate; `make new virtual machine` exists but is **unreliable for producing a bootable VM** (a `make`-created VM failed to boot) | reliably mutate drive sub-objects; reliably create a *bootable* VM |

So the **proven-good recipe** is: **create the VM in the UTM GUI (or `import` a known-good .utm
bundle)**, then **plutil to configure** the bundle's `config.plist`, then **utmctl to run**.
AppleScript `make` is documented below only as a fallback, clearly de-emphasized.

## Step 1 — Create the VM (GUI is reliable; AppleScript is not)

**Preferred:** create the VM in the UTM GUI (or `import virtual machine` a known-good `.utm`
bundle), pick the architecture/target, then quit UTM and apply the headless tweaks in Steps 2+.
The realized target in this repo is **aarch64 / UTM target `virt`** (Apple Silicon native), not
x86_64/q35.

**Fallback only — if scripting creation** (`make` is unreliable for a *bootable* VM; prefer the
GUI):

```bash
osascript <<'EOF'
tell application "UTM"
  set vmConfig to {backend:qemu, configuration:{name:"nixbox", architecture:"aarch64", memory:6144, cpu cores:4}}
  set newVM to make new virtual machine with properties vmConfig
  get name of newVM
end tell
EOF
```

(`architecture:"aarch64"`, UTM target `virt` is the realized target.) Even when `make` succeeds
it leaves **defaults you must fix**: IDE drives, an `e1000` NIC, and a qcow2 of UTM's default
virtual size (often 64 GiB) — and the resulting VM may not boot at all. Prefer the GUI/import path.

## Step 2 — CRITICAL: quit UTM before editing the bundle

UTM **rewrites `config.plist` on exit and clobbers external edits**. Always:

```bash
osascript -e 'tell application "UTM" to quit'
sleep 3; pgrep -x UTM && echo "still running — wait" || echo "quit OK"
```

The bundle lives at:
`~/Library/Containers/com.utmapp.UTM/Data/Documents/<name>.utm/`
with `config.plist` and `Data/<UUID>.qcow2` + `efi_vars.fd` inside.

> `<name>` is the UTM **display name**, independent of the NixOS hostname. The realized VM is
> named `NixOS.utm` even though its installed hostname is `nixbox` — the `nixbox.utm` paths below
> are illustrative; substitute your actual bundle name (`ls ~/Library/Containers/com.utmapp.UTM/Data/Documents/`).

## Step 3 — Configure via plutil

```bash
PLIST=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixbox.utm/config.plist

# Disk → VirtIO (guest device becomes /dev/vda); CD over USB boots reliably
plutil -replace Drive.1.Interface -string VirtIO "$PLIST"   # index 1 = the disk
plutil -replace Drive.0.Interface -string USB    "$PLIST"   # index 0 = the CD
# NIC → virtio-net-pci (so NixOS DHCP-on-all-interfaces binds cleanly)
plutil -replace Network.0.Hardware -string virtio-net-pci "$PLIST"
plutil -lint "$PLIST"   # always validate
```

Confirm per-drive: `plutil -extract Drive.0.Interface raw "$PLIST"` etc.

### Serial console: Mode must be `Terminal` (not Ptty)

If you add a serial console, set its `Mode` to **`Terminal`** — with `Terminal`, `utmctl start`
does **NOT** throw the `-2700` error. But a `Terminal` serial is only reachable in the **UTM GUI
window** — there is no CLI console, because `utmctl attach` is a non-functional stub (see the
capability table). Do not expect to drive the serial console from the terminal.

## Step 4 — Attach an ISO

UTM references removable media by `ImageName` inside the bundle's `Data/` dir:

```bash
BUNDLE=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixbox.utm
cp /path/to/installer.iso "$BUNDLE/Data/installer.iso"
plutil -replace Drive.0.ImageName -string installer.iso "$BUNDLE/config.plist"
plutil -replace Drive.0.ImageType -string CD            "$BUNDLE/config.plist"
```

## Step 5 — Networking: vmnet-shared gives a REAL routable IP (no port-forward needed)

UTM **Shared** mode uses `vmnet-shared`, which hands the guest a **real routable IP on a host
subnet** — observed `192.168.64.x` on `bridge100`. You do **NOT** need a port-forward to SSH from
the Mac; you SSH straight to the guest IP.

**Discover the guest IP from the Mac via ARP** (the live ISO has no QEMU guest agent, so
`utmctl ip-address` fails — ARP is the way). The guest MAC is in
`config.plist` at `Network.0.MacAddress`:

```bash
MAC=$(plutil -extract Network.0.MacAddress raw "$PLIST")
arp -an | grep -i "$MAC"        # → ? (192.168.64.x) at <mac> on bridge100 ...
# then: ssh izzy@192.168.64.x   (or root@... on the live ISO)
```

### Alternative — port-forward for SSH (Shared/NAT mode)

If you must use a port-forward instead, forward a host port to the guest:

```bash
plutil -insert  Network.0.PortForward.0 -dictionary "$PLIST"
plutil -replace Network.0.PortForward.0.Protocol     -string  TCP "$PLIST"
plutil -replace Network.0.PortForward.0.HostAddress  -string  ""  "$PLIST"
plutil -replace Network.0.PortForward.0.HostPort     -integer 2222 "$PLIST"
plutil -replace Network.0.PortForward.0.GuestAddress -string  ""  "$PLIST"
plutil -replace Network.0.PortForward.0.GuestPort    -integer 22  "$PLIST"
```

Then `ssh -p 2222 root@localhost` from the Mac reaches guest `:22`. But under vmnet-shared the
direct-IP/ARP path above is simpler and is what the verified install used.

## Step 6 — Disk sizing without a real qemu-img

UTM's bundled `qemu-img` is a **`.framework` dylib — NOT executable** (`exec format error`).
To *resize* you need a real binary: `brew install qemu`, then
`qemu-img resize "$BUNDLE/Data/<UUID>.qcow2" 20G`.

To merely *read* the qcow2 virtual size without qemu, parse the header (big-endian u64 at
byte offset 24):

```bash
SIZE=$(xxd -s 24 -l 8 -p "$BUNDLE/Data/<UUID>.qcow2")
python3 -c "print(int('$SIZE',16)//1024**3, 'GiB')"
```

qcow2 is **sparse** — a 64 GiB virtual disk costs only the bytes actually written, so a
default-larger disk is usually fine to leave alone (≥ requested size is harmless).

## Step 7 — Boot and inspect

```bash
open -a UTM; sleep 5; utmctl list          # reopen so it picks up your edits
utmctl start nixbox                           # with a Terminal-mode serial this does NOT throw -2700
utmctl status nixbox                          # → started
utmctl ip-address nixbox                      # ⚠ empty on a live installer ISO (no guest agent) — use ARP (Step 5)
```

## Recovery toolkit (UTM-side)

When a VM boots the wrong thing or won't come up, these host-side tricks help:

- **Force-boot the ISO instead of the disk.** UEFI ignores QEMU `bootindex` once an NVRAM boot
  entry exists. With UTM quit, detach the disk drive so only the CD is bootable, then re-attach
  after (keep a `config.plist.bak`):

  ```bash
  cp "$BUNDLE/config.plist" "$BUNDLE/config.plist.bak"
  osascript -e 'tell application "UTM" to quit'; sleep 3
  plutil -remove Drive.1 "$BUNDLE/config.plist"   # drop the disk; only the CD remains bootable
  # …boot the ISO, do your repair, quit UTM, then restore from config.plist.bak
  ```

- **`efi_vars.fd` (NVRAM) can bloat/corrupt** — saw 1.8 GB; a healthy one is ~640 KB. With UTM
  quit, move it aside and UTM regenerates a clean one:

  ```bash
  osascript -e 'tell application "UTM" to quit'; sleep 3
  mv "$BUNDLE/Data/efi_vars.fd" "$BUNDLE/Data/efi_vars.fd.bloated"
  ```

## Boundaries / gotchas (front-loaded)

- **`utmctl attach` is a non-functional stub** (UTM 4.7.5 prints `WARNING: attach command is not
  implemented yet!`). There is NO CLI serial console — a `Terminal`-mode serial is only reachable
  in the UTM GUI window.
- **AppleScript `make` is unreliable for a bootable VM** — a `make`-created VM failed to boot.
  Create via the UTM GUI or `import` a known-good `.utm` bundle; use plutil only for headless tweaks.
- **No guest agent on most live ISOs** → `utmctl ip-address` won't work until the installed OS
  runs `qemu-guest-agent`. Under vmnet-shared the guest has a real routable IP — discover it via
  ARP from the Mac (see Step 5), then SSH directly; no port-forward needed.
- **Edit config.plist only while UTM is quit**, or edits vanish.
- **AppleScript drive mutation is unreliable** — use plutil on the bundle instead.
- `utmctl` includes `delete` with **no confirmation** — be deliberate.
- With a `Terminal`-mode serial, `utmctl start` does NOT throw `-2700`.
