# nixpi SD-Card Flashing Runbook

This document is the operator walkthrough for flashing the `nixpi` Raspberry Pi 4
NixOS SD image and confirming the Pi actually boots. It exists because a
**silently truncated SD write** cost an entire afternoon (2026-07-06): the Pi
would flash "successfully", flicker its green ACT LED once, then go dark with no
network — over and over. See §1 for the golden rule that would have caught it in
one command.

Everything here is grounded in the repo files:

- `modules/parts/hosts.nix` — exports `nixosConfigurations.nixpi` (the `sdImage` build target), also surfaced as the `nixpi-sd-image` package that CI prebuilds and publishes to the `installer-latest` release
- `hosts/nixpi.nix` — the LIVE Pi profile, including the **scripted-initrd boot fix** (`boot.initrd.systemd.enable = lib.mkForce false`) that is the *other* thing that can hang stage-1
- `hosts/nixpi.nix` + the in-tree `modules/features/cloudflared-connector/` capsule — what `nixpi` does once booted (the Cloudflare Tunnel connector carrying static-key SSH + the Caddy landing page)

---

## 1. TL;DR / golden rule — verify the write ACTUALLY completed

> **A flash is not done when `dd` returns. It is done when `dd` prints a byte
> count equal to the decompressed image's size after several minutes of writing.** A `dd` that returns fast
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
- **Watch the numbers.** A healthy full write of the `nixpi` `sdImage` takes
  **several minutes** to a real SD card. It should end with
  `<N> bytes transferred in <secs> secs`, where `<N>` equals `ls -l` of the
  decompressed image — the same `copied == size` check `nixpi-flash` runs. If `dd` finishes in
  seconds, or never prints a byte count, **assume the write is incomplete and
  re-flash** — do not put the card in the Pi.
- Press **Ctrl-T** during the write to print an in-progress byte count at any
  time (macOS `dd` responds to SIGINFO).

If you remember one thing from this doc: **confirm `dd`'s byte count equals the image's size.**

---

## 2. Get the image — prebuilt (preferred) or build it yourself

The nixpi sdImage bakes **no secrets** (the tunnel token + Wi-Fi are planted on
the FAT `FIRMWARE` partition *after* the flash — see §4b), so it is a pure
function of the flake. CI (`build-installers`) prebuilds it and publishes it to
the rolling `installer-latest` GitHub release, and warms the expensive RPi kernel
into the kattakath Cachix. **You almost never build it by hand.**

The one-command path (`nix run .#nixpi-flash`, §4) handles acquisition for you:

- **`--release`** — download the CI-prebuilt image off `installer-latest`. Needs
  `gh` auth but **no Nix build at all**, so it is fast and cheap. This is the
  normal path and what you want — the Mac *can* build the image itself now (next
  bullet), but this skips a heavy multi-GB build.
- **default (no flag)** — `nix build` the sdImage. The Cachix warm substitutes the
  kernel/intermediates, but the *final* image assembly is an `aarch64-linux` build.
  The client Mac can now do this locally on **Determinate's native Linux builder**
  (except the step in `docs/map/hosts.md` § The one operation it cannot do),
  but that runs on a small ephemeral VM (1 CPU / 8 GiB by default; `determinateNix.determinateNixd.builder.memoryBytes` raises it if the assembly OOMs), so a full SD-image assembly is
  slow there — prefer `--release` unless you specifically want a from-source image.
  (It also completes on any other aarch64-linux builder, e.g. the devcontainer.)
- **`--image FILE.img.zst`** — flash a local prebuilt image you already have.

To build it manually on an aarch64-linux builder:

```bash
git add -A                                                            # flakes ignore untracked files
nix build .#nixosConfigurations.nixpi.config.system.build.sdImage    # → result/sd-image/*.img.zst
ls -lh result/sd-image/                                              # the compressed .img.zst
```

The build output is a **zstd-compressed** `*.img.zst` under
`result/sd-image/`. Decompressed it is a full FAT boot partition +
a multi-GB ext4 root — its `ls -l` size is the byte count you must see land on the card in §4.

---

## 3. Move the image to the Mac and verify it survived the copy

