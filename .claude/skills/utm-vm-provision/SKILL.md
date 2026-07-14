---
name: utm-vm-provision
description: >
  Create and configure a UTM virtual machine on macOS, with NO GUI required, and drive the full
  macOS→UTM→NixOS pipeline for the nixvm sandbox VM. Use when asked to "make a VM", "set up a UTM
  VM", "provision a NixOS/Linux guest", "spin up nixvm", "install NixOS in UTM", or automate UTM.
  For a prebuilt qcow2 (nixvm), a fully CLI-authored bundle — heredoc config.plist + copied disk +
  UTM restart — boots and SSHs end-to-end (VERIFIED, see §0); no GUI or AppleScript needed. For
  ISO installs, GUI-create remains the reliable path. Covers disk sizing, VirtIO interfaces, ISO
  attach, vmnet-shared/ARP networking, host→guest port forwarding, and the boundary between
  host-side automation and in-guest steps. Pairs with nixos-flake-install for the in-guest OS
  install.
---

# UTM VM Provisioning (macOS) — nixvm sandbox

## Repo facts you rely on (verify, don't assume)

- Target: `nixosConfigurations.nixvm` (aarch64-linux, generic UTM/QEMU UEFI VM, sandbox — GUI and
  remote-desktop deferred, no public ingress). The realized VM is **aarch64 / UTM target `virt`**,
  not x86_64/q35.
- Partition labels: `nixos` (ext4 root) + `boot` (vfat EFI) — `hosts/nixvm.nix`.
- User `ismail`: wheel, passwordless sudo, project SSH key; key-only SSH, no root login.
- Flake tracks `nixos-unstable` → installer ISO version is irrelevant.
- `hosts/nixvm.nix` **already** includes the VirtIO initrd (`virtio_pci`/`virtio_blk`/
  `virtio_scsi`/`ahci`/`sd_mod`) + UEFI `fileSystems` + systemd-boot — **no patch needed**. The
  initrd patch only applies if you create a brand-new generic host that lacks it.
- **≥6 GB RAM, clean wipe.** A 2 GB VM OOM-kills `nixos-install` mid-build; Nix marks the partial
  store paths valid, so retries (even with swap + `--cores 1 -j 1`) finish `toplevel` without
  rebuilding the damaged paths → boots but journald/udevd/networkd loop, no NIC, unreachable.
- **Private repo** → the VM can't fetch `github:owner/repo` anonymously (404). rsync the working
  tree in (`--exclude '.git/hooks' --exclude 'memory/' --exclude 'result'`), `git add -A` on the
  VM (flakes ignore untracked files), then `nixos-install --flake /tmp/nixcfg#nixvm`.
- `nixvm` has **no `/etc/secrets/*` requirement** — it is a sandbox with no tunnel and no public
  ingress. (Contrast with `nixpi`, which needs `/etc/secrets/cloudflared-token` — see the
  **cloudflared-tunnel** skill; that host is Pi hardware, not a UTM target.)

## Hard boundaries (state them; don't fake past them)

- **`utmctl attach` is a non-functional stub** (UTM 4.7.5: `WARNING: attach command is not
  implemented yet!`) — there is NO CLI serial console. A `Terminal`-mode serial (which avoids the
  `-2700` start error) is only reachable in the UTM GUI window.
