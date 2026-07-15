# nixpi SD-Card Flashing Runbook

This document is the operator walkthrough for flashing the `nixpi` Raspberry Pi 4
NixOS SD image and confirming the Pi actually boots. It exists because a
**silently truncated SD write** cost an entire afternoon (2026-07-06): the Pi
would flash "successfully", flicker its green ACT LED once, then go dark with no
network — over and over. See §1 for the golden rule that would have caught it in
one command.

Everything here is grounded in the repo files:

- `flake.nix` — exports `nixosConfigurations.nixpi` (the `sdImage` build target) and the `nixpi-installer` variant
- `hosts/nixpi.nix` — the LIVE Pi profile, including the **scripted-initrd boot fix** (`boot.initrd.systemd.enable = lib.mkForce false`) that is the *other* thing that can hang stage-1
- `docs/tunnel-architecture-and-runbook.md` — what `nixpi` does once it is booted (tunnel + ZTIA SSH + Caddy)

---

## 1. TL;DR / golden rule — verify the write ACTUALLY completed

> **A flash is not done when `dd` returns. It is done when `dd` prints a byte
> count of ~5.6 GB after several minutes of writing.** A `dd` that returns fast
> and silent did **not** write the full image — it wrote the small FAT boot
> partition and truncated the multi-GB ext4 ROOT partition. The Pi will load the
> kernel from FAT (one green flicker) and then hang forever on `rootwait`,
> unable to mount the half-written root. No network, no SSH, no mDNS.

The single habit that prevents this:

- **Decompress to a file first, then `dd if=file`** — never pipe
  `zstd -dc image.img.zst | dd`. When `dd` reads from a plain file it knows the
  total size and prints `<N> bytes transferred in <secs> secs` at the end; when
  it reads from a pipe an interrupted/short stream can end early with no visible
  total. The pipe form is exactly what produced the truncated-write failures.
- **Watch the numbers.** A healthy full write of the `nixpi` `sdImage`
  decompresses to **~5.6 GB** and takes **several minutes** (order of 4-6 min to
  a real SD card). It should end with a line like
  `5872025600 bytes transferred in 300 secs (~19 MB/sec)`. If `dd` finishes in
  seconds, or never prints a byte count, **assume the write is incomplete and
  re-flash** — do not put the card in the Pi.
- Press **Ctrl-T** during the write to print an in-progress byte count at any
  time (macOS `dd` responds to SIGINFO).

If you remember one thing from this doc: **confirm the ~5.6 GB byte count.**

---

## 2. Build the image

`nix` is absent on the client Mac (`macos`), so build on an aarch64-linux
builder — the repo's **devcontainer** (Nix-in-Docker on Apple Silicon) or the
`nixvm` aarch64-linux CI runner / any aarch64-linux host.

```bash
git add -A                                                            # flakes ignore untracked files
nix build .#nixosConfigurations.nixpi.config.system.build.sdImage    # → result/sd-image/*.img.zst
ls -lh result/sd-image/                                              # the compressed .img.zst
```

The build output is a **zstd-compressed** `*.img.zst` under
`result/sd-image/`. Decompressed it is **~5.6 GB** (a full FAT boot partition +
a multi-GB ext4 root) — that is the size you must see land on the card in §4.

**Alternative — the installer image.** `flake.nix` also exports a
`nixpi-installer` config whose image is built with
`nix build .#nixosConfigurations.nixpi-installer.config.system.build.sdImage`
(or the `nixpi-installer-image` package). That image boots as
`nixos@nixpi-installer.local` for an SSH-driven bootstrap rather than being the
final system; the flashing procedure below is identical, only the file and its
size differ.

---

## 3. Move the image to the Mac and verify it survived the copy

Copy the compressed image over and confirm the checksum matches the builder —
so a corrupt *transfer* isn't mistaken for a bad *write* later.

```bash
# on the builder:
sha256sum result/sd-image/*.img.zst

# copy to the Mac:
scp <builder>:.../result/sd-image/nixos-sd-image-*.img.zst ~/Downloads/

# on the Mac — must match the builder's sum:
shasum -a 256 ~/Downloads/nixos-sd-image-*.img.zst
```