This step only applies if you built the image on a **separate** aarch64-linux
builder. If you used `--release` or built locally on the Mac (via Determinate's
native Linux builder), the image is already on this machine — there is no copy to
verify, so skip straight to §4.

When you did build on a remote box, copy the compressed image over and confirm the
checksum matches the builder — so a corrupt *transfer* isn't mistaken for a bad
*write* later.

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

## 3b. Reflashing a card that FAILED? Image it first — the write destroys the evidence

**Skip this section only if the card is new or you do not care why the last one
died.** Everything else here is reversible; a `dd` over a failed card is not.

This exists because of 2026-10-02. The Pi went dark and the root cause was only
findable from the card itself: `tune2fs -l` reported **`FS Error count: 82`**,
**`First error time: epoch+5s`** and **`Last checked: 1980`** — the filesystem came
off the flash *already corrupt*, which is what identified
`packages/nixpi-provision.nix` verifying only `dd`'s byte count with no read-back
anywhere. One premature flash would have erased the only proof.

**Two things that are easy to get wrong, both corrected here:**

1. **The journal is NOT RAM-only.** `hosts/nixpi.nix` sets
   `services.journald.settings.Journal.Storage = "persistent"`, so the failing
   boot's journal is on the card's ext4 root in `/var/log/journal`. Do not skip
   capture believing a power-cycle already lost it.
2. **`journalctl -b -1` is the wrong tool.** You cannot run it on a host you
   cannot reach, and when the Pi is dark that is the whole problem. Capture happens
   **from the card, on the Mac** — never over SSH.

Rather than read a corrupt filesystem under time pressure, take one full image and
do forensics on the copy, as many times as you like:

```bash
# 1. Identify the reader. It is NOT disk0 (that is the internal Mac SSD).
diskutil list
diskutil unmountDisk /dev/diskN

# 2. Image the WHOLE card, raw device for speed.
sudo /bin/dd if=/dev/rdiskN of="$HOME/nixpi-forensic-$(date +%Y%m%d-%H%M).img" bs=4m
#    Same golden rule as §1, but against the whole CARD, not the image: the byte
#    count MUST equal the "Disk Size … (N Bytes)" of `diskutil info /dev/diskN`.
#    Ctrl-T prints progress. Returns in seconds with no count → incomplete, re-run.

# 3. The FIRMWARE partition is FAT, so macOS mounts it natively. The glob picks
#    up any cmdline.txt.bak a previous recovery's HAND-EDIT left behind.
mkdir -p ~/nixpi-forensic-firmware
cp -a /Volumes/FIRMWARE/cmdline.txt* ~/nixpi-forensic-firmware/
```

On that hand-edit: `hosts/nixpi.nix` now sets `boot.kernelParams` declaratively and
notes that it is rendered into the boot config verbatim (into `cmdline.txt` under
raspberry-pi-nix; into each generation's `extlinux.conf` APPEND line since the move to
nixos-hardware, which leaves `cmdline.txt` unused), *"so this
survives a reflash — unlike the hand-edit that was needed to recover this
incident."* So a fresh card should need no firmware hand-editing at all; finding a
`.bak` there means an earlier recovery predates #795, and the `.bak` is evidence
rather than something to restore.

Once step 2 prints its byte count, **the card is expendable** — proceed to §4.

**Forensics on the image, afterwards and offline.** macOS cannot mount ext4, so
this needs a Linux context (`nix run .#nixvm`, or a Colima container via
`local.containers`). The three readings that diagnosed 2026-10-02:

```bash
tune2fs -l <ext4 partition>      # FS Error count, First/Last error time,
                                 #   Last checked, and Errors behavior — the
                                 #   superblock survives even when the fs will not mount
journalctl -D /var/log/journal   # the persistent journal from the failing boot
journalctl -D /var/log/journal -k | grep -i 'ext4\|EFSCORRUPTED'
```

