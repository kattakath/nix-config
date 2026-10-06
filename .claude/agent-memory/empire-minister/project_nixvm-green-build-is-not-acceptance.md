---
name: nixvm-green-build-is-not-acceptance
description: Two nixvm defects that evaluated correctly and built GREEN while being wrong in the guest — a Modes line that cannot create a mode, and useNixStoreImage silently inheriting writableStore=false. Only a booted xrandr/systemctl proves either.
metadata:
  type: project
---

**For `nixvm`, `nix flake check` + a green `system.build.vm` are NOT acceptance.** Two defects
on 2026-10-06 passed every gate and were still wrong inside the guest. Both were found only by
SSHing in (see [[nixvm-ssh-loopback-2222]] — that is what SSH is for).

**How to apply:** for any nixvm change that affects the display, the store, or a session
service, say **"untested, needs a boot"** until you have run the check in the guest. Do not let
a green build stand in for it.

## Defect 1 — a `Modes` line SELECTS, it cannot CREATE

`virtualisation.resolution` feeds `services.xserver.resolutions` (`qemu-vm.nix:1508`) which
renders `Modes "2880x1800"` into the Xorg Screen section. Measured: the conf **did** contain it
at all three depths, and Xorg still logged
`(II) modeset(0): Output Virtual-1 using initial mode 1280x800`, because the probed list held
5120x2160, 3840x2160, 1920x1200, **1440x900** and more but **no 2880x1800**.

**That asymmetry is the trap:** `1440x900` is on the virtio-gpu's list, `2880x1800` is not — so
the old value "worked" and the new one silently did not, with no config difference in quality.

Fix is on the **device**: `-device virtio-gpu-pci,xres=2880,yres=1800`. Verified against the
pinned binary — `qemu-system-aarch64 -device virtio-gpu-pci,help` lists
`xres=<uint32> (default: 1280)` and `yres=<uint32> (default: 800)`. **Those defaults were
exactly the measured guest resolution**, which is what proved the device owns it. `edid=on` is
also default, so the EDID advertises xres/yres as preferred.

### RESOLVED 2026-10-06: 1920x1200 + dpi 192 + Xft.dpi 192, all three verified in the guest

Final, boot-verified state: `xrandr` → `current 1920 x 1200`, the mode marked `59.88*+`
(current **and** preferred); Xorg log `using initial mode 1920x1200` and
`(++) DPI set to (192, 192)`; `xrdb -query` → `Xft.dpi: 192` and
`xfconf-query -c xsettings -p /Xft/DPI` → `192`.

**DPI is NOT scaled to the resolution.** qemu's Cocoa UI divides the framebuffer by the Retina
factor for the window (`ui/cocoa.m:503`) and multiplies back for the framebuffer (`:564-565`),
so one guest pixel is one Mac **device** pixel at every mode. A 12pt font at dpi D is `12*D/72`
device pixels and native macOS puts 12pt at 32, so **D = 192 regardless of the mode** — which
also reproduces the original complaint (96 dpi → 8 points against a native 16, "half size"). A
resolution-proportional value such as 128 lands near 10.7 points and still reads small. The
resolution buys **area**: 1920x1200 → a 960x600 **point** window.

**A rejection line for the WORKING mode is normal.** The log still contains
`Not using mode "1920x1200" (hsync out of range)` **and** uses 1920x1200 — there are 9 Modeline
entries for that resolution at different refresh rates and X drops some while accepting one.
Do not read a single "Not using mode" grep hit as failure; check `using initial mode`.

### How it got there — `xres`/`yres` WORKED and 2880x1800 was STILL rejected

Boot-tested 2026-10-06 with `-device virtio-gpu-pci,xres=2880,yres=1800`:

```
(II) modeset(0): Not using mode "2880x1800" (hsync out of range)
(II) modeset(0): Output Virtual-1 using initial mode 1920x1440 +0+0
```

So there is a **FOURTH** gate nobody had named: even once the device advertises a mode, Xorg's
modesetting driver validates it against the EDID's **sync-frequency limits** and will drop it.
`xres`/`yres` did their job (2880x1800 appears in the probed list, as a *rejected* entry) — the
generated EDID's hsync range does not admit it.

Result moved 1280x800 → **1920x1440**, which is **4:3** and so letterboxes a 16:10 window. Not
the target, not a regression either. **Unresolved at time of writing.** The known-good
candidates are modes that survived validation: `1920x1200` (16:10, no device flag needed) or
`3840x2160` (16:9). Do NOT assume a bigger `xres`/`yres` will stick — validate in a booted
guest.

### THREE independent display layers — fixing one leaves the others

| Layer | Owner | Measured state |
|---|---|---|
| 1. which modes **exist** | the QEMU device (`xres`/`yres`) | was device default 1280x800 |
| 2. X server DPI | `services.xserver.dpi = 192` | **WORKS** — guest log `(++) modeset(0): DPI set to (192, 192)` |
| 3. **`Xft.dpi` for every GTK app** | XFCE's xsettings daemon | **96**, overriding layer 2 |