Only proceed once the two sums are identical.

---

## 4. Flash (macOS) — the verified full-write procedure

```bash
# 1. Identify the SD reader. It is NOT disk0 (that is the internal Mac SSD).
diskutil list
#    Look for an ~external/removable disk the size of your card (e.g. /dev/disk4).
diskutil info /dev/diskN          # double-check: "Removable Media", size, "SD Card Reader"

# 2. Decompress to a plain file FIRST (so dd can report the total byte count).
zstd -d -k -f ~/Downloads/nixos-sd-image-*.img.zst -o /tmp/nixpi.img
ls -lh /tmp/nixpi.img             # EXPECT ~5.6G — if it is tiny, the .zst is bad, re-copy (§3)

# 3. Unmount (not eject) so dd can open the raw device.
diskutil unmountDisk /dev/diskN

# 4. Write. Use the RAW device (/dev/rdiskN) — much faster than /dev/diskN.
sudo dd if=/tmp/nixpi.img of=/dev/rdiskN bs=4m
#    ^^^ THE CRITICAL STEP. This MUST run for several minutes and end with a line like:
#        5872025600 bytes transferred in 300 secs (19573418 bytes/sec)
#    Press Ctrl-T at any time to print an in-progress byte count.
#    If this returns in seconds or prints NO byte count → the write is incomplete.
#    Do NOT boot the card; re-run this step.

# 5. Flush and eject.
sync
diskutil eject /dev/diskN
```

Notes:

- **`/dev/rdiskN` vs `/dev/diskN`:** the `r` (raw) node bypasses the buffer
  cache and writes several times faster. Same disk *number*, different node.
- **Get the disk number right.** `diskutil info /dev/diskN` before every `dd` —
  writing to `disk0` overwrites the Mac's own drive. There is no undo.
- **macOS re-mounts the FIRMWARE partition after the write.** Seeing the card
  reappear in Finder (as `bootfs`/a small FAT volume) immediately after `dd`
  finishes is **normal** — that is the FAT boot partition, not evidence of a bad
  write. What matters is that the `dd` byte count was ~5.6 GB and that
  `diskutil eject` succeeded / the prompt returned cleanly.

---

## 5. First-boot expectations (don't mistake a slow-but-healthy boot for failure)

Insert the card and power the Pi with an adequate supply (**5V / 3A** — see §6).

- **First boot takes ~60-90s**, longer than steady-state reboots, because the
  root filesystem auto-expands to fill the card and fresh SSH host keys are
  generated on first boot.
- **The green ACT LED should stay active / blink through boot** (disk + kernel
  activity), not flicker once and die. A single flicker → dark is the
  truncated-write signature (§6).
- Once up, the host publishes `nixpi.local` over mDNS (avahi). Because a fresh
  flash **reuses the `nixpi.local` name with a brand-new host key**, clear the
  stale entry before the first SSH or it aborts with a host-identification
  warning:

```bash
ssh-keygen -R nixpi.local   # clear any stale host key first
```

The **live** `nixpi` image is cert-only (`removeStaticKey = true`) — LAN static-key
`ssh …@nixpi.local` does **not** work. Confirm the boot over ZTIA (WARP) per
[`tunnel-architecture-and-runbook.md`](tunnel-architecture-and-runbook.md), or via the
physical serial/HDMI console. (The `nixpi-installer` image, by contrast, keeps the
`nixos` user + static key: `ssh nixos@nixpi-installer.local`.)

(Same stale-host-key gotcha every reprovision hits — the name is stable, the key
is not.)

---

## 6. Symptom → cause table

