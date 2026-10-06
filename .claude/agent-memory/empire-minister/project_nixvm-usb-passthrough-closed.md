---
name: nixvm-usb-passthrough-closed
description: CLOSED 2026-10-06 — nixvm gets no USB passthrough, operator's decision. No qemu.options line can fix it (libusb needs an Apple capture entitlement); usbipd-mac was denied by Apple; VirtualHere excludes HID. GPG/SSH need no passthrough at all.
metadata:
  type: project
---

**USB passthrough into `nixvm` is a CLOSED question. Do not re-attempt or re-research it.**
Operator's decision 2026-10-06: **keep `nixvm` as it is, accept no USB.** Also recorded in
`hosts/nixvm.nix` above `qemu.options`, so someone reading the host file finds it without
knowing to look here.

**Why:** every host-side route is blocked by Apple, not by this repo's configuration.

| Route | Why it fails |
|---|---|
| `-device usb-host` | **No `qemu.options` line fixes this.** The backend is real — the pinned binary links `libusb-1.0.30` and carries `host-libusb.c` strings — but libusb on macOS can only capture a WHOLE device and needs an Apple **capture entitlement** to detach a kernel driver. Apple class drivers claim mass storage, HID, audio, video and CDC-serial. |
| `-device u2f-passthru` | **Absent in this build**, measured: `-device u2f-passthru,help` → `Device 'u2f-passthru' not found`. The one class with a purpose-built non-libusb path has no path here. |
| USB/IP | **Structurally impossible host-side.** `usbipd-mac`'s DriverKit USB-transport entitlement was **DENIED by Apple 2026-02-25**, redirected to the *import* entitlement — the opposite capability. nixpkgs' `usbip` is the Linux **client** half only (built from `kernel.src`). |
| VirtualHere ($49) | **Does not work**, and it is the obvious-looking cheap fix. Its macOS server excludes **HID**, audio, video and Bluetooth by Apple policy post-10.15; a YubiKey's HID interface — the device that prompted the ask — specifically fails. |

**The only working routes LEAVE QEMU:** Parallels (~$100, mature, field-proven
YubiKey→Linux on Apple Silicon) or UTM (free; PR #7877 merged 2026-09-18 using macOS 27's
`VZUSBPassthroughDevice`/`AccessoryAccess.framework`, but issue #7914 — `VZErrorDomain error -6`
on any device assign — was still open at time of writing).

**What a move would cost, if it is ever reconsidered:** the NixOS guest, sshd, the HM profile and
the PGP stack all survive. **Lost:** `nix run .#nixvm`, every QEMU-specific audio/display/
clipboard option (see [[nixvm-two-layer-feature-class]]), and the declarative
`virtualisation.vmVariant` round-trip.

## THE CONSOLATION, and it is a complete answer for the two cases that actually prompted this

**GPG and SSH need NO passthrough at all.** If the narrow question returns, this is the answer:

- **GPG** — forward the Mac's agent socket into the guest rather than the token:
  `RemoteForward /run/user/1000/gnupg/S.gpg-agent <output of
  `gpgconf --list-dirs agent-extra-socket` on the Mac>` with **`StreamLocalBindUnlink yes`**
  (without it the second connection fails on a stale socket). The *extra* socket is the right
  one — it is the restricted variant intended for forwarding.
- **SSH** — plain `ssh -A` (agent forwarding). Nothing else needed.

So "I need my YubiKey in the VM" is usually really "I need to sign/auth from the VM", and that
has a working answer today. Only genuinely device-level needs (flashing, mass storage, serial,
webcam) are actually blocked.
