# nixpi provisioning toolkit — the macOS-side, all-Nix companion to
# the firmware-secrets flake. Returns four `writeShellApplication`s
# (shellcheck'd at `nix flake check`), wired as flake apps in flake.nix:
#
#   nix run .#nixpi-flash       — acquire image (--release download / --image / build)
#                                 + verified dd + auto-plant (fresh reflash)
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
  gh,
  orgName,
  repoName,
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

  # Shared: decrypt secrets/cloudflared-token.age with the operator SSH key.
  # age prompts on /dev/tty for an encrypted key — that fails in agent/non-TTY
  # shells ("/dev/tty: device not configured"), which is exactly how a reflash
  # often runs. Order:
  #   1) unencrypted key → age -d directly
  #   2) TTY available → age prompts natively on /dev/tty
  #   3) no TTY (macOS) → osascript hidden dialog, temp-unlock a key copy via
  #      ssh-keygen -p, age -d, then wipe the copy (never log the passphrase)
  decryptVaultFn = ''
        decrypt_operator_vault() {
          # $1 = destination path for plaintext (TUNNEL_TOKEN=…)
          local dest="''${1:?}"
          local key="${operatorKey}"
          local vault_path="${vault}"
          local tmpkey="" pass=""

          if [ ! -f "$key" ]; then
            echo "nixpi: operator key not found: $key" >&2
            return 1
          fi
          if [ ! -f "$vault_path" ]; then
            echo "nixpi: vault not found: $vault_path (run from repo root)." >&2
            return 1
          fi

          _nixpi_vault_cleanup() {
            if [ -n "''${tmpkey:-}" ] && [ -f "$tmpkey" ]; then
              # Best-effort overwrite then unlink (macOS has no shred by default).
              /bin/dd if=/dev/urandom of="$tmpkey" bs=1024 count=4 conv=notrunc >/dev/null 2>&1 || true
              rm -f "$tmpkey"
            fi
            unset pass tmpkey 2>/dev/null || true
          }

          # Unencrypted private key: no passphrase needed.
          if SSH_ASKPASS_REQUIRE=force SSH_ASKPASS=/usr/bin/false DISPLAY=dummy \
            /usr/bin/ssh-keygen -y -f "$key" </dev/null >/dev/null 2>&1; then
            age -d -i "$key" "$vault_path" >"$dest"
            return 0
          fi

          # Encrypted key + real TTY: let age prompt (never capture the passphrase).
          if [ -r /dev/tty ] && [ -w /dev/tty ]; then
            # age reads the passphrase from the controlling terminal.
            if age -d -i "$key" "$vault_path" >"$dest" </dev/tty 2>/dev/tty; then
              return 0
            fi
            echo "nixpi: vault decrypt failed (wrong passphrase or corrupt vault?)." >&2
            return 1
          fi

          # No TTY (Claude Code Bash, launchd, piped CI, …): macOS GUI prompt.
          if [ ! -x /usr/bin/osascript ]; then
            echo "nixpi: operator key is passphrase-protected and no TTY is available." >&2
            echo "nixpi: re-run in Terminal.app, or unlock is not possible headless here." >&2
            return 1
          fi

          # EXACTLY ONE `on error` handler: a second one (e.g. a dedicated
          # `on error number -128` for Cancel) is a hard AppleScript syntax
          # error — osascript rejects the whole script with "Expected end but
          # found on", so `pass` comes back empty and every GUI unlock reports a
          # bogus "cancelled". Cancel already surfaces as an empty result here.
          pass=$(/usr/bin/osascript <<'APPLESCRIPT'
    try
      text returned of (display dialog "Passphrase for ~/.ssh/id_ed25519" & return & "(decrypts the nixpi Cloudflare tunnel token vault)" with title "nixpi-provision" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
    on error
      return ""
    end try
    APPLESCRIPT
    ) || true

          if [ -z "''${pass:-}" ]; then
            echo "nixpi: vault decrypt cancelled (no passphrase)." >&2
            return 1
          fi

          # Explicit cleanup only — do NOT install EXIT/RETURN traps here: nixpi-flash
          # already owns EXIT for its image tmpdir, and a nested trap would clobber it.
          tmpkey=$(mktemp "''${TMPDIR:-/tmp}/nixpi-opkey.XXXXXX")
          /bin/cp "$key" "$tmpkey"
          /bin/chmod 600 "$tmpkey"
          # Unlock a throwaway copy (empty passphrase) so age needs no TTY.
          # -P is briefly visible in ps(1); accepted for this short-lived GUI path.
          if ! /usr/bin/ssh-keygen -p -f "$tmpkey" -P "$pass" -N "" -q; then
            echo "nixpi: wrong passphrase (or ssh-keygen could not unlock the key)." >&2
            _nixpi_vault_cleanup
            return 1
          fi
          unset pass

          if ! age -d -i "$tmpkey" "$vault_path" >"$dest"; then
            echo "nixpi: vault decrypt failed after unlock." >&2
            _nixpi_vault_cleanup
            return 1
          fi
          _nixpi_vault_cleanup
          return 0
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
        ${decryptVaultFn}
        decrypt_operator_vault "$mnt/cloudflared-token"
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
      gh
    ];
    text = ''
            # Fresh reflash: acquire the image → decompress → verified dd → auto-plant.
            # Three ways to acquire it, in precedence order:
            #   --image FILE.img.zst  a prebuilt image on disk (skips build/download)
            #   --release             download the latest CI-built image from the
            #                         installer-latest GitHub release (needs `gh` auth; NO
            #                         Nix, NO aarch64-linux builder — the Mac path)
            #   (default)             `nix build` the sdImage. With the kattakath Cachix
            #                         warm this substitutes the kernel/intermediates, but
            #                         the final image assembly still needs an aarch64-linux
            #                         builder — so on the builder-less Mac, prefer --release.
            ${firmwareMountFn}

            disk=""
            image=""
            use_release=""
            wifi_conf=""
            ssid=""
            psk=""
            country=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --disk) disk="''${2:?}"; shift 2 ;;
                --image) image="''${2:?}"; shift 2 ;;
                --release) use_release=1; shift ;;
                --wifi-conf) wifi_conf="''${2:?}"; shift 2 ;;
                --ssid) ssid="''${2:?}"; shift 2 ;;
                --psk) psk="''${2:?}"; shift 2 ;;
                --country) country="''${2:?}"; shift 2 ;;
                -h | --help) echo "usage: nixpi-flash --disk /dev/diskN [--image FILE.img.zst | --release] [--wifi-conf FILE | --ssid SSID [--psk PSK] [--country CC]]"; exit 0 ;;
                *) echo "nixpi-flash: unknown argument: $1" >&2; exit 1 ;;
              esac
            done
            case "$disk" in
              "") echo "nixpi-flash: --disk /dev/diskN is required." >&2; exit 1 ;;
              /dev/disk0 | disk0) echo "nixpi-flash: refusing to write the internal disk0." >&2; exit 1 ;;
              /dev/disk*) : ;;
              *) echo "nixpi-flash: --disk must be /dev/diskN." >&2; exit 1 ;;
            esac

            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT

            if [ -n "$image" ] && [ -n "$use_release" ]; then
              echo "nixpi-flash: --image and --release are mutually exclusive." >&2; exit 1
            fi
            if [ -z "$image" ] && [ -n "$use_release" ]; then
              echo "nixpi-flash: downloading the latest prebuilt nixpi image (installer-latest release)…"
              # Pick by updatedAt (newest wins), not shell glob order. installer-latest is
              # a rolling slot that can briefly hold multiple nixos-sd-image-*.img.zst
              # names (nixpkgs rev in the basename); alphabetical $1 would flash the
              # OLDEST — e.g. a pre-key-rotate image — and lock the operator out.
              # Download only that one asset (multi-GB). The publish path also retires
              # stale assets; this is defense in depth for residual multi-asset slots.
              asset=$(gh release view installer-latest -R ${orgName}/${repoName} --json assets \
                --jq '[.assets[] | select(.name | test("^nixos-sd-image-.*\\.img\\.zst$"))]
                      | if length == 0 then empty else sort_by(.updatedAt) | last | .name end')
              if [ -z "''${asset:-}" ]; then
                echo "nixpi-flash: no nixpi image asset found on installer-latest." >&2
                exit 1
              fi
              echo "nixpi-flash: selected asset: $asset"
              gh release download installer-latest -R ${orgName}/${repoName} \
                -p "$asset" -D "$tmp" --clobber
              image="$tmp/$asset"
              [ -f "$image" ] || { echo "nixpi-flash: download failed: $image" >&2; exit 1; }
            fi
            if [ -z "$image" ]; then
              echo "nixpi-flash: building the sdImage (needs an aarch64-linux builder — see --release)…"
              out=$(nix build --no-link --print-out-paths \
                ".#nixosConfigurations.nixpi.config.system.build.sdImage")
              set -- "$out"/sd-image/*.img.zst
              image="$1"
            fi
            [ -f "$image" ] || { echo "nixpi-flash: image not found: $image" >&2; exit 1; }

            echo "nixpi-flash: decompressing $image …"
            zstd -d -q -f "$image" -o "$tmp/nixpi.img"
            size=$(/usr/bin/stat -f%z "$tmp/nixpi.img")

            model=$(/usr/sbin/diskutil info "$disk" | sed -n 's/.*Device \/ Media Name: *//p')
            human=$(/usr/sbin/diskutil info "$disk" | sed -n 's/.*Disk Size: *\([^(]*\).*/\1/p')
            # $model/$human are hardware-reported diskutil metadata, not fixed
            # strings — passed via env + AppleScript's `system attribute`, never
            # interpolated into the AppleScript source, so a crafted media-name
            # (e.g. embedding a `"`) can't break out of the string literal.
            if ! DISK_CONFIRM_DEVICE="$disk" DISK_CONFIRM_MODEL="$model" DISK_CONFIRM_SIZE="$human" \
              /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
      set diskName to system attribute "DISK_CONFIRM_DEVICE"
      set modelName to system attribute "DISK_CONFIRM_MODEL"
      set humanSize to system attribute "DISK_CONFIRM_SIZE"
      display dialog "Flash to " & diskName & " (" & modelName & ", " & humanSize & ")?" & return & "This ERASES the card." buttons {"Cancel", "Flash"} default button "Cancel" with icon caution
      APPLESCRIPT
            then
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