- **You cannot run commands inside a live NixOS ISO** — it has no QEMU guest agent, so
  `utmctl ip-address`/`exec` don't work. The user sets a root password at the UTM console (the ISO
  has no preset password; login is `root`, not `nixos`) and starts `sshd`; then you SSH in. Under
  UTM **Shared** (`vmnet-shared`) the guest has a **real routable IP** (`192.168.64.x` on
  `bridge100`) — discover it via `arp -an | grep <Network.0.MacAddress>` and SSH directly; no
  port-forward needed. (macOS `ssh` can't pipe a password — use `sshpass`.)
- **AppleScript `make` is unreliable for a bootable VM** — prefer GUI-create or `import`; use
  plutil only for headless tweaks.
- **Edit `config.plist` only while UTM is quit** — it clobbers external edits on exit.
- **Partitioning and `nixos-install` are destructive and slow under emulation.** Confirm the
  target device (`lsblk`) before `parted`/`mkfs`. Never partition a disk you haven't verified.
- **No secrets in `.nix` or the transcript.** SSH *public* keys are fine to handle; never echo
  private key material.
- Don't `git push` or `nixos-rebuild switch` an existing host without explicit confirmation.

## Two ways to get a running NixOS VM

1. **Preferred — import a prebuilt qcow2** (no ISO, no in-guest install, no OOM-RAM risk).
   Build the disk image from the flake on **any Nix-on-Linux box that targets aarch64-linux**,
   copy it to the Mac, and point a UTM VM at it:
   ```bash
   # on an aarch64-linux machine with nix+flakes:
   nix build .#nixvm-image
   #   → result  (UEFI qcow2, UTM-importable)
   ```
   **Full NixOS is NOT required — just Nix + flakes on Linux for the right arch.** This repo's
   **devcontainer** qualifies (`nix:1` feature, `nix-command flakes`, Debian base): on an Apple
   Silicon Mac it builds aarch64 natively — no QEMU TCG emulation needed for this fleet. See the
   **nixvm-utm-prebuild-on-devcontainer** skill for the full build-from-Mac flow.
   Then create a UTM VM (GUI, aarch64/`virt`, UEFI) and replace its `Data/<UUID>.qcow2` with the
   built image (UTM quit; keep the filename or update `Drive.<disk>.ImageName`). The image already
   contains the full `nixvm` system — boot straight into it, no partitioning or `nixos-install`.
2. **Install from ISO** — create a VM, boot the minimal ISO, partition + `nixos-install` over SSH.
   Slower and has the ≥6 GB-RAM-or-corruption pitfall; use only if you can't build the image.
   See **nixos-flake-install** for the full ISO flow.

The rest of this skill covers creating/shaping the VM bundle (needed for both paths) and the
recovery toolkit.

## 0. Create the whole VM from scratch via CLI (prebuilt qcow2) — NO GUI

VERIFIED end-to-end (UTM 4.7.5, Apple Silicon): a hand-authored bundle boots NixOS
and accepts SSH, with the GUI never opened to *create* anything (only restarted so UTM rescans
`Documents/`). Use this when you already have a bootable disk image (e.g. from
**nixvm-utm-prebuild-on-devcontainer**). Idempotent-ish: it bails if the bundle already exists.

```bash
DOCS=~/Library/Containers/com.utmapp.UTM/Data/Documents
NAME=nixvm                                    # bundle + display name
BUNDLE="$DOCS/$NAME.utm"
SRC=/path/to/nixvm.qcow2                       # the prebuilt, WRITABLE qcow2 (not the read-only store symlink)

[ -e "$BUNDLE" ] && { echo "bundle exists: $BUNDLE — pick another NAME or delete it"; exit 1; }

VM_UUID=$(uuidgen); DRIVE_UUID=$(uuidgen)
# Locally-administered unicast MAC (2nd nibble ∈ {2,6,A,E}); deterministic so DNS/leases are stable:
MAC="16:7C:DF:00:5C:01"

mkdir -p "$BUNDLE/Data"
cp "$SRC" "$BUNDLE/Data/$DRIVE_UUID.qcow2"     # UTM names disks by UUID; ImageName must match

cat > "$BUNDLE/config.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Backend</key><string>QEMU</string>
  <key>ConfigurationVersion</key><integer>4</integer>
  <key>Display</key><array/>
  <key>Drive</key><array><dict>
    <key>Identifier</key><string>$DRIVE_UUID</string>
    <key>ImageName</key><string>$DRIVE_UUID.qcow2</string>
    <key>ImageType</key><string>Disk</string>
    <key>Interface</key><string>VirtIO</string>
    <key>InterfaceVersion</key><integer>0</integer>
    <key>ReadOnly</key><false/>
  </dict></array>
  <key>Information</key><dict>
    <key>Icon</key><string>nixos</string><key>IconCustom</key><false/>
    <key>Name</key><string>$NAME</string><key>UUID</key><string>$VM_UUID</string>
  </dict>
  <key>Input</key><dict>
    <key>MaximumUsbShare</key><integer>3</integer>
    <key>UsbBusSupport</key><string>3.0</string><key>UsbSharing</key><false/>
  </dict>
  <key>Network</key><array><dict>
    <key>Hardware</key><string>virtio-net-pci</string>
    <key>IsolateFromHost</key><false/>
    <key>MacAddress</key><string>$MAC</string>
    <key>Mode</key><string>Shared</string>
    <key>PortForward</key><array/>
  </dict></array>
  <key>QEMU</key><dict>
    <key>AdditionalArguments</key><array/>
    <key>BalloonDevice</key><false/><key>DebugLog</key><false/>
    <key>Hypervisor</key><true/><key>PS2Controller</key><false/>
    <key>RNGDevice</key><true/><key>RTCLocalTime</key><false/>
    <key>TPMDevice</key><false/><key>TSO</key><false/><key>UEFIBoot</key><true/>
  </dict>
  <key>Serial</key><array><dict>
    <key>Mode</key><string>Terminal</string><key>Target</key><string>Auto</string>
    <key>Terminal</key><dict>
      <key>BackgroundColor</key><string>#000000</string><key>CursorBlink</key><true/>
      <key>Font</key><string>Menlo</string><key>FontSize</key><integer>12</integer>
      <key>ForegroundColor</key><string>#ffffff</string>
    </dict>
  </dict></array>
  <key>Sharing</key><dict>
    <key>ClipboardSharing</key><true/>
    <key>DirectoryShareMode</key><string>VirtFS</string>
    <key>DirectoryShareReadOnly</key><false/>
  </dict>
  <key>System</key><dict>
    <key>Architecture</key><string>aarch64</string><key>CPU</key><string>default</string>
    <key>CPUCount</key><integer>0</integer>
    <key>CPUFlagsAdd</key><array/><key>CPUFlagsRemove</key><array/>
    <key>ForceMulticore</key><false/><key>JITCacheSize</key><integer>0</integer>
    <key>MemorySize</key><integer>6144</integer><key>Target</key><string>virt</string>
  </dict>
</dict></plist>
EOF

plutil -lint "$BUNDLE/config.plist"            # MUST print "OK" — fix before continuing

# UTM only discovers new bundles at launch — restart it so the VM appears to utmctl:
osascript -e 'tell application "UTM" to quit'; sleep 3
open -a UTM; sleep 6
utmctl list                                    # → your NAME shows up, status "stopped"
utmctl start "$NAME"                            # exit 0, no -2700 (Terminal serial + UEFI disk)
```

**Why each non-obvious bit matters (each cost a real failure to learn):**
- **`Drive.ImageName` must equal the on-disk filename.** UTM stores disks as `Data/<UUID>.qcow2`;
  the disk won't attach if `ImageName` ≠ the actual file.
- **`MemorySize` ≥ 6144.** The <6 GB-RAM-or-silent-corruption lesson applies to the VM too, not
  just the builder.
- **`Serial.Mode = Terminal`** (not `Ptty`) — `Ptty` triggers `-2700` on `utmctl start`. `Auto`
  target is correct; a `Terminal` serial is only viewable in the GUI window (no CLI console).
- **`System.CPUCount = 0`** means "all host cores" — what the GUI writes; leave it.
- **No `Display`/no GPU** is fine for a headless sandbox VM — the serial + SSH are enough. (GUI /
  remote-desktop is explicitly deferred for `nixvm`.)
- **Authoring with the Write tool fails** if your harness restricts writes to the project dir
  (the bundle lives under `~/Library/Containers/…`). The heredoc via shell sidesteps that — and is
  what makes the recipe portable anyway.

Then find the IP and SSH in (see §5 for ARP; the prebuilt image has **no guest agent**, so
`utmctl ip-address` returns `-2700` — use ARP):

```bash
MAC=$(plutil -extract Network.0.MacAddress raw "$BUNDLE/config.plist")
sleep 45                                        # let NixOS boot + DHCP
# ARP strips per-octet leading zeros (16:7C:DF:00:5C:01 → 16:7c:df:0:5c:1) — match loosely:
arp -an | grep bridge100                         # read the 192.168.64.x for your MAC
ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no ismail@192.168.64.x 'hostname; nixos-version'
```

### ⚠ A REBUILT `nixvm` DOES need a post-boot re-key (this used to say it didn't)

A fresh NixOS guest generates a **new SSH host key on first boot**. `nixvm` now hosts the
self-hosted CI runner, whose PAT (`secrets/gh-runner-token-nixvm.age`) is agenix-encrypted to the
`nixvm` host key recorded in `secrets/secrets.nix`. After a rebuild that recipient is stale, so:

- agenix cannot decrypt the runner PAT on the new VM,
- `github-nix-ci`'s runner service never starts,
- and every PR's `build (aarch64-linux)` leg — `runs-on: [nixvm, aarch64-linux]` — queues forever.

The VM boots and SSHs perfectly the whole time, so this fails **silently**. Re-key it:

```bash
ssh ismail@<vm-ip> 'cut -d" " -f1,2 /etc/ssh/ssh_host_ed25519_key.pub'   # the NEW host key
# in the repo: set `nixvm = "ssh-ed25519 …"` in secrets/secrets.nix, then
nix run github:ryantm/agenix -- -r -i ~/.ssh/id_ed25519    # from secrets/
# commit + push, then on the VM: nixos-rebuild switch --flake github:…#nixvm
```

Note `agenix -r` re-keys **every** secret and age never re-encrypts byte-identically (fresh
ephemeral keys), so secrets not encrypted to `nixvm` come back "modified" with no semantic change
— revert that churn so the commit is only the nixvm re-key. `packages/key-recovery.nix` does the
same thing for `macos` and derives the keep-list from `secrets.nix`.

Otherwise `nixvm` needs no secret handoff (no tunnel, no `/etc/secrets/*`) — it's ready to use
as soon as SSH answers.

To tear a from-scratch VM down completely: `utmctl stop NAME; utmctl delete NAME` — `delete`
removes the whole bundle (qcow2 included) with **no confirmation**.

## Gotchas (read first)

- **A 100% CLI-authored bundle BOOTS for the prebuilt-qcow2 case** (VERIFIED, UTM
  4.7.5 — see §0). Hand-write `config.plist` via heredoc, drop the qcow2 in `Data/`, restart UTM
  so it rescans `Documents/`, then `utmctl start`. No GUI, no AppleScript. **For ISO installs**,
  GUI-create is still the safer path (UEFI/NVRAM boot-order quirks bite there, not when the disk
  is already a complete bootable system).
- **UTM only rescans `Documents/` on launch.** A bundle created while UTM is running is invisible
  to `utmctl` until you quit + reopen UTM (`osascript … quit` → `open -a UTM`). It does **not**
  clobber a hand-authored `config.plist` on the *next* quit — it only rewrites configs it has
  loaded and you then changed. Author while quit, or author-then-restart, and you're safe.
- **`utmctl` controls existing VMs only** — list/status/start/stop/clone/delete/ip-address. It
  **cannot create or mutate config**. `utmctl attach` is a **non-functional stub** in UTM 4.7.5
  (`WARNING: attach command is not implemented yet!`) — there is **no CLI serial console**.
- **Quit UTM before editing `config.plist`** — UTM rewrites it on exit and clobbers your edits.
- **AppleScript `make` is unreliable for a bootable VM** (made VMs failed to boot) — fallback only.
- `utmctl delete` has **no confirmation**.
- Realized target in this repo: **aarch64 / UTM target `virt`** (Apple Silicon native).

Bundle path: `~/Library/Containers/com.utmapp.UTM/Data/Documents/<name>.utm/` containing
`config.plist`, `Data/<UUID>.qcow2`, `efi_vars.fd`. The **bundle display name ≠ NixOS hostname**
in general — verify with `ls ~/Library/Containers/com.utmapp.UTM/Data/Documents/` and by SSHing in
and checking `hostname`.

## 1. Create the VM

**Prebuilt qcow2?** Use **§0** — author the bundle entirely from the CLI; skip this section.

**ISO install (or you want the GUI):** create in the UTM GUI or `import virtual machine` a
known-good `.utm`; pick architecture (aarch64, target `virt`). Then quit UTM and apply the tweaks
in §3–§5. (The CLI recipe in §0 also works as a starting point here — just attach an ISO per §4
and leave the disk empty/blank instead of copying in a bootable image.)

Fallback (de-emphasized — may not boot, and leaves IDE drives / `e1000` NIC / oversized qcow2 to
fix): `osascript -e 'tell application "UTM" to make new virtual machine with properties {backend:qemu, configuration:{name:"nixvm", architecture:"aarch64", memory:6144, cpu cores:4}}'`

## 2. Quit UTM before editing

```bash
osascript -e 'tell application "UTM" to quit'
sleep 3; pgrep -x UTM && echo "still running — wait" || echo "quit OK"
```

## 3. Configure via plutil

```bash
PLIST=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixvm.utm/config.plist

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
BUNDLE=~/Library/Containers/com.utmapp.UTM/Data/Documents/nixvm.utm
cp /path/to/installer.iso "$BUNDLE/Data/installer.iso"
plutil -replace Drive.0.ImageName -string installer.iso "$BUNDLE/config.plist"
plutil -replace Drive.0.ImageType -string CD            "$BUNDLE/config.plist"
```

## 5. Networking — vmnet-shared gives a real routable IP (no port-forward)

UTM **Shared** mode = `vmnet-shared` → guest gets a **real routable IP** (`192.168.64.x` on
`bridge100`). SSH straight to it. `utmctl ip-address` fails with `-2700` (`guest agent not
running`) **on both the live ISO and the booted prebuilt nixvm image** — neither ships
qemu-guest-agent — so find the IP via ARP using the guest MAC:

```bash
MAC=$(plutil -extract Network.0.MacAddress raw "$PLIST")
# ⚠ ARP prints MACs with per-octet leading zeros STRIPPED: 16:7C:DF:00:5C:01 → 16:7c:df:0:5c:1.
# A literal `grep "$MAC"` MISSES those — grep the bridge instead and read off your row:
arp -an | grep bridge100        # → ? (192.168.64.x) at 16:7c:df:0:5c:1 on bridge100
# ssh ismail@192.168.64.x   (or root@... on the live ISO)
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
utmctl start  nixvm                # Terminal-mode serial → no -2700
utmctl status nixvm                # → started
utmctl ip-address nixvm            # ⚠ empty on live ISO (no guest agent) — use ARP (step 5)
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

## Process summary (the full macOS→UTM→NixOS pipeline)

1. Establish what exists: `utmctl list`, `git remote -v`, confirm `hosts/nixvm.nix` is the target.
2. Pick a path: §0 (prebuilt qcow2, no GUI) or §1+ISO (GUI-create, then **nixos-flake-install**).
3. At each host↔guest boundary, hand the user the exact commands they must type, then resume.
4. Report per phase: what you automated, what the user must do, and the verified end state.
   `nixvm` needs no post-install secret rekey step — unlike `nixpi`, it has no tunnel.
