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

## Audio: VERIFIED WORKING in a booted guest, 2026-10-06

`/proc/asound/cards` → `0 [SoundCard]: virtio-snd - VirtIO SoundCard at pci/0000:00:07.0/virtio6`;
`virtio_snd` bound with `snd_pcm`/`snd_timer`/`snd`/`soundcore`; PCM nodes `pcm0p` + `pcm0c`
present; `wpctl status` → Device 44 `Virtio 1.0 sound (QEMU) [alsa]`, **Sink 48 default**
`Virtio 1.0 sound (QEMU) Stereo [vol: 0.40]`, Source 52; `wpctl inspect @DEFAULT_AUDIO_SINK@`
→ `alsa.driver_name = "virtio_snd"`; `rtkit-daemon` **active**. The `virtio-sound-pci` fallback
to `intel-hda` was NOT needed. **Audibility is unverified — no agent has ears.**

### THE CAPTURE HALF IS BROKEN, and I missed it by not reading the host log

QEMU printed this **four times** at launch, and I only found it afterwards because I was
reading the GUEST and never looked at the tail of my own launch log:

```
qemu-system-aarch64: -device virtio-sound-pci,audiodev=snd0: audio: Can not open `virtio-sound.in' (no host audio driver)
qemu-system-aarch64: audio: Can not open `virtio-sound.in' (no host audio driver)   (x3 more)
```

**Playback is fine** — the guest got a card and a default sink, and QEMU continues past this.
What fails is the **input/capture** stream. Near-certain cause: macOS **microphone TCC**. A QEMU
launched from a terminal has no mic grant, so coreaudio's input device cannot be opened. The
guest still *shows* a Source (`52. Virtio 1.0 sound (QEMU) Stereo`) because the virtio device
exposes one regardless; it just has no host backend behind it.

**Not fixed** (2026-10-06 — the task in flight was docs-only). Candidate fix when it is wanted:
give the audiodev no input voices, e.g. `-audiodev coreaudio,id=snd0,in.voices=0`, which stops
QEMU trying to open a capture device at all. **Verify the property exists** on the pinned binary
first (`-audiodev coreaudio,help`).

**THE LESSON, and it is mine:** I verified the guest exhaustively and declared audio PASS while
four host-side errors sat unread in the launch log I had created. **Read the host launch log as
part of acceptance, not only the guest.** For a two-layer feature there are two logs.

### THREE instrument traps, all of which produced a wrong answer first

1. **`wpctl status` raced wireplumber by one second** and reported `Devices:` and `Sinks:` EMPTY.
   Re-queried minutes later, both were populated. I nearly reported audio as FAILED. PipeWire is
   **socket-activated**, so a query can be the thing that starts it — then immediately read it
   before enumeration finishes. Query twice, seconds apart.
2. **`pactl` is NOT on PATH** with `services.pipewire.pulse.enable` — `pulseaudio`'s CLI is not
   in `systemPackages`, only its libs. `pactl info` exits 127, which reads like a broken stack.
   Use **`wpctl status`**, `wpctl inspect @DEFAULT_AUDIO_SINK@`, or `pw-dump`.
3. **`systemctl --user status pipewire` says `inactive (dead)` and that is NORMAL** — the
   `.socket` units are what stay `active (listening)`. Check the sockets, or `ps`, not the
   service.

Also: `alsa-utils` is absent (operator declined it), so there is **no `speaker-test`** — an
audibility check must be a browser or another player. And the default sink comes up at
**40% volume**, which is worth checking before concluding "no sound".

## Audio specifics as shipped (`2b9ccd1`)

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