| Symptom | Most likely cause | First action |
|---|---|---|
| Green ACT flickers **once** then goes DARK; Ethernet link LED is up but there is **no DHCP lease / no SSH / no mDNS** | **Truncated SD write** (by far the most common). The FAT boot partition read fine (the flicker), but the ext4 root is half-written so the kernel hangs on `rootwait`. | **Re-flash with a verified full write** (§4) — confirm the ~5.6 GB `dd` byte count this time. Only if a *verified* full write still hangs, suspect the scripted-initrd fix (next row). |
| Green ACT blinks normally for a while, then boot stalls with root never mounting (only visible on serial, or as "up but never reachable" after a *known-good* full write) | **systemd-initrd stage-1 hang** — the `linux-rpi` 6.6.x kernel wedges mounting `/sysroot` under systemd stage-1. The fix (`boot.initrd.systemd.enable = lib.mkForce false`) lives in `hosts/nixpi.nix`; a config change that reintroduces systemd-initrd will hang here. | Confirm `hosts/nixpi.nix` still forces scripted initrd (§8); rebuild the image and re-flash. |
| Green ACT **never blinks at all**; only the **red** power LED is on | Firmware can't read the card at all — the Pi never even loads the bootloader off FAT. | Check **power (needs a solid 5V/3A supply — undervoltage is a classic cause), the SD slot, and the card itself** (reseat / try another card). |

---

## 7. Debugging a boot hang with NO serial console (initrd SSH)

When there is no serial cable and the Pi hangs before userspace, you can still
get a shell — put **dropbear** in the **scripted** initrd and bring up the
network *before* root is mounted, then SSH in and inspect why the root mount is
failing. This is the technique that actually diagnosed the truncated-write hang.

Add to a **debug** build of `hosts/nixpi.nix` (do not ship this to the live
host):

```nix
boot.kernelParams = [ "ip=dhcp" ];          # bring up eth0 in the initrd
boot.initrd.network.enable = true;
boot.initrd.network.ssh = {
  enable = true;                            # dropbear in the SCRIPTED initrd
  port = 22;
  authorizedKeys = [ "ssh-ed25519 AAAA... your-debug-key" ];
  hostKeys = [ /path/to/an/initrd_host_key ];
};
```

Rebuild, flash (with a **verified full write** — §4, or you'll be debugging the
wrong thing), boot, and:

```bash
ssh root@nixpi.local            # lands in the initrd shell, BEFORE root is mounted
dmesg | tail -40                # look for ext4 mount / rootwait errors
ls -l /dev/disk/by-partuuid/    # is the ROOT partuuid even present? (absent ⇒ truncated write)
# then attempt the mount by hand to see the exact failure:
mount /dev/disk/by-partuuid/<root-partuuid> /mnt
```

If `/dev/disk/by-partuuid/` is missing the root partition entirely, the write
was truncated — go re-flash. If the partition is present but the mount fails on
ext4 errors, the card or write is corrupt.

> **CRITICAL gotcha — do NOT add the Ethernet driver to
> `boot.initrd.availableKernelModules`.** On the Pi 4 with the `linux-rpi`
> 6.6.51 kernel the GENET Ethernet driver is **built into the kernel image**, so
> there is no `bcmgenet.ko` / `genet.ko` to load. Listing `bcmgenet` (or
> `genet`) in `availableKernelModules` makes the initrd build fail with a fatal
> missing-module error (`boot.initrd.allowMissingModules` defaults `false`).
> Just set `ip=dhcp` and enable initrd networking — the driver is already there.

---

## 8. Cross-references

- **Scripted-initrd boot fix:** `hosts/nixpi.nix` forces
  `boot.initrd.systemd.enable = lib.mkForce false` (and
  `boot.initrd.systemd.tpm2.enable = lib.mkForce false` — the Pi 4 has no TPM).
  These MUST stay in place; systemd stage-1 hangs mounting root on this kernel.
  A config that reintroduces systemd-initrd will not reboot on this hardware,
  and eval / generic-kernel QEMU will not catch it — only a real Pi (or serial)
  does.
- **What `nixpi` does once booted:**
  [`docs/tunnel-architecture-and-runbook.md`](tunnel-architecture-and-runbook.md)
  — the Cloudflare Tunnel connector, ZTIA SSH (short-lived certs), and Caddy
  serving the `kattakath.com` landing page. First-boot SSH here uses the static
  key over `nixpi.local`; ZTIA layers on afterward per that runbook.
