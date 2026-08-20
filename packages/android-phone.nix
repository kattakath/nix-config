# Deterministic ADB wired/wireless operator + scrcpy mirroring.
#
# adb/scrcpy already do the real work (mDNS discovery, TLS pairing, TCP/IP
# bootstrap) — this wrapper just gives their scattered primitives one
# consistent CLI surface instead of remembering which of six adb subcommands
# to reach for. Deliberately does NOT vendor a third-party pairing tool
# (adb-qr, adb-wifi, escrcpy, …): those add an untrusted dependency for
# something adb's own `mdns`/`pair`/`connect` already do — see the escrcpy
# tap removal (2026-07-08, modules/darwin/homebrew.nix) for why this repo
# avoids that. adb/scrcpy themselves come from the `android-platform-tools`/
# `scrcpy` Homebrew formulae (hosts/macos.nix) — resolved dynamically here,
# same pattern as packages/vpn.nix's wg/wg-quick lookup, so this derivation
# has no nixpkgs android-tools dependency to collide with them on PATH.
#
# Nuance this wrapper encodes so you don't have to re-learn it each time:
#   - "pairing port" (Settings > Wireless debugging > Pair device with
#     pairing code) and "connect port" (the main Wireless debugging screen)
#     are DIFFERENT and unrelated — adb pair uses the former, adb connect
#     the latter. `mdns services` distinguishes them via distinct service
#     types (_adb-tls-pairing._tcp vs _adb-tls-connect._tcp).
#   - the connect port changes on Wi-Fi reconnect or device reboot — there
#     is no stable address to hardcode, which is why `connect` auto-resolves
#     from mDNS by default instead of taking a fixed ip:port.
#   - adb's own mDNS cache (separate from the system mDNSResponder — `dns-sd
#     -B` can see a device instantly while `adb mdns services` still reports
#     nothing) can miss a device that started advertising after the daemon
#     last scanned. `mdns_raw` retries once via `adb kill-server`/`start-
#     server` when the first scan comes back empty, before treating it as a
#     real "not found" — confirmed live 2026-08-19, was silently mistaken for
#     a network-level mDNS block until diagnosed with `dns-sd -B`.
#   - adb has NO "unpair"/"forget" primitive — pairing trust can only be
#     revoked ON the device (Settings > Wireless debugging > tap device >
#     Forget). `unpair` here is best-effort: disconnect + jump the device to
#     that settings screen via an intent; it does not fake a real unpair.
{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  findutils,
}:
writeShellApplication {
  name = "android-phone";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    gawk
    findutils
  ];
  excludeShellChecks = [
    "SC2012"
    "SC2016"
    "SC2034"
    "SC2086"
    "SC2318"
  ];
  text = ''
    set -euo pipefail

    # Prefer Homebrew tools on darwin; fall back to PATH (same pattern as
    # packages/vpn.nix's wg/wg-quick resolution).
    ADB="''${ADB:-}"
    SCRCPY="''${SCRCPY:-}"
    if [ -z "$ADB" ]; then
      if [ -x /opt/homebrew/bin/adb ]; then ADB=/opt/homebrew/bin/adb
      elif [ -x /usr/local/bin/adb ]; then ADB=/usr/local/bin/adb
      else ADB=$(command -v adb 2>/dev/null || true)
      fi
    fi
    if [ -z "$SCRCPY" ]; then
      if [ -x /opt/homebrew/bin/scrcpy ]; then SCRCPY=/opt/homebrew/bin/scrcpy
      elif [ -x /usr/local/bin/scrcpy ]; then SCRCPY=/usr/local/bin/scrcpy
      else SCRCPY=$(command -v scrcpy 2>/dev/null || true)
      fi
    fi

    die() { echo "android-phone: $*" >&2; exit 1; }
    info() { echo "android-phone: $*" >&2; }
    ok() { echo "android-phone: $*" >&2; }

    usage() {
      cat >&2 <<'EOF'
    usage: android-phone <command> [args]

    Deterministic wired/wireless ADB + scrcpy mirroring for a physical device.
    (For the VIRTUAL emulator, use `android-emu` instead — unrelated tool.)

      list                    USB devices, connected wireless, discoverable-but-
                              not-yet-paired devices (three clearly labeled sections)
      pair <ip:port> [code]   pair using the code from Settings > Wireless
                              debugging > "Pair device with pairing code"
                              (omit code to be prompted; that screen's ip:port
                              is DIFFERENT from the main wireless-debugging one)
      connect [ip:port]       connect to an already-paired device; with no arg,
                              auto-resolves the sole mDNS-advertised connectable
                              device (errors with a pick-list if there's >1)
      disconnect [ip:port]    disconnect one connection, or all if omitted
      unpair [serial]         best-effort: disconnect + open the device's
                              Wireless debugging settings screen so you can tap
                              Forget — adb has no scriptable unpair, see below
      tcpip [serial] [port]   USB-connected device only: switch it to TCP/IP
                              mode on `port` (default 5555) and connect, without
                              launching a mirror (for adb shell/install workflows)
      wireless [serial]       USB-connected device only: bootstrap to wireless
                              AND start mirroring in one step (delegates to
                              `scrcpy --tcpip`, which does its own IP discovery)
      mirror [serial] [-- scrcpy-args...]
                              start scrcpy; auto-picks the sole authorized
                              device if serial is omitted and only one exists
      doctor                  tool paths, mDNS support, connected devices

    Examples:
      android-phone list
      android-phone pair 192.168.1.50:41273 482910
      android-phone connect
      android-phone wireless
      android-phone mirror -- --stay-awake --turn-screen-off
    EOF
    }

    require_adb() { [ -n "$ADB" ] && [ -x "$ADB" ] || die "adb not found — install the android-platform-tools cask or activate the macos host"; }
    require_scrcpy() { [ -n "$SCRCPY" ] && [ -x "$SCRCPY" ] || die "scrcpy not found — install the scrcpy formula or activate the macos host"; }

    # ---- adb devices -l parsing --------------------------------------------
    # USB lines carry a `usb:` field; already-connected wireless lines have a
    # serial of the form ip:port and no `usb:` field; anything else (emulator-*,
    # unauthorized/offline) is left out of the pretty sections but still shown.
    usb_devices() {
      "$ADB" devices -l 2>/dev/null | tail -n +2 | grep -E '\susb:' || true
    }
    wireless_connected_devices() {
      "$ADB" devices -l 2>/dev/null | tail -n +2 | grep -E '^[0-9]+(\.[0-9]+){3}:[0-9]+\s' || true
    }
    other_devices() {
      "$ADB" devices -l 2>/dev/null | tail -n +2 | grep -vE '\susb:' | grep -vE '^[0-9]+(\.[0-9]+){3}:[0-9]+\s' | grep -v '^$' || true
    }

    # adb can list the SAME physical device twice — once by its resolved
    # ip:port and once by its raw mDNS instance name — when it's both
    # mDNS-paired and explicitly `adb connect`ed; they're two live transports
    # to one device, not two devices. Confirmed live 2026-08-19 on adb 37.0.1.
    # Dedupe by the model:/device: signature adb reports, preferring the
    # ip:port-style serial (stable, scrcpy -s friendly) over the mDNS name.
    dedup_authorized_devices() {
      "$ADB" devices -l 2>/dev/null | tail -n +2 | grep -w device | awk '
        {
          sig = ""
          for (i = 1; i <= NF; i++) if ($i ~ /^model:/ || $i ~ /^device:/) sig = sig $i
          is_ip = ($1 ~ /^[0-9]+(\.[0-9]+){3}:[0-9]+$/) ? 1 : 0
          if (!(sig in best) || is_ip > best_is_ip[sig]) {
            best[sig] = $0
            best_is_ip[sig] = is_ip
          }
        }
        END { for (k in best) print best[k] }
      ' || true
    }

    refresh_adb_server() {
      "$ADB" kill-server >/dev/null 2>&1 || true
      "$ADB" start-server >/dev/null 2>&1 || true
      sleep 2
    }

    # ---- adb mdns services parsing -----------------------------------------
    # Two distinct service types: pairing-mode (device showing a pairing code)
    # and connect-ready (already paired, reachable). Format:
    #   adb-XXXX._adb-tls-connect._tcp. 192.168.1.50:5555
    #
    # adb's own mDNS cache can miss a device that started advertising after
    # the daemon last scanned — confirmed live (2026-08-19): `dns-sd -B`
    # showed the phone's _adb-tls-connect service immediately (system mDNS
    # was never blocked), but `adb mdns services` returned nothing until the
    # server was restarted. Query once; if totally empty, refresh the server
    # and retry once before giving up — this is what makes `connect` (no arg)
    # actually deterministic instead of needing a manual kill-server dance.
    mdns_raw() {
      require_adb
      local out
      out=$("$ADB" mdns services 2>/dev/null || true)
      if [ -z "$out" ]; then
        refresh_adb_server
        out=$("$ADB" mdns services 2>/dev/null || true)
      fi
      echo "$out"
    }

    cmd_list() {
      require_adb
      local usb wireless mdns_raw_out mdns_c mdns_p
      usb=$(usb_devices)
      wireless=$(wireless_connected_devices)
      mdns_raw_out=$(mdns_raw)
      mdns_c=$(echo "$mdns_raw_out" | grep '_adb-tls-connect\._tcp' | awk '{print $NF}' || true)
      mdns_p=$(echo "$mdns_raw_out" | grep '_adb-tls-pairing\._tcp' | awk '{print $NF}' || true)

      echo "USB:"
      if [ -n "$usb" ]; then printf '  %s\n' "$usb"; else echo "  (none)"; fi

      echo "Wireless (connected):"
      if [ -n "$wireless" ]; then printf '  %s\n' "$wireless"; else echo "  (none)"; fi

      echo "Wireless (discoverable via mDNS, not yet connected):"
      if [ -n "$mdns_c" ]; then
        printf '  %s\n' "$mdns_c" | while read -r addr; do
          if echo "$wireless" | grep -q "^$addr"; then continue; fi
          echo "  $addr  (paired — run: android-phone connect $addr)"
        done
      fi
      if [ -n "$mdns_p" ]; then
        printf '  %s\n' "$mdns_p" | while read -r addr; do
          echo "  $addr  (pairing mode — run: android-phone pair $addr)"
        done
      fi
      if [ -z "$mdns_c" ] && [ -z "$mdns_p" ]; then
        echo "  (none, even after an adb server refresh — check Wireless debugging is ON and the phone is on this Wi-Fi network; manual ip:port from the device still works as a last resort)"
      fi
    }

    cmd_pair() {
      require_adb
      local target="''${1:-}" code="''${2:-}"
      [ -n "$target" ] || die "usage: android-phone pair <ip:port> [code] (ip:port from Settings > Wireless debugging > Pair device with pairing code)"
      if [ -n "$code" ]; then
        "$ADB" pair "$target" "$code"
      else
        "$ADB" pair "$target"
      fi
    }

    cmd_connect() {
      require_adb
      local target="''${1:-}" candidates n
      if [ -z "$target" ]; then
        candidates=$(mdns_raw | grep '_adb-tls-connect\._tcp' | awk '{print $NF}' || true)
        n=$(echo "$candidates" | grep -c . || true)
        if [ "''${n:-0}" -eq 0 ]; then
          die "no mDNS-advertised connectable device found — pair first (android-phone pair …), or connect explicitly: android-phone connect <ip:port>"
        elif [ "$n" -gt 1 ]; then
          info "multiple connectable devices found — pick one:"
          printf '  %s\n' "$candidates" >&2
          die "re-run: android-phone connect <ip:port>"
        fi
        target="$candidates"
      fi
      "$ADB" connect "$target"
    }

    cmd_disconnect() {
      require_adb
      local target="''${1:-}"
      if [ -z "$target" ] || [ "$target" = "all" ]; then
        "$ADB" disconnect
        ok "disconnected all wireless connections"
      else
        "$ADB" disconnect "$target"
      fi
    }

    cmd_unpair() {
      require_adb
      local serial="''${1:-}" usb wireless
      if [ -z "$serial" ]; then
        usb=$(usb_devices | awk '{print $1}')
        wireless=$(wireless_connected_devices | awk '{print $1}')
        serial=$(printf '%s\n%s\n' "$usb" "$wireless" | grep -v '^$' | head -1 || true)
        [ -n "$serial" ] || die "no connected device — connect (USB or wireless) first, or pass a serial: android-phone unpair <serial>"
      fi
      info "adb has no scriptable unpair — Android only lets you revoke pairing trust ON the device."
      "$ADB" -s "$serial" shell am start -a android.settings.WIRELESS_DEBUGGING_SETTINGS >/dev/null 2>&1 \
        || "$ADB" -s "$serial" shell am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS >/dev/null 2>&1 \
        || info "could not open settings automatically (older Android?) — go to Settings > Developer options > Wireless debugging yourself"
      "$ADB" disconnect "$serial" >/dev/null 2>&1 || true
      ok "disconnected $serial and opened Wireless debugging settings (if supported) — tap the device under Paired devices > Forget to finish"
    }

    cmd_tcpip() {
      require_adb
      local serial="''${1:-}" port="''${2:-5555}" ip route_out
      if [ -z "$serial" ]; then
        serial=$(usb_devices | awk '{print $1}' | head -1)
        [ -n "$serial" ] || die "no USB device found — connect one first (tcpip bootstrap requires USB)"
      fi
      "$ADB" -s "$serial" tcpip "$port"
      sleep 1
      route_out=$("$ADB" -s "$serial" shell ip route get 1.1.1.1 2>/dev/null || true)
      ip=$(echo "$route_out" | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
      [ -n "$ip" ] || die "could not determine device IP (ip route get failed) — find it manually in Settings > Wireless debugging and run: android-phone connect <ip>:$port"
      "$ADB" connect "$ip:$port"
      ok "connected $ip:$port"
    }

    cmd_wireless() {
      require_adb
      require_scrcpy
      local serial="''${1:-}"
      if [ -n "$serial" ]; then
        "$SCRCPY" "--tcpip=$serial"
      else
        "$SCRCPY" --tcpip
      fi
    }

    cmd_mirror() {
      require_adb
      require_scrcpy
      local serial="''${1:-}" authorized n
      if [ -n "$serial" ] && [ "$serial" != "--" ]; then
        shift
        "$SCRCPY" -s "$serial" "$@"
        return 0
      fi
      authorized=$(dedup_authorized_devices)
      n=$(echo "$authorized" | grep -c . || true)
      if [ "''${n:-0}" -gt 1 ]; then
        info "multiple authorized devices — pick one:"
        printf '  %s\n' "$authorized" >&2
        die "re-run: android-phone mirror <serial>"
      fi
      "$SCRCPY" "$@"
    }

    cmd_doctor() {
      echo "adb:            ''${ADB:-MISSING}"
      echo "scrcpy:         ''${SCRCPY:-MISSING}"
      if [ -n "''${ADB:-}" ] && [ -x "$ADB" ]; then
        echo "adb mdns check: $("$ADB" mdns check 2>&1 | tr '\n' ' ')"
      fi
      echo
      cmd_list
    }

    cmd="''${1:-}"
    if [ -n "$cmd" ]; then shift; fi
    case "$cmd" in
      "" | -h | --help | help) usage; exit 0 ;;
      list | devices | find) cmd_list ;;
      pair) cmd_pair "$@" ;;
      connect) cmd_connect "$@" ;;
      disconnect) cmd_disconnect "$@" ;;
      unpair) cmd_unpair "$@" ;;
      tcpip) cmd_tcpip "$@" ;;
      wireless) cmd_wireless "$@" ;;
      mirror) cmd_mirror "$@" ;;
      doctor) cmd_doctor ;;
      *) die "unknown command: $cmd (try: android-phone --help)" ;;
    esac
  '';
}
