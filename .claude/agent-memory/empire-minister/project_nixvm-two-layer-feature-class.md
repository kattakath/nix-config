---
name: nixvm-two-layer-feature-class
description: FOUR nixvm features need a host QEMU arg AND a guest service, and either half alone is a silent no-op with a green build — clipboard, display, SSH, audio. Check both sides before diagnosing.
metadata:
  type: project
---

**Every nixvm integration so far has TWO halves, and one half alone builds green and does
nothing.** Treat this as the default shape, not a coincidence — it has caught four features.

| Feature | Host half (`hosts/nixvm.nix`) | Guest half (`modules/nixos/desktop-vm.nix`) |
|---|---|---|
| Clipboard | `-chardev qemu-vdagent` + `virtserialport` | `services.spice-vdagentd.enable` |
| Display | `-device virtio-gpu-pci,xres=,yres=` | `services.xserver.dpi` + HM `xfconf` `Xft/DPI` |
| SSH | `virtualisation.forwardPorts` | `listenAddresses` mkForce + `openFirewall` |
| Audio | `-audiodev coreaudio` + `virtio-sound-pci` | `services.pipewire.*` + `security.rtkit.enable` |

**How to apply:** when a nixvm feature "does not work", ask which half is missing **before**
debugging either one. And never report a half-landed feature as done on a green build — see
[[nixvm-green-build-is-not-acceptance]].

## Audio specifics (shipped `2b9ccd1`, 2026-10-06, NOT boot-tested)

- The guest had **no card at all**: `/proc/asound/cards` absent, only generic
  `snd`/`snd_seq*`/`snd_timer` loaded. Nothing in the fleet configured audio
  (`grep -rn "pipewire\|pulseaudio\|rtkit" modules/ hosts/` → **0**).
- `grepped qemu-vm.nix for audio/soundhw/audiodev — ZERO hits in 1,559 lines` → no upstream
  option owns QEMU audio, so raw `qemu.options` is the lane.
- `-audiodev help` on the pinned binary: `none, coreaudio, dbus, spice, wav`. **coreaudio** is
  the only one that reaches the Mac's speakers.
- `virtio-sound-pci` chosen over `intel-hda`: paravirtualised, ONE device instead of controller
  + separate `hda-duplex` codec, consistent with the file's other virtio choices. **Named
  fallback if `snd_virtio` does not bind:** `-device intel-hda` + `-device
  hda-duplex,audiodev=snd0`. Guest kernel has both `CONFIG_SND_VIRTIO=m` and
  `CONFIG_SND_HDA_INTEL=m`.
- **Do not hand-add `xfce4-pulseaudio-plugin` or `pavucontrol`** — `xfce.nix:150-157` adds both
  once `services.pipewire.pulse.enable` is true. Verified in the closure:
  `xfce4-pulseaudio-plugin-0.5.1`, `pavucontrol-6.2`, and `xfce4-volumed-pulse` correctly
  **absent** (that one is only for `noDesktop`).
- **`pipewire.service` showing MASKED with audio off is normal** — NixOS's representation of
  `enable = false` when a closure package ships the units. Never unmask by hand.
- **`services.pulseaudio` is renamed at this pin** (`mkRenamedOptionModule`,
  `pulseaudio.nix:95`) and is mutually exclusive with pulse emulation. Leave it alone.
- `rtkit` authorises realtime priority **through polkit**
  (`org.freedesktop.RealtimeKit1`), which the wheel-YES rule already covers — so it adds no
  unanswerable prompt (see [[nixvm-autologin-locker-lockout-trap]]).
- **`alsa-utils` is NOT in the closure**, so there is no `speaker-test` in the guest. An
  audibility check has to be a browser or another player. Not added; flagged.
