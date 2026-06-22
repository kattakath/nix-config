---
name: utm-vm-provision
description: >
  Create and configure a UTM virtual machine headlessly on macOS — no GUI clicking.
  Use when asked to "make a VM", "set up a UTM VM", "create an x86_64/ARM VM", provision a
  NixOS/Linux guest, or automate UTM. Covers AppleScript VM creation, config.plist editing
  via plutil, disk sizing, VirtIO interfaces, ISO attach, and host→guest port forwarding.
  Pairs with nixos-flake-install for the in-guest OS install.
---

# UTM VM Provisioning (headless, macOS)

Create and shape a UTM VM entirely from the CLI. UTM exposes two automation surfaces with a
hard split in capability — know which does what:

| Surface | Can do | Cannot do |
|---|---|---|
| `utmctl` (CLI, on PATH via Homebrew + `/Applications/UTM.app/Contents/MacOS/utmctl`) | list, status, **start/stop**, attach (serial), **ip-address**, exec, clone, delete | **create a VM**; mutate config |
| UTM **AppleScript** (`osascript -e 'tell application "UTM" …'`) | `make new virtual machine`, `import virtual machine`, read properties, enumerate | reliably mutate drive sub-objects |

So the working recipe is: **AppleScript to create**, **plutil to configure**, **utmctl to run**.

## Step 1 — Create the VM (AppleScript)

The existing default backend may be `apple` (Virtualize). For x86_64 on Apple Silicon you need
`qemu` (Emulate):

```bash
osascript <<'EOF'
tell application "UTM"
  set vmConfig to {backend:qemu, configuration:{name:"nixbox", architecture:"x86_64", memory:4096, cpu cores:4}}
  set newVM to make new virtual machine with properties vmConfig
  get name of newVM
end tell
EOF
```

This creates a VM but with **defaults you must fix**: IDE drives, an `e1000` NIC, and a
qcow2 of UTM's default virtual size (often 64 GiB) — not necessarily what you asked for.

## Step 2 — CRITICAL: quit UTM before editing the bundle

UTM **rewrites `config.plist` on exit and clobbers external edits**. Always:

```bash
osascript -e 'tell application "UTM" to quit'
sleep 3; pgrep -x UTM && echo "still running — wait" || echo "quit OK"
```

The bundle lives at:
`~/Library/Containers/com.utmapp.UTM/Data/Documents/<name>.utm/`
with `config.plist` and `Data/<UUID>.qcow2` + `efi_vars.fd` inside.

## Step 3 — Configure via plutil

```bash
PLIST=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixbox.utm/config.plist

# Disk → VirtIO (guest device becomes /dev/vda); CD over USB boots reliably on q35
plutil -replace Drive.1.Interface -string VirtIO "$PLIST"   # index 1 = the disk
plutil -replace Drive.0.Interface -string USB    "$PLIST"   # index 0 = the CD
# NIC → virtio-net-pci (so NixOS DHCP-on-all-interfaces binds cleanly)
plutil -replace Network.0.Hardware -string virtio-net-pci "$PLIST"
plutil -lint "$PLIST"   # always validate
```

Confirm per-drive: `plutil -extract Drive.0.Interface raw "$PLIST"` etc.

## Step 4 — Attach an ISO

UTM references removable media by `ImageName` inside the bundle's `Data/` dir:

```bash
BUNDLE=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixbox.utm
cp /path/to/installer.iso "$BUNDLE/Data/installer.iso"
plutil -replace Drive.0.ImageName -string installer.iso "$BUNDLE/config.plist"
plutil -replace Drive.0.ImageType -string CD            "$BUNDLE/config.plist"
```

## Step 5 — Port-forward for SSH (Shared/NAT mode)

Under Shared networking the guest gets a private IP; forward a host port to reach it:

```bash
PLIST=.../config.plist
plutil -insert  Network.0.PortForward.0 -dictionary "$PLIST"
plutil -replace Network.0.PortForward.0.Protocol     -string  TCP "$PLIST"
plutil -replace Network.0.PortForward.0.HostAddress  -string  ""  "$PLIST"
plutil -replace Network.0.PortForward.0.HostPort     -integer 2222 "$PLIST"
plutil -replace Network.0.PortForward.0.GuestAddress -string  ""  "$PLIST"
plutil -replace Network.0.PortForward.0.GuestPort    -integer 22  "$PLIST"
```

Then `ssh -p 2222 root@localhost` from the Mac reaches guest `:22`.

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
utmctl start nixbox                          # a -2700 OSStatus event is non-fatal (display/console)
utmctl status nixbox                          # → started
utmctl ip-address nixbox                      # ⚠ empty on a live installer ISO (no guest agent)
```

## Boundaries / gotchas (front-loaded)

- **No guest agent on most live ISOs** → `utmctl exec` and `utmctl ip-address` won't work until
  the installed OS runs `qemu-guest-agent`. To drive an install, start `sshd` in the live env and
  use the port-forward (see nixos-flake-install).
- **Edit config.plist only while UTM is quit**, or edits vanish.
- **AppleScript drive mutation is unreliable** — use plutil on the bundle instead.
- `utmctl` includes `delete` with **no confirmation** — be deliberate.
- `start` may print `OSStatus error -2700` while still starting; trust `utmctl status`.