A card whose superblock already shows a non-zero error count at first boot was either
**written** badly or is **fake-capacity**: first boot's `resize2fs` writes block-group
metadata across the card's whole *claimed* size, and a fake card loses everything past its
real edge — the same `ext4_validate_block_bitmap` / `EFSCORRUPTED` signature. Since #794
`nixpi-flash` reads the card back and `cmp`s it against the image, so a bad *write* now
aborts loudly instead of reporting success — but the read-back covers only the image's
bytes, so it can never catch a bad *card*. That is §3c's job.

**The 2026-10-02 "flasher bug" verdict is probably wrong (inferred, not proven).** That card
reported 33,554,432,000 bytes, was reflashed and put back, and is the card that §3c's f3 run
showed holding only 15.2 GiB on 2026-10-17. Run §3c before blaming the flasher.

---

## 3c. Test the CARD before trusting it — a verified write is not a healthy card

**Do this for every card that is new to nixpi.** A verified flash (§1, and `nixpi-flash`'s
read-back) proves only that the image's bytes landed. It says nothing about the rest of the
card — and nixpi's first boot grows root to the size the card *claims*
(`sdImage.expandOnBoot`, default `true` — nixpkgs' `installer/sd-card/sd-image.nix` since the
move off raspberry-pi-nix). A fake-capacity card accepts every write past its
real size and hands back garbage later, so the image verifies clean, first boot works, and
ext4 corrupts on some later boot once data lands past the real edge.

