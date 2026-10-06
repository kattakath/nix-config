---
name: nixvm-clipboard-qemu-vdagent
description: nixvm's macOS clipboard sharing is raw qemu.options (upstream models only the guest side); the virtserialport needs NO explicit bus=, and it is text-only
metadata:
  type: project
---

`hosts/nixvm.nix` wires macOS↔guest clipboard with three raw
`virtualisation.qemu.options` args (2026-10-06): a `qemu-vdagent` chardev with
`clipboard=on`, `-device virtio-serial-pci`, and a `virtserialport` named
`com.redhat.spice.0`.

**Why raw args and not an option:** grepping the pinned nixpkgs'
`nixos/modules/virtualisation/` for `vdagent` returns **zero hits**. NixOS models only the
GUEST side (`services.spice-vdagentd`). Nothing upstream wires the host chardev. Do not
"fix" these to a nonexistent option.

**The bus-id question, settled by measurement.** An explicit
`-device virtio-serial-pci,id=virtio-serial0` + `bus=virtio-serial0.0` and the implicit
form (no id, no `bus=`) BOTH start cleanly on the qemu this VM runs, even with
`-device virtio-gpu-pci` also enumerated. `info qtree` on the implicit form shows the port
on `bus: virtio-serial-bus.0` with the right chardev and name — note the real bus name is
`virtio-serial-bus.0`, **not** `virtio-serial0.0` (that is an alias derived from the device
id). The implicit form shipped: fewer assumptions.

**TEXT ONLY.** qemu's Cocoa UI registers a `QemuClipboardPeer` for text; there is no image
or file clipboard over this path. Do not promise one.

**UNVERIFIED BY INTERACTION.** Nobody has copied text in a macOS app and pasted it in the
guest — and they cannot yet, because the VM does not build on this Mac
([[nixvm-initrd-case-hack-blocker]]). The guest-side tell once it does boot:
`ps aux | grep spice-vdagent` must show BOTH `spice-vdagentd` and the per-session
`spice-vdagent` client. The client needs no wiring — `pkgs.spice-vdagent` ships
`etc/xdg/autostart/spice-vdagent.desktop`, confirmed present in the built
`vmVariant.system.path` under `etc/xdg/autostart/`.