Layer 3 is the one that keeps apps small. nixpkgs cannot set it — `programs/xfconf.nix` is 32
lines declaring **only `enable`** (re-read 2026-10-06). The **pinned home-manager CAN**:
`modules/misc/xfconf.nix` has `settings` (`:96`), applied via `xfconf-query` (`:138`), gated
`mkIf (cfg.enable && cfg.settings != {})` (`:132`). Not adopted yet — it belongs in the
cross-host `modules/home/` profile and needs host-gating. Manual until then:
`xfconf-query -c xsettings -p /Xft/DPI -s 192`.

## Defect 2 — `useNixStoreImage = true` silently turns nix OFF

`writableStore` default = `cfg.mountHostNixStore` (`qemu-vm.nix:720`); `mountHostNixStore`
default = `!useNixStoreImage && !useBootLoader` (`:899`). So `useNixStoreImage = true` dragged
`writableStore` to **false through two layers nobody chose**. Evaluated before the fix:
`writableStore = false`.

Consequence: `/nix/store` was a **bind of `/nix/.ro-store`, an erofs mounted `ro`**
(`:1448-1469`; `findmnt /nix/store` → `erofs ro,relatime`), and the nix-daemon died on its
first write — `creating directory "/nix/store/.links": Read-only file system`.

`writableStore = true` switches the same stanza to **overlayfs** over a **tmpfs** upper
(`:1470-1474`, `writableStoreUseTmpfs` defaults true), so the per-boot-fresh-store design
survives: the upper layer is RAM, discarded every boot.

**This VM was upstream's own documented failing case** — cite this, it stops anyone
"simplifying" the line away. `nixos/tests/qemu-vm-store.nix` declares
`imageReadOnly = { useNixStoreImage = true; writableStore = false; }` (`:26-28`) and asserts
`imageReadOnly.fail(build_derivation)` (`:56`), against `imageWritable` (`writableStore = true`)
asserted to succeed (`:51`).

### The causal chain — three agents and a live shell to connect it

```
read-only store -> every nix operation fails
                -> home-manager-ismail.service fails on EVERY boot
                -> ~/.zshrc and ~/.zshenv never written
                -> interactive zsh finds no startup files
                -> zsh-newuser-install wizard
```

**The wizard was never a zsh or home-manager bug.** And **Determinate is not implicated**:
upstream's test fails identically with stock nix, and the daemon logged
`accepted connection from pid 1456, user ismail (trusted)` and died only on the write. The
`Authentication failure, s: Permanent` FlakeHub line in the same journal is unrelated noise —
no token in a disposable guest.

**Ruled out, do not retry:** `useNixStoreImage = false` + a 9p host store (loses the fresh-store
design and exposes every path to the macOS `~nix~case~hack~` class, not just the one terminfo
entry — see [[nixvm-initrd-case-hack-blocker]]); swapping Determinate for upstream nix
(upstream's test proves the daemon is irrelevant); skipping nix in HM activation (`activate`
calls `nix-store --realise` and `nix-env --profile --set` unconditionally).

## Verified GREEN in the guest on the same clean boot

`wg`/`wg-quick` present and the `wireguard` module loaded with its four deps; no
`xfce4-screensaver` binary or process; `xset q` → `timeout: 0`; no `gnome-keyring-daemon`;
chromium's wrapper carries `password-store=basic`; the polkit YES-for-wheel rule is in
`/etc/polkit-1/rules.d/10-nixos.rules` with `polkit-gnome` running; **both** `spice-vdagentd`
and `spice-vdagent` running.

## `sudo poweroff` sometimes leaves QEMU alive — INTERMITTENT, 1 of 2

**Corrected the same day I claimed it.** First measurement: `sudo poweroff` returned 0, the
guest went down (sshd dead — `Connection timed out during banner exchange`) and **QEMU stayed
alive 60 s+** holding the qcow2 write lock, state `S`; SIGTERM ended it in ~2 s. I wrote that up
as "does not bring QEMU down". **Second measurement, same VM, same command: QEMU exited on its
own after ~2 s.** So it is **intermittent (1 of 2)**, not deterministic — probably a wedge late
in shutdown, not a missing feature. Neither `-no-shutdown` nor `-no-reboot` is in its argv.

**How to apply:** always use the graceful shutdown (services stop, filesystems flush, no stale
profile locks), then **a bounded poll plus a SIGTERM fallback** — and confirm the process is
gone with `pgrep -x` **and** `lsof` on the qcow2 before relaunching, or the new VM hits the
write lock. Do not describe the wedge as guaranteed; n=2.

## Every store write triggers a full auto-GC against a 1.9 GB tmpfs

Measured after `writableStore = true`. Both `nix-store --realise` and `nix-store --add` printed:

```
running auto-GC to free 8697573376 bytes
waiting for the big garbage collector lock...
```

`min-free`/`max-free` are evaluated against the **overlay's tmpfs upper** (1.9 GB), so nix
thinks it must free 8.7 GB on every write. The writes **succeed** — this is not a failure — but
expect a GC pass per operation, which will make building anything in the guest slow.
**Deliberately not fixed** (2026-10-06, operator's call); recorded so it is not rediscovered.

## Instrument trap recorded

`zsh -i -c 'echo OK'` printed OK and nearly produced a false "wizard is gone" — `-c` does not
reach the newuser path. A real-pty `ssh -tt … zsh -i` hung and produced nothing. The sound
evidence was the **missing dotfiles**, not a shell probe.
