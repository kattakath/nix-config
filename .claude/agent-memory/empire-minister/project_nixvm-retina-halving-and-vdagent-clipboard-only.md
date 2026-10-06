---
name: nixvm-retina-halving-and-vdagent-clipboard-only
description: qemu's Cocoa UI DIVIDES the guest framebuffer by the Retina factor, so nixvm rendered half-size; fix is resolution AND dpi together. qemu-vdagent is clipboard-ONLY — window resize never reflows the guest.
metadata:
  type: project
---

Two measured facts about `nixvm`'s display on this Mac. Both landed in `08a7006` (2026-10-06).

## The window was half-size, and it is qemu's Cocoa UI doing it

`ui/cocoa.m:503` in qemu 11.1.1:

```c
CGFloat width = screen.width / [[self window] backingScaleFactor];
```

It treats the guest framebuffer as **device** pixels and divides by the Retina factor (2 here),
so `1440x900` arrived as a ~`720x450` **point** window — sharp, and half-size.

**Resolution and DPI are a PAIR. Never move one alone.** `virtualisation.resolution` feeds
`services.xserver.resolutions = mkVMOverride [ cfg.resolution ]` (`qemu-vm.nix:1508`) — an Xorg
**mode list**, not a qemu device property. Raising it alone spreads the same point-size fonts
over more pixels: bigger window, **smaller** text. Current values: `2880x1800` in
`hosts/nixvm.nix` + `services.xserver.dpi = 192` in `modules/nixos/desktop-vm.nix` (which owns
the whole `services.xserver` block and is gated on `local.desktopVm.enable`).

- 16:10 preserved → no letterbox on the built-in panel, **will** letterbox on a 16:9 external.
- Cost: 4x pixels on an emulated virtio-gpu. **Halve the pair first** if the desktop drags.
- Per-app smallness has no declarative lever at this pin: `xfce.nix:170` only flips
  `programs.xfconf.enable`, so XFCE's `/Xft/DPI` is manual (`xfconf-query -c xsettings -p
  /Xft/DPI`).

## `qemu-vdagent` is CLIPBOARD-ONLY — the old comment claiming auto-resize was false

Verified in the pinned qemu 11.1.1 source, `ui/vdagent.c` (tarball unpacked from the drv this
VM's runner executes, not from memory):

- `vdagent_chr_recv_msg` (`:732`) switches on **six** types: `VD_AGENT_ANNOUNCE_CAPABILITIES`
  (`:737`) and `VD_AGENT_CLIPBOARD{,_GRAB,_REQUEST,_RELEASE}` (`:740-743`), then
  `default: break;` (`:748`).
- `VD_AGENT_MONITORS_CONFIG` and `VD_AGENT_DISPLAY_CONFIG` appear **only** in the `msg_name[]`
  trace table (`:95`, `:98`). They are never a case.

**Consequence:** dragging or fullscreening the QEMU window **never** reflows the guest desktop.
The guest keeps whatever mode Xorg got at start. That is why the resolution/DPI pair is the real
fix and why no one should wait for auto-resize to kick in.

**How to apply:** if a future task wants dynamic resize, `qemu-vdagent` cannot provide it — that
needs a real SPICE server (`-spice` + `spice-app`/client), which would cost the native Cocoa
window this VM is configured for. See [[nixvm-clipboard-qemu-vdagent]] for the clipboard half.
