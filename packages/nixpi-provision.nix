# nixpi provisioning toolkit — the macOS-side, all-Nix companion to
# modules/nixos/firmware-provisioning.nix. Returns four `writeShellApplication`s
# (shellcheck'd at `nix flake check`), wired as flake apps in flake.nix:
#
#   nix run .#nixpi-flash       — build + verified dd + auto-plant (fresh reflash)
#   nix run .#nixpi-provision   — plant token/wifi onto a mounted card (update either)
#   nix run .#nixpi-wifi-creds  — emit a wpa_supplicant.conf from the Mac's Wi-Fi
#   nix run .#nixpi-vault-token — re-encrypt a new connector token into the vault (rotate)
#
# These are the ONLY supported way to provision an SD card, so the runbook is
# executable, not prose. Design notes:
#   * The SD card's FAT FIRMWARE partition is the one thing macOS can write, so it
#     carries the secrets a fresh flash needs (host-key-independent — see the module
#     and hosts/nixpi.nix for why NOT agenix).
#   * macOS-only tools are called by absolute path (house style — cf. key-recovery.nix);
#     age/zstd/grep/etc. are pinned via runtimeInputs.
#   * The token vault (secrets/cloudflared-token.age) is read from the WORKING TREE
#     (run these from the repo root) so a freshly `nixpi-vault-token`-ed token is
#     planted without a rebuild.
{
  writeShellApplication,
  age,
  zstd,
  coreutils,
  gnugrep,
  gnused,
  gawk,
}:
let
  operatorKey = "$HOME/.ssh/id_ed25519";
  vault = "secrets/cloudflared-token.age";

  # Shared: echo the mount point of the FAT volume named FIRMWARE, or fail.
  firmwareMountFn = ''
    firmware_mount() {
      local mp
      mp=$(/usr/sbin/diskutil info -plist FIRMWARE 2>/dev/null \
            | /usr/bin/plutil -extract MountPoint raw - 2>/dev/null) || true
      if [ -z "''${mp:-}" ] || [ "$mp" = "(null)" ] || [ ! -d "$mp" ]; then
        echo "nixpi: FIRMWARE partition not mounted — insert a freshly-flashed nixpi card." >&2
        return 1
      fi
      printf '%s\n' "$mp"
    }
  '';

  # Shared: require CWD to be the repo root (the vault must be reachable).
  requireRepoRootFn = ''
    require_repo_root() {
      if [ ! -f "${vault}" ]; then
        echo "nixpi: run this from the nix-config repo root (${vault} not found here)." >&2
        return 1
      fi
    }
  '';

  wifi-creds = writeShellApplication {
    name = "nixpi-wifi-creds";
    runtimeInputs = [
      coreutils
      gnused
      gawk
    ];
    text = ''
      # Emit a wpa_supplicant.conf for nixpi from the Mac's current Wi-Fi network.
      # Reads the SSID + keychain PSK of the network this Mac is on; --ssid/--country
      # override. Prints to stdout (pipe into nixpi-provision --wifi-conf, or a file).
      ssid=""
      psk=""
      country=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --ssid) ssid="''${2:?}"; shift 2 ;;
          --psk) psk="''${2:?}"; shift 2 ;;
          --country) country="''${2:?}"; shift 2 ;;
          -h | --help) echo "usage: nixpi-wifi-creds [--ssid SSID] [--psk PSK] [--country CC]"; exit 0 ;;
          *) echo "nixpi-wifi-creds: unknown argument: $1" >&2; exit 1 ;;
        esac
      done

      if [ -z "$ssid" ]; then
        wifi_dev=$(/usr/sbin/networksetup -listallhardwareports \
          | awk '/Wi-Fi/{getline; print $2; exit}')
        wifi_dev="''${wifi_dev:-en0}"
        # Modern macOS gates `networksetup -getairportnetwork` behind Location
        # privacy (it lies "not associated"); `ipconfig getsummary` reports the SSID
        # without that. Fall back to networksetup if ipconfig ever comes up empty.
        ssid=$(/usr/sbin/ipconfig getsummary "$wifi_dev" 2>/dev/null \
          | sed -n 's/^[[:space:]]*SSID : //p' | head -1)
        if [ -z "$ssid" ]; then
          ssid=$(/usr/sbin/networksetup -getairportnetwork "$wifi_dev" \
            | sed 's/^Current Wi-Fi Network: //')
        fi
      fi
      case "$ssid" in
        "" | *"not associated"* | *"not currently"*)
          echo "nixpi-wifi-creds: could not determine the current Wi-Fi SSID; pass --ssid (and --psk)." >&2
          exit 1 ;;
      esac

      # PSK: --psk wins; else read it from the keychain for this SSID (may prompt for
      # keychain auth). Band-split networks (e.g. a separate '<name>-5G') can be saved
      # under a different name than the one you flash — pass --ssid/--psk then.
      if [ -z "$psk" ]; then
        if ! psk=$(/usr/bin/security find-generic-password -wa "$ssid" 2>/dev/null) || [ -z "$psk" ]; then
          echo "nixpi-wifi-creds: no saved password for '$ssid' in the keychain; pass --psk." >&2
          exit 1
        fi
      fi

      if [ -z "$country" ]; then
        country=$(/usr/bin/defaults read -g AppleLocale 2>/dev/null | sed 's/.*_//' | cut -c1-2)
        [ -n "$country" ] || country="US"
      fi

      cat <<EOF
      country=$country
      ctrl_interface=/run/wpa_supplicant
      update_config=1
      network={
          ssid="$ssid"
          psk="$psk"
      }
      EOF
    '';
  };

  provision = writeShellApplication {
    name = "nixpi-provision";
    runtimeInputs = [
      age
      coreutils
      gnugrep
    ];
    text = ''
      # Plant the connector token and/or Wi-Fi config onto the mounted FIRMWARE
      # partition of a nixpi SD card. Default --all; --token / --wifi for updates.
      ${firmwareMountFn}
      ${requireRepoRootFn}

      what="all"
      wifi_conf=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --token) what="token"; shift ;;
          --wifi) what="wifi"; shift ;;
          --all) what="all"; shift ;;
          --wifi-conf) wifi_conf="''${2:?}"; shift 2 ;;
          -h | --help) echo "usage: nixpi-provision [--all|--token|--wifi] [--wifi-conf FILE]"; exit 0 ;;
          *) echo "nixpi-provision: unknown argument: $1" >&2; exit 1 ;;
        esac
      done

      mnt=$(firmware_mount)

      if [ "$what" = "token" ] || [ "$what" = "all" ]; then
        require_repo_root
        age -d -i "${operatorKey}" ${vault} > "$mnt/cloudflared-token"
        if ! grep -q '^TUNNEL_TOKEN=' "$mnt/cloudflared-token"; then
          echo "nixpi-provision: decrypted token is malformed (no TUNNEL_TOKEN= line)." >&2
          exit 1
        fi
        echo "nixpi-provision: planted cloudflared-token."
      fi

      if [ "$what" = "wifi" ] || [ "$what" = "all" ]; then
        if [ -n "$wifi_conf" ]; then
          cp "$wifi_conf" "$mnt/wpa_supplicant.conf"
        else
          ${wifi-creds}/bin/nixpi-wifi-creds > "$mnt/wpa_supplicant.conf"
        fi
        if ! grep -q '^country=' "$mnt/wpa_supplicant.conf"; then
          echo "nixpi-provision: wpa_supplicant.conf missing a country= line (radio stays blocked)." >&2
          exit 1
        fi
        echo "nixpi-provision: planted wpa_supplicant.conf."
      fi

      sync
      /usr/bin/osascript -e 'display notification "FIRMWARE partition provisioned" with title "nixpi"' >/dev/null 2>&1 || true
      echo "nixpi-provision: done ($mnt). Eject and boot the Pi."
    '';
  };

  flash = writeShellApplication {
    name = "nixpi-flash";
    runtimeInputs = [
      zstd
      coreutils
      gnused
    ];
    text = ''
      # Fresh reflash: build (or --image) → decompress → verified dd → auto-plant.
      # Requires an aarch64-linux builder for the build step (see the runbook); pass
      # --image PATH to a prebuilt *.img.zst to skip building.
      ${firmwareMountFn}

      disk=""
      image=""
      wifi_conf=""
      ssid=""
      psk=""
      country=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --disk) disk="''${2:?}"; shift 2 ;;
          --image) image="''${2:?}"; shift 2 ;;
          --wifi-conf) wifi_conf="''${2:?}"; shift 2 ;;
          --ssid) ssid="''${2:?}"; shift 2 ;;
          --psk) psk="''${2:?}"; shift 2 ;;
          --country) country="''${2:?}"; shift 2 ;;
          -h | --help) echo "usage: nixpi-flash --disk /dev/diskN [--image FILE.img.zst] [--wifi-conf FILE | --ssid SSID [--psk PSK] [--country CC]]"; exit 0 ;;
          *) echo "nixpi-flash: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      case "$disk" in
        "") echo "nixpi-flash: --disk /dev/diskN is required." >&2; exit 1 ;;
        /dev/disk0 | disk0) echo "nixpi-flash: refusing to write the internal disk0." >&2; exit 1 ;;
        /dev/disk*) : ;;
        *) echo "nixpi-flash: --disk must be /dev/diskN." >&2; exit 1 ;;
      esac

      if [ -z "$image" ]; then
        echo "nixpi-flash: building the sdImage (needs an aarch64-linux builder)…"
        out=$(nix build --no-link --print-out-paths \
          ".#nixosConfigurations.nixpi.config.system.build.sdImage")
        set -- "$out"/sd-image/*.img.zst
        image="$1"
      fi
      [ -f "$image" ] || { echo "nixpi-flash: image not found: $image" >&2; exit 1; }

      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      echo "nixpi-flash: decompressing $image …"
      zstd -d -q -f "$image" -o "$tmp/nixpi.img"
      size=$(stat -f%z "$tmp/nixpi.img")

      model=$(/usr/sbin/diskutil info "$disk" | sed -n 's/.*Device \/ Media Name: *//p')
      human=$(/usr/sbin/diskutil info "$disk" | sed -n 's/.*Disk Size: *\([^(]*\).*/\1/p')
      if ! /usr/bin/osascript -e \
        "display dialog \"Flash to $disk ($model,$human)?\nThis ERASES the card.\" buttons {\"Cancel\",\"Flash\"} default button \"Cancel\" with icon caution" \
        >/dev/null 2>&1; then
        echo "nixpi-flash: cancelled."; exit 1
      fi

      /usr/sbin/diskutil unmountDisk "$disk"
      rdisk=$(printf '%s' "$disk" | sed 's|/dev/disk|/dev/rdisk|')
      echo "nixpi-flash: writing $size bytes to $rdisk (several minutes)…"
      sudo -v
      ddlog=$(sudo /bin/dd "if=$tmp/nixpi.img" "of=$rdisk" bs=4m 2>&1)
      echo "$ddlog"
      copied=$(printf '%s\n' "$ddlog" | sed -n 's/^\([0-9]*\) bytes transferred.*/\1/p')
      if [ "$copied" != "$size" ]; then
        echo "nixpi-flash: WRITE INCOMPLETE ($copied != $size bytes) — do NOT boot; re-run." >&2
        exit 1
      fi
      sync
      echo "nixpi-flash: verified full write ($copied bytes)."

      /usr/sbin/diskutil mount "''${disk}s1" >/dev/null 2>&1 || true
      # On a BAND-SPLIT network (e.g. joined to `FOO-5G` but the keychain stores the
      # base `FOO` PSK) nixpi-provision's auto Wi-Fi detect fails — pin it with --ssid
      # or a prebuilt --wifi-conf. Build the conf here when --ssid is given.
      if [ -z "$wifi_conf" ] && [ -n "$ssid" ]; then
        wifi_conf="$tmp/wpa.conf"
        wc_args=(--ssid "$ssid")
        [ -n "$psk" ] && wc_args+=(--psk "$psk")
        [ -n "$country" ] && wc_args+=(--country "$country")
        ${wifi-creds}/bin/nixpi-wifi-creds "''${wc_args[@]}" > "$wifi_conf"
      fi
      prov_args=(--all)
      [ -n "$wifi_conf" ] && prov_args+=(--wifi-conf "$wifi_conf")
      ${provision}/bin/nixpi-provision "''${prov_args[@]}"
      /usr/sbin/diskutil eject "$disk"
      echo "nixpi-flash: done. Insert the card and boot the Pi."
    '';
  };

  vault-token = writeShellApplication {
    name = "nixpi-vault-token";
    runtimeInputs = [
      age
      coreutils
    ];
    text = ''
      # Re-encrypt a NEW connector token into the vault (secrets/cloudflared-token.age),
      # to the operator's own SSH key. Feed the token on stdin or via $TUNNEL_TOKEN —
      # e.g. from `cf-tunnel-apply`. Run from the repo root; commit the result.
      ${requireRepoRootFn}
      require_repo_root

      if [ -n "''${TUNNEL_TOKEN:-}" ]; then
        line="TUNNEL_TOKEN=$TUNNEL_TOKEN"
      elif [ ! -t 0 ]; then
        line=$(cat)
      else
        echo "nixpi-vault-token: provide the token on stdin or via \$TUNNEL_TOKEN." >&2
        exit 1
      fi
      case "$line" in
        TUNNEL_TOKEN=*) : ;;
        *) line="TUNNEL_TOKEN=$line" ;;
      esac

      printf '%s\n' "$line" | age -e -R "$HOME/.ssh/id_ed25519.pub" -o ${vault}
      echo "nixpi-vault-token: re-encrypted ${vault} — commit it, then re-plant/rebuild."
    '';
  };
in
{
  inherit
    wifi-creds
    provision
    flash
    vault-token
    ;
}
