# Deterministic ADB wired/wireless operator + scrcpy mirroring.
#
# adb/scrcpy already do the real work (mDNS discovery, TLS pairing, TCP/IP
# bootstrap) — this wrapper just gives their scattered primitives one
# consistent CLI surface instead of remembering which of six adb subcommands
# to reach for. Deliberately does NOT vendor a third-party pairing tool
# (adb-qr, adb-wifi, escrcpy, …): those add an untrusted dependency for
# something adb's own `mdns`/`pair`/`connect` already do — see the escrcpy
# tap removal (2026-07-08, modules/darwin/homebrew.nix) for why this repo
# avoids that. `adb` comes from the `android-platform-tools` Homebrew CASK
# (hosts/macos.nix) — mobile-mcp resolves that same one — so it has no store path
# to bake in and cannot be a `runtimeInput`; it is resolved at RUNTIME instead,
# which also keeps this derivation free of a nixpkgs android-tools dependency
# that would collide with it on PATH.
#
# `scrcpy` MOVED to nixpkgs on 2026-09-29 (modules/home/default.nix), so that half
# of the sentence above no longer holds — but the runtime resolution below is kept
# for it anyway, deliberately: baking in a store path would drag nixpkgs
# android-tools into this derivation's closure as scrcpy's own wrapper dependency,
# which is the PATH collision this header exists to avoid. Resolving from PATH
# picks up the Home Manager profile copy and costs nothing.
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
#   - DEEPER than a cache: adb's DEFAULT (Bonjour) mDNS backend goes blind
#     altogether on this Mac, and a restart does not revive it — only
#     `ADB_MDNS_OPENSCREEN=1` does (measured 2026-10-06, both service types
#     affected). That export is at the top of the script, and because the
#     backend is picked by the adb SERVER at startup, the restart above is what
#     applies it to a server someone else started. Blind discovery is the
#     failure to suspect FIRST when `list` says "(none)" but `dns-sd -B` and
#     `ping` both find the phone.
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

    # mDNS backend: adb ships TWO, and the default (Bonjour) goes BLIND on this Mac.
    # Measured 2026-10-06 with a phone advertising on the LAN the whole time:
    #
    #   adb mdns services, default backend     -> EMPTY, twice, across a restart
    #   adb mdns services, ADB_MDNS_OPENSCREEN -> found the device immediately
    #   dns-sd -B (macOS native)               -> found it the whole time
    #
    # It is blind to BOTH service types, so `list` reported "(none)" while a phone
    # sat there waiting, and the pairing dialog was invisible too — the operator was
    # told nothing was discoverable. Exported rather than passed per-call because the
    # backend is chosen by the adb SERVER at startup; see refresh_adb_server.
    export ADB_MDNS_OPENSCREEN=1

    # adb: prefer the Homebrew CASK's copy, fall back to PATH — see the header, the
    # path is only knowable at runtime. scrcpy keeps the same shape even though it
    # is a nixpkgs package now: its brew branches simply stop matching once
    # `cleanup = "uninstall"` removes the old formula, and PATH then resolves the
    # Home Manager profile copy. Do not "tidy" the brew branches away — a machine
    # mid-migration still has them, and they cost one `test -x`.
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
      doctor                  tool paths, which mDNS backend is live, adb's view
                              vs the SYSTEM's view (they disagree when adb goes
                              blind), and connected devices

    Examples:
      android-phone list
      android-phone pair 192.168.1.50:41273 482910
      android-phone connect
      android-phone wireless
      android-phone mirror -- --stay-awake --turn-screen-off
    EOF
    }

    require_adb() { [ -n "$ADB" ] && [ -x "$ADB" ] || die "adb not found — install the android-platform-tools cask or activate the macos host"; }
    require_scrcpy() { [ -n "$SCRCPY" ] && [ -x "$SCRCPY" ] || die "scrcpy not found — activate the macos host (it is a nixpkgs package in home.packages), or put scrcpy on PATH"; }

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

    # Restarting is ALSO how the openscreen backend gets applied to a server this
    # wrapper did not start: ADB_MDNS_OPENSCREEN is read by the SERVER at startup, so
    # exporting it cannot convert one already running under Bonjour (Android Studio,
    # a bare `adb` in another shell, or a pre-existing session all leave one behind).
    # kill-server then start-server re-execs it with the export inherited.
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
    #
    # 2026-10-06: the restart ALONE was measured INSUFFICIENT — an empty list
    # stayed empty across kill-server/start-server, and only the openscreen
    # backend found the device. The retry survives because the restart is now
    # what applies that backend (see refresh_adb_server), so the two work
    # together; do not drop either half believing the other covers it.
    # macOS's own mDNS resolver, as a SECOND instrument of a different shape. It
    # found the phone on EVERY attempt on 2026-10-06 — including while adb's view
    # was empty — and it is what diagnosed the blindness in the first place. Emits
    # the same three fields mdns_raw's callers parse: instance, service type,
    # ip:port. /usr/bin/dns-sd and /usr/bin/dscacheutil are macOS SYSTEM tools, so
    # this is a runtime probe rather than a runtimeInputs entry — nothing to add to
    # the closure, and nothing for nixpkgs to package.
    #
    # The guard is DEFENSIVE, not load-bearing: this package is macOS-only today
    # (home.packages adds it under `lib.optionals isMacosHost`, and there is no
    # packages.aarch64-linux.android-phone output — verified 2026-10-06, after an
    # earlier draft of this comment claimed the opposite). It costs one `test -x`
    # and keeps a `die` out of a non-Darwin path if that ever changes.
    mdns_via_system() {
      [ -x /usr/bin/dns-sd ] && [ -x /usr/bin/dscacheutil ] || return 0
      local svc inst hostport host port ip
      for svc in _adb-tls-connect._tcp _adb-tls-pairing._tcp; do
        inst=$(timeout 4 /usr/bin/dns-sd -B "$svc" 2>/dev/null |
          awk -v s="$svc." '$0 ~ s { for (j = 7; j <= NF; j++) printf "%s%s", $j, (j < NF ? " " : ""); print "" }' |
          tail -1) || true
        [ -n "$inst" ] || continue
        hostport=$(timeout 5 /usr/bin/dns-sd -L "$inst" "$svc" 2>/dev/null |
          grep -oE '[A-Za-z0-9._-]+\.local\.:[0-9]+' | tail -1) || true
        [ -n "$hostport" ] || continue
        host=''${hostport%%:*}
        port=''${hostport##*:}
        # dns-sd -G's own output is awkward to parse reliably; dscacheutil answers
        # the same question in one field and was the form that worked when measured.
        ip=$(/usr/bin/dscacheutil -q host -a name "''${host%.}" 2>/dev/null |
          awk '/^ip_address:/ { print $2; exit }') || true
        [ -n "$ip" ] || continue
        printf '%s\t%s.\t%s:%s\n' "$inst" "$svc" "$ip" "$port"
      done
    }

    has_services() { printf '%s' "''${1:-}" | grep -q '_adb-tls-'; }

    mdns_raw() {
      require_adb
      local out deadline
      out=$("$ADB" mdns services 2>/dev/null || true)

      # Test for SERVICE LINES, never for emptiness. `adb mdns services` always
      # prints its 32-byte "List of discovered mdns services" header (measured with
      # od -c, 2026-10-06), so the old `[ -z "$out" ]` was never true and this whole
      # retry was DEAD CODE — which is the real reason "the restart doesn't help"
      # was observed: the restart never ran.
      if ! has_services "$out"; then
        refresh_adb_server
        # Poll, because one post-restart query is a coin flip: time-to-first-service
        # measured 0s, 13s, and once not at all within 30s across three trials. The
        # backend has to catch the phone's next advertisement, and Wi-Fi power saving
        # makes that sporadic.
        deadline=$(($(date +%s) + 15))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          out=$("$ADB" mdns services 2>/dev/null || true)
          if has_services "$out"; then break; fi
          "$ADB" devices >/dev/null 2>&1 || true
        done
      fi

      # Still nothing from adb: ask the OS, which disagreed with adb every time it
      # mattered. A disagreement here is the signal to trust, not to average.
      if ! has_services "$out"; then
        out=$(mdns_via_system) || true
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
          # NOT "(paired)". This label is derived from the mDNS SERVICE TYPE, and
          # _adb-tls-connect._tcp is advertised whenever Wireless debugging is ON,
          # paired or not. Calling it "paired" was a FALSE ALL-CLEAR on 2026-10-06:
          # trust had been revoked, the label said paired, and the real failure
          # (needs re-pairing) was hunted as a network problem instead. Only an
          # actual `connect` can tell the two apart.
          echo "  $addr  (connectable — run: android-phone connect $addr; if it fails, trust was revoked and you need 'pair' with a code)"
        done
      fi
      if [ -n "$mdns_p" ]; then
        printf '  %s\n' "$mdns_p" | while read -r addr; do
          echo "  $addr  (pairing mode — run: android-phone pair $addr)"
        done
      fi
      if [ -z "$mdns_c" ] && [ -z "$mdns_p" ]; then
        echo "  (none — after an adb server refresh, a 15s poll AND a macOS mDNS cross-check all came back empty, so this is a real not-found rather than adb's backend going blind. Check Wireless debugging is ON and the phone is on this Wi-Fi network; 'android-phone doctor' shows both views, and a manual ip:port from the device still works as a last resort)"
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

      # Drop adb's OWN duplicate. adb auto-connects mDNS-advertised devices under
      # their service name, so after an explicit ip:port connect the SAME phone can
      # appear twice — `10.0.0.250:44089` and `adb-XXXX._adb-tls-connect._tcp`. Every
      # bare `adb shell` then dies with "adb: more than one device/emulator", which
      # reads like a second phone is attached. Measured twice on 2026-10-06, once
      # while reading package lists, where it silently turned real answers into
      # "absent" for every package queried.
      local dupe
      dupe=$("$ADB" devices 2>/dev/null | awk '/^adb-.*_adb-tls-connect\._tcp[[:space:]]/ { print $1 }' | head -1) || true
      if [ -n "''${dupe:-}" ]; then
        "$ADB" disconnect "$dupe" >/dev/null 2>&1 || true
        info "dropped adb's duplicate mDNS transport for the same device ($dupe) so bare 'adb shell' keeps working"
      fi
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
        # NOT `adb mdns check` — it printed "adb discovery 0.0.0" under BOTH
        # backends while one of them was returning nothing (2026-10-06), so it
        # cannot discriminate working discovery from blind discovery and reads as
        # reassuring either way. `mdns services` is the real signal: a count of
        # what was actually found, with the backend named so a zero is diagnosable.
        # Not ''${V:+a}''${V:-b} — when V is SET, ''${V:-b} expands to V's VALUE, so that
        # pair printed "openscreen (…)1". Measured, then written as a plain branch.
        if [ -n "''${ADB_MDNS_OPENSCREEN:-}" ]; then
          echo "mdns backend:   openscreen (ADB_MDNS_OPENSCREEN=$ADB_MDNS_OPENSCREEN)"
        else
          echo "mdns backend:   bonjour (adb default — measured BLIND on macOS; the wrapper exports openscreen, so seeing this means something unset it)"
        fi
        # ONE query, reused: mdns_raw can poll for up to 15s, so calling it per
        # field would make `doctor` take a minute and report three different scans.
        local svcs
        svcs=$(mdns_raw)
        echo "adb mdns view:  $(printf '%s' "$svcs" | grep -c '_adb-tls-connect\._tcp' || true) connect, $(printf '%s' "$svcs" | grep -c '_adb-tls-pairing\._tcp' || true) pairing"
        if [ -x /usr/bin/dns-sd ]; then
          echo "system mdns:    $(mdns_via_system | grep -c '_adb-tls-' || true) advertised (independent cross-check — if this is non-zero while the line above is 0, adb's backend is blind, not the network)"
        fi
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