**Measured 2026-10-17** on nixpi's own "32 GB" card, which the kernel names
`mmcblk0: mmc0:0001 asdfg 31.3 GiB` (a placeholder product name, no brand's model code):
`f3read` reported `Data OK: 15.20 GB` and `Data LOST: 16.01 GB`, every lost sector
*Corrupted* and none *Overwritten* (so no wrap-around). The first bad sector is LBA
31,948,800 — exactly 15,600 MiB, a round number, which points at a programmed limit rather
than wear. A GC plus a reboot then left root with a block-bitmap checksum mismatch.

f3 (nixpkgs `f3`) is the off-the-shelf test. On macOS only `f3write`/`f3read` build —
`f3probe`/`f3fix` do not. It **erases the card**:

```bash
diskutil list                                   # find the card — NOT disk0
diskutil eraseDisk ExFAT F3TEST MBR diskN       # one volume across the whole card
sudo mdutil -i off /Volumes/F3TEST              # f3's docs: Spotlight indexing skews the run
F3=$(nix build --no-link --print-out-paths nixpkgs#f3 | head -1)/bin
"$F3/f3write" -p 1 /Volumes/F3TEST              # fills the card; live %, MB/s and ETA
diskutil eject diskN                            # then PHYSICALLY pull the card and reinsert it
"$F3/f3read" -p 1 /Volumes/F3TEST               # PASS = Data LOST is zero
```

- **The physical reinsert is not optional.** macOS lacks `posix_fadvise(DONTNEED)`, so f3
  cannot drop the cache itself, and f3's docs say to disconnect and reconnect between the two
  steps. Sanity check: `f3read` runs at tens of MB/s on an SD card; a read in the GB/s range
  is coming from the Mac's RAM, not the card.
- **Cost, measured on the 32 GB card:** `f3write` ~34 min at ~16 MB/s, `f3read` ~26 min at
  ~21 MB/s. Steady speed throughout is itself a good sign; a failing card tends to slow or
  stall.
- **Is it stuck?** `-p 1` is f3's own report. For an independent one, run
  `iostat -d -w 5 diskN` in a second terminal: it prints the card's real throughput, and a
  sustained `0.00` MB/s while f3 is still running is a stall.
- **A FAIL is not repairable.** No software fixes a fake or failing card; `f3fix` (Linux-only)
  only shrinks the partition to the real size. Use a different card, or, if you must keep this
  one, cap it below the bad region (§4c).

---

## 4. Flash (macOS) — the verified full-write procedure

```bash
# 1. Identify the SD reader. It is NOT disk0 (that is the internal Mac SSD).
diskutil list
#    Look for an ~external/removable disk the size of your card (e.g. /dev/disk4).
diskutil info /dev/diskN          # double-check: "Removable Media", size, "SD Card Reader"

# 2. Decompress to a plain file FIRST (so dd can report the total byte count).
zstd -d -k -f ~/Downloads/nixos-sd-image-*.img.zst -o /tmp/nixpi.img
ls -l /tmp/nixpi.img              # note the byte count step 4 must match — if it is tiny, the .zst is bad, re-copy (§3)

# 3. Unmount (not eject) so dd can open the raw device.
diskutil unmountDisk /dev/diskN

# 4. Write. Use the RAW device (/dev/rdiskN) — much faster than /dev/diskN.
sudo /bin/dd if=/tmp/nixpi.img of=/dev/rdiskN bs=4m   # /bin/dd: the PATH dd is GNU and rejects bs=4m
#    ^^^ THE CRITICAL STEP. This MUST run for several minutes and end with a line like:
#        <N> bytes transferred in <secs> secs (<rate> bytes/sec)
#    where <N> equals step 2's `ls -l` count (nixpi-flash's own `copied == size` check).
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
  reappear in Finder (as `FIRMWARE`, a small FAT volume) immediately after `dd`
  finishes is **normal** — that is the FAT boot partition, not evidence of a bad
  write. What matters is that the `dd` byte count matched the image's size and that
  `diskutil eject` succeeded / the prompt returned cleanly.

---

## 4b. Plant the connector token + Wi-Fi on the FIRMWARE partition

**Do this after every flash, before first boot.** A fresh flash wipes the whole
card, so the connector token (and Wi-Fi config, if used) must be re-planted onto the
FAT `FIRMWARE` partition each time. `hosts/nixpi.nix` reads them on boot via
`local.firmwareProvisioning` (the in-tree `modules/features/firmware-secrets/`
capsule): each
planted file is copied into a root-only `/run` file before its consumer starts.

**One command does §2–§4b** — build, verified write, and plant, with an `osascript`
confirm dialog:

```bash
nix run .#nixpi-flash -- --disk /dev/diskN            # + --image FILE.img.zst to skip build
```

⚠ **`nixpi-flash` plants only AFTER its `dd`, which runs for several minutes.** If anything
backgrounds or detaches the command in that window — a wrapper's
command timeout, `nohup`, a CI step, an agent shell that moves long jobs to the background —
the plant step loses its controlling terminal.
**The write still succeeded**, so if the plant did not land, re-plant onto the mounted card
with the commands below rather than re-flashing. Run `nixpi-flash` in a real foreground TTY.

⚠ **`READ-BACK MISMATCH` at `char 8390660` is a known FALSE alarm on macOS** (fix deferred).
macOS auto-mounts `FIRMWARE` the moment `dd` finishes and writes `.fseventsd` and
`.Spotlight-V100` into it, so the read-back compares a card macOS has just touched against the
pristine image; byte 8,390,660 is 2,052 bytes into `FIRMWARE` (which starts at 8,388,608). It
reproduced on both 2026-10-17 flashes. It aborts **before** the plant, so confirm the write
yourself and then run `nixpi-provision` (below). A mismatch at any OTHER offset is real —
believe it. Confirmations that can come back red:

- **Root:** `sudo e2fsck -n -f /dev/diskNs2` (nixpkgs `e2fsprogs.bin`) must exit 0, and
  `sudo dumpe2fs -h` must show `Mount count: 0` / `Last mount time: n/a` (an untouched image). For
  bytes, hash the root partition on both sides with **measured** byte counts — slice the image
  stream with `tail -c`/`head -c`, never BSD `dd count=` (on a pipe it counts short reads as
  records and silently returns less).
- **FIRMWARE:** `dd` a copy of `/dev/rdiskNs1`, extract it and the image's FAT with mtools
  (`mcopy -s -i <copy> '::*' <dir>`), and `diff -rq` the two trees; the only extras allowed are
  `.fseventsd` and `.Spotlight-V100`. Don't `mount -t msdos` instead — on macOS 27 the msdosfs
  kext is refused ("Bad code signature"), and a diff of two empty mount points passes.

**Or plant onto an already-flashed, mounted card:**

```bash
nix run .#nixpi-provision                 # token + Wi-Fi (default --all)
nix run .#nixpi-provision -- --token      # just re-plant the token (e.g. after a rotation)
nix run .#nixpi-provision -- --wifi       # just refresh Wi-Fi
```

- **Token** — decrypted from the operator-only vault `secrets/cloudflared-token.age`
  and written as `cloudflared-token`. To refresh it — a FULL apply, so `cf-tunnel-plan` first, and stop
  on any `+ create`, `-/+ replace` or `- destroy` of the Access policy, a change to its
  `include`, or any change to `nixpi_ssh` (`infra/cloudflare/nixpi-tunnel.nix` § ADOPTION IS IMPORT-FIRST) — then
  `cf-tunnel-apply` prints the tunnel's CURRENT token (a data source; no new token; a real
  rotation means replacing the tunnel resource) → `nix run .#nixpi-vault-token` re-encrypts it into
  the vault → re-plant.
  This deliberately does NOT use agenix: agenix binds the token to nixpi's SSH host
  key, but a fresh flash mints a new host key, so the ciphertext would stop
  decrypting and the tunnel would die — and the tunnel is the only remote path in,
  so unrecoverably. A file on the macOS-writable FAT partition is immune.
- **Wi-Fi** — `nix run .#nixpi-provision -- --wifi` writes a `wpa_supplicant.conf` from
  `nix run .#nixpi-wifi-creds`. With no `--ssid` that is the DECLARED ladder,
  `nixpiWifiNetworks` in `modules/parts/identity.nix` (PSKs read from this Mac's keychain) —
  the "No --ssid at all AND a declared ladder" branch in `packages/nixpi-provision.nix`. An
  explicit `--ssid` REPLACES the ladder, so passing one plants a one-AP card. It must carry
  `country=` (the Pi 4 radio is rfkill-blocked without a regulatory domain). Wi-Fi is
  OPTIONAL — without it the Pi is LAN-only. With it, a headless Pi reaches
  `nixpi.kattakath.com` from first boot with no LAN cable, keyboard, or monitor.
- **Plant a FALLBACK AP, not just one.** The declared ladder, `nixpiWifiNetworks` in
  `modules/parts/identity.nix`, is where the fallback is declared, and the blocks come out
  ranked by `priority=`. A hand-typed `--ssid` list is a one-off that REPLACES the ladder
  (above). One AP makes that AP a single point of failure whose recovery is
  this runbook (~40 min): off-site the only route in is the tunnel, and the tunnel
  needs working INTERNET rather than merely a LAN (the LAN sshd path, `local.lanRecovery`,
  helps only when you are on that LAN). Measured 2026-09-22: a two-block config failed
  over to the second AP in ~6 s and reached the internet through it.
- **The wired link does NOT make this redundant** when both interfaces face the same
  router. If that router keeps LAN carrier but loses its uplink, `end0` keeps a
  default route at metric 1002 and beats a working `wlan0` at 3003 — traffic
  blackholes down the wired path. Unplug Ethernet to force the failover.

If you skip planting, the Pi still boots and is reachable on the LAN (`nixpi.local`),
but the Cloudflare tunnel stays down — no `ssh nixpi` and no hosted site — until you
plant the token and reboot.

---

## 4c. Reflashing the CAPPED card — redo the cap before first boot

nixpi's current card is the fake one from §3c, **kept in service by operator choice** with
root capped below its bad region:

| Partition | Start LBA | Sectors | Role |
|---|---|---|---|
| p1 `FIRMWARE` | 16,384 | 262,144 | from the image, untouched |
| p2 `NIXOS_SD` | 278,528 | 29,081,600 | root, **ends at 14 GiB** — below the first bad LBA, 31,948,800 |
| p3, type `0xda` | 29,360,128 | 36,175,872 | **fence** to the card's claimed end (65,536,000 sectors). Never format or mount it |

**Every reflash undoes this.** `dd` writes the image's own MBR (p2 only as large as the image, then free
space), and the next first boot grows root across the whole claimed 31 GiB, straight back into
the bad region. So after §4 and §4b, **before the card goes back in the Pi**, rewrite sector 0.

**Why a fence, not a config option.** The first-boot step (nixpkgs' `expand-root-partition`
service; raspberry-pi-nix's `boot.postBootCommands` before it) runs
`echo ",+," | sfdisk -N$partNum` to grow root into the free space after it, then
`resize2fs`. With p3 right after p2 there is
nothing to grow into: `sfdisk` exits 0 and changes nothing (tested on nixpi's own util-linux
2.42.3, and observed on the Pi on 2026-10-17), and `resize2fs` fills the capped partition.
**`sdImage.expandOnBoot = false` was unsafe under raspberry-pi-nix** — the same `mkIf` gated
`nix-store --load-db`, so the store would be left unregistered and a later GC would treat all
of it as garbage. nixpkgs' module splits that into its own `register-nix-paths` service, so
the option is safe now; the fence stays because it also survives a reflash of this card with
an older image.

```bash
diskutil unmountDisk /dev/diskN
sudo /bin/dd if=/dev/rdiskN of=/tmp/mbr-old.bin bs=512 count=1   # sector 0 = the MBR

# Build the capped MBR with nixpi's OWN sfdisk (an aarch64-linux build, which Determinate's
# native Linux builder runs). Only sector 0 of the sparse file is ever used.
cat > /tmp/mbr-cap.nix <<'EOF'
{ flake, mbr }:
let pkgs = (builtins.getFlake flake).nixosConfigurations.nixpi.pkgs; in
pkgs.runCommand "nixpi-mbr-cap" { nativeBuildInputs = [ pkgs.util-linux ]; } ''
  set -eu
  truncate -s 33554432000 card.img
  dd if=${mbr} of=card.img bs=512 count=1 conv=notrunc status=none
  sfdisk -d card.img | grep -q 'card.img2 : start=      278528,'
  echo ',29081600' | sfdisk -q -N2 --no-reread card.img
  echo 'start=29360128, size=36175872, type=da' | sfdisk -q --append --no-reread card.img
  sfdisk -d card.img > capped.txt
  echo ',+,' | sfdisk -q -N2 --no-reread card.img
  sfdisk -d card.img | cmp - capped.txt
  mkdir "$out"; cp capped.txt "$out/"
  dd if=card.img of="$out/mbr-new.bin" bs=512 count=1 status=none
''
EOF
nix build --impure -o /tmp/mbr-cap -f /tmp/mbr-cap.nix --argstr flake "$PWD" --arg mbr /tmp/mbr-old.bin

# Only partition entries 2 and 3 may differ: 0-based offsets inside 462-493. The disk
# signature (440-443), entry 1 and the boot signature (510-511) must not appear.
cmp -l /tmp/mbr-old.bin /tmp/mbr-cap/mbr-new.bin | awk '{print $1 - 1}' | tr '\n' ' '
sudo /bin/dd if=/tmp/mbr-cap/mbr-new.bin of=/dev/rdiskN bs=512 count=1
sudo /bin/dd if=/dev/rdiskN bs=512 count=1 2>/dev/null | cmp - /tmp/mbr-cap/mbr-new.bin && echo "MBR written"
diskutil list /dev/diskN        # expect: Linux 14.9 GB, then 0xDA 18.5 GB
```

What the build asserts, so a wrong input fails it rather than producing a bad table: the
card's p2 starts at the image's LBA 278,528 (an all-zero MBR is refused), and replaying the
exact first-boot `sfdisk` leaves the capped table unchanged. Run it from the repo root
(`$PWD` is the flake). Its output on 2026-10-17 was byte-identical to the MBR now live on the
card.

**After first boot**, confirm the cap held and the store registered:

```bash
ssh ismail@nixpi.local 'lsblk /dev/mmcblk0; df -h /; ls /nix-path-registration; nix-store -q --hash /run/current-system'
# expect: p2 13.9G + p3 17.3G, / = 14G, "No such file" (first boot ran to completion), a sha256
```

The numbers above are **this card's**. A different fake card needs its own: take the edge from
`f3read`'s `Data OK` (plus the ~40 MB of exFAT overhead in front of the data), cap at least
1 GiB below it, and size p3 to the card's reported sector count.

## 5. First-boot expectations (don't mistake a slow-but-healthy boot for failure)

Insert the card and power the Pi with an adequate supply (**5V / 3A** — see §6).

- **First boot takes ~60-90s**, longer than steady-state reboots, because the
  root filesystem auto-expands to fill the card (on the capped card, to the end of p2 —
  §4c) and fresh SSH host keys are generated on first boot. Measured 2026-10-17 on the
  capped card: tunnel serving within 2 min 15 s of the card leaving the Mac — an upper
  bound, since it includes moving the card to the Pi.
- **The green ACT LED should stay active / blink through boot** (disk + kernel
  activity), not flicker once and die. A single flicker → dark is the
  truncated-write signature (§6).
- Once up, the host publishes `nixpi.local` over mDNS (avahi) — from the WIRED port
  only, so the name needs the cable in (`hosts/nixpi.nix`). Because a fresh
  flash **reuses the `nixpi.local` name with a brand-new host key**, clear the
  stale entry before the first SSH or it aborts with a host-identification
  warning:

```bash
ssh-keygen -R nixpi.local   # clear any stale host key first
```

SSH is the operator's static key (keys-only). On the LAN once mDNS is up:
`ssh ismail@nixpi.local`. **That LAN line only became TRUE on 2026-10-01** — it had
been written here for months while `modules/nixos/core.nix` bound sshd to loopback,
so mDNS resolved and the connection then timed out. `local.lanRecovery`
(`modules/nixos/lan-recovery.nix`) opens sshd's port on `end0`/`wlan0` and makes it
work. **Two consequences for a flash:**

- **A `--release` flash only carries it once CI has republished.** The image comes
  from the rolling `installer-latest` pre-release, rebuilt by
  `build-installers.yml` on any push to `main` touching `hosts/nixpi.nix` or
  `modules/nixos/**`. Flashing `--release` before that workflow finishes writes the
  OLD image — tunnel-only, no LAN path. Check the release is newer than the merge.
- **Verify the LAN path on the FIRST boot, not during the next outage.** It is the
  one ingress a dead `cloudflared` cannot take away, and a flash is the only moment
  you have hands on the hardware to notice it is missing:

```bash
ssh -o ConnectTimeout=5 ismail@nixpi.local true && echo "LAN recovery path LIVE"
```

Remotely (e.g. travelling), over the tunnel:
`ssh ismail@nixpi.kattakath.com` — the `ProxyCommand cloudflared access ssh --hostname
%h` is **declarative now**, in `modules/home/default.nix`'s `Host nixpi.kattakath.com`
block (with `StrictHostKeyChecking accept-new` for exactly the fresh-key case below).
Do **not** hand-edit `~/.ssh/config` to add it — that file is a read-only `/nix/store`
symlink owned by Home Manager; change the module and re-activate. The physical
serial/HDMI console is the break-glass path.

Same fresh-key gotcha applies to the tunnelled name, so after a reflash:
`ssh-keygen -R nixpi.kattakath.com` (`accept-new` still refuses a *changed* key).

**If the tunnel/SSH proxy fails with `cloudflared access ssh: failed to find
Access application`** while the public sites on the same tunnel are still
serving fine — that's not a tunnel/DNS/Pi problem, it's a missing Cloudflare
Zero Trust Access Application for `nixpi.kattakath.com` (declared in
`infra/cloudflare/nixpi-tunnel.nix` as `nixpi_ssh`; restore it with
`cf-tunnel-plan` → `cf-tunnel-apply`).

(Same stale-host-key gotcha every reprovision hits — the name is stable, the key
is not.)

---

## 6. Symptom → cause table

| Symptom | Most likely cause | First action |
|---|---|---|
| Green ACT flickers **once** then goes DARK; Ethernet link LED is up but there is **no DHCP lease / no SSH / no mDNS** | **Truncated SD write** (by far the most common). The FAT boot partition read fine (the flicker), but the ext4 root is half-written so the kernel hangs on `rootwait`. | **Re-flash with a verified full write** (§4) — confirm `dd`'s byte count equals the image's size this time. Only if a *verified* full write still hangs, suspect the scripted-initrd fix (next row). |
| Green ACT blinks normally for a while, then boot stalls with root never mounting (only visible on serial, or as "up but never reachable" after a *known-good* full write) | **systemd-initrd stage-1 hang** — the `linux-rpi` kernel (6.6.x when measured) wedges mounting `/sysroot` under systemd stage-1. The fix (`boot.initrd.systemd.enable = lib.mkForce false`) lives in `hosts/nixpi.nix`; a config change that reintroduces systemd-initrd will hang here. | Confirm `hosts/nixpi.nix` still forces scripted initrd (§8); rebuild the image and re-flash. |
| A verified flash boots and serves fine, then root is **corrupt after a later reboot** (e2fsck: block-bitmap checksum mismatch), or first boot logs `EFSCORRUPTED` | **Fake-capacity card.** The image fits below its real edge, so the flash verifies; writes past the edge (first boot's `resize2fs`, store growth, a GC, the persistent journal) vanish | **f3-test the card** (§3c). On a FAIL, use another card or cap it (§4c) |
| Green ACT **never blinks at all**; only the **red** power LED is on | Firmware can't read the card at all — the Pi never even loads the bootloader off FAT. | Check **power (needs a solid 5V/3A supply — undervoltage is a classic cause), the SD slot, and the card itself** (reseat / try another card). |

---

## 7. Debugging a boot hang with NO serial console (initrd SSH)

When there is no serial cable and the Pi hangs before userspace, you can still
get a shell — put an **SSH server** (OpenSSH, not dropbear, in the pinned nixpkgs'
`initrd-ssh.nix`) in the **scripted** initrd and bring up the
network *before* root is mounted, then SSH in and inspect why the root mount is
failing. This is the technique that actually diagnosed the truncated-write hang.

Add to a **debug** build of `hosts/nixpi.nix` (do not ship this to the live
host):

```nix
boot.kernelParams = [ "ip=dhcp" ];          # bring up eth0 in the initrd
boot.initrd.network.enable = true;
boot.initrd.network.ssh = {
  enable = true;                            # OpenSSH in the SCRIPTED initrd  
  port = 22;
  authorizedKeys = [ "ssh-ed25519 AAAA... your-debug-key" ];
  hostKeys = [ /path/to/an/initrd_host_key ];
};
```

Rebuild, flash (with a **verified full write** — §4, or you'll be debugging the
wrong thing), boot, and:

```bash
ssh root@<pi-dhcp-lease-ip>     # lands in the initrd shell, BEFORE root is mounted
                                #   (the initrd runs no mDNS, so nixpi.local does not resolve)
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
> kernel (6.6.51 when this was measured) the GENET Ethernet driver is **built into the kernel image**, so
> there is no `bcmgenet.ko` / `genet.ko` to load. Listing `bcmgenet` (or
> `genet`) in `availableKernelModules` makes the initrd build fail with a fatal
> missing-module error (`boot.initrd.allowMissingModules` defaults `false`).
> Just set `ip=dhcp` and enable initrd networking — the driver is already there.

---

## 8. Cross-references

- **Scripted-initrd boot fix:** `hosts/nixpi.nix` forces
  `boot.initrd.systemd.enable = lib.mkForce false` (the `tpm2` one is now set by
  nixos-hardware's raspberry-pi/4 module itself — the Pi 4 has no TPM).
  This MUST stay in place; why, and what is still untested on the current kernel, is the
  "SCRIPTED initrd, KEPT" comment above that line in `hosts/nixpi.nix`.
  A systemd-initrd hang is invisible to eval / generic-kernel QEMU — only a real Pi
  (or serial) shows it.
- **What `nixpi` does once booted:** `hosts/nixpi.nix` +
  the `modules/features/cloudflared-connector/` capsule — the Cloudflare Tunnel connector carrying
  Access-gated SSH (`ssh://localhost:22`) and Caddy serving whatever
  `hostedSites` the composing flake passed. **That list lives in THIS repo** —
  `config.fleet.hostedSites` in `modules/parts/identity.nix`, **one entry today**
  (`snoringirl.com`). `mkNixos`'s parameter still defaults to `[ ]`, so a `templates/`
  consumer that passes nothing gets zero vhosts. Token + Wi-Fi are planted per
  §4b (nixpi-firmware-provision skill).
