---
name: android-phone
description: >-
  Operate a PHYSICAL Android device over ADB from this Mac — wired or wireless —
  using the fleet `android-phone` CLI (packages/android-phone.nix): pair, connect,
  disconnect, bootstrap USB→TCP/IP, and mirror via scrcpy. Use when the user asks
  to "connect my phone", "pair my android", "adb over wifi", "wireless debugging",
  "mirror my phone screen", "scrcpy", "adb can't see my device", or any ADB
  connectivity/diagnosis task. NOT for the virtual emulator (that is `android-emu`
  / the Android Emulator app) and NOT for driving app UIs (that is the gateway's
  `mobile-mcp` server — this skill gets the device connected so mobile-mcp can).
---

# Android over ADB — the `android-phone` operator

Always reach for the **`android-phone`** wrapper (on PATH via Home Manager) instead of
raw `adb`/`scrcpy` invocations. It encodes several live-diagnosed adb footguns
(documented in `packages/android-phone.nix` in kattakath/nix-config) that raw adb
makes you re-learn every time. `adb` and `scrcpy` themselves come from Homebrew
(`android-platform-tools`, `scrcpy`) — the wrapper resolves them dynamically.

## Command surface

| Command | What it does |
| --- | --- |
| `android-phone list` | Three labeled sections: USB, connected wireless, mDNS-discoverable (paired-connectable vs pairing-mode, each with the exact next command to run) |
| `android-phone pair <ip:port> [code]` | Pair with the code from *Settings → Wireless debugging → Pair device with pairing code* |
| `android-phone connect [ip:port]` | Connect to an already-paired device; with no arg it auto-resolves the sole mDNS-advertised device (errors with a pick-list if >1) |
| `android-phone disconnect [ip:port]` | Drop one wireless connection, or all if omitted |
| `android-phone unpair [serial]` | Best-effort: disconnect + open the device's Wireless-debugging settings so the user can tap Forget |
| `android-phone tcpip [serial] [port]` | USB-connected device → TCP/IP mode (default 5555) + connect, **no** mirror — for `adb shell`/install workflows |
| `android-phone wireless [serial]` | USB device → wireless bootstrap **and** mirroring in one step (`scrcpy --tcpip`) |
| `android-phone mirror [serial] [-- scrcpy-args…]` | Start scrcpy; auto-picks the sole authorized device; pass-through args after `--` (e.g. `-- --stay-awake --turn-screen-off`) |
| `android-phone doctor` | Tool paths, `adb mdns check`, then the full `list` — **run this first when anything misbehaves** |

## The footguns the wrapper absorbs (don't fight them manually)

- **Pairing port ≠ connect port.** The ip:port on the *"Pair device with pairing
  code"* screen is only for `pair`; the main Wireless-debugging screen's ip:port is
  only for `connect`. They are unrelated ports advertised as distinct mDNS service
  types (`_adb-tls-pairing._tcp` vs `_adb-tls-connect._tcp`).
- **The connect port changes** on Wi-Fi reconnect or device reboot — never hardcode
  an ip:port; `connect` with no argument re-resolves from mDNS each time.
- **adb's private mDNS cache goes stale** (separate from macOS's mDNSResponder —
  `dns-sd -B` can see the phone while `adb mdns services` reports nothing). The
  wrapper already retries once through an adb server restart; if `list` still shows
  nothing, the honest causes are Wireless debugging off or a different Wi-Fi
  network, not a local mDNS block.
- **There is no scriptable unpair.** Pairing trust can only be revoked ON the
  device (*Wireless debugging → tap device → Forget*); `unpair` gets the user to
  that screen, nothing more. Don't hunt for an adb flag that doesn't exist.
- **One device can list twice** (ip:port serial + raw mDNS instance name = two
  transports, one phone). The wrapper dedupes for `mirror`; if you parse
  `adb devices -l` yourself, expect duplicates.

## Routing to neighbors

- **Driving app UIs** (tap/type/screenshot inside apps): use the `mobile-mcp`
  gateway server *after* this skill gets the device connected.
- **Virtual emulator**: `android-emu` / the "Android Emulator" Spotlight app —
  unrelated tool, don't point `android-phone` at it.
- **Modifying the tooling itself**: that's a kattakath/nix-config session
  (`packages/android-phone.nix`), rebuilt via `darwin-rebuild switch`.
