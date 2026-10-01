# Generic "operator-planted file on a device's FAT firmware partition -> root-only
# /run file at boot" mechanism.
#
# WHY THIS EXISTS: a headless device (Raspberry Pi, NUC, kiosk) often needs a
# secret BEFORE the network/SSH is usable, and WITHOUT binding that secret to the
# SSH host key. agenix/sops decrypt at activation with the host key -- but a fresh
# SD/USB flash MINTS A NEW HOST KEY, so those secrets can no longer be decrypted,
# and there is no console to recover over. The FAT firmware partition is the one
# thing you can write from another machine after flashing, so the operator plants
# files there and this module copies each into a root-only /run path at boot,
# before the consuming service starts. The FAT partition is world-readable, so the
# /run copy (0600 by default) is where the secret actually rests at runtime.
#
# Declaring a firmware-planted secret is one attribute set. The CONSUMER
# (cloudflared, wpa_supplicant, a licence daemon, ...) keeps its own unit; this
# module only owns the plant -> /run copy + ordering.
{
  config,
  lib,
  # `escapeSystemdPath` lives in NixOS's own utils (nixos/lib/utils.nix), NOT in
  # nixpkgs `lib` -- it is passed to every NixOS module as this argument.
  utils,
  ...
}:
let
  cfg = config.local.firmwareProvisioning;
  # PRIOR ART: systemd's own LoadCredential=, which nixpkgs already uses for exactly
  # this shape -- nixos/modules/services/networking/cloudflared.nix:387-390 loads the
  # tunnel credentials + cert straight off an operator-supplied path. Grepped the
  # pinned nixpkgs for it; the option exists and fits the general idea, so a copy
  # unit is still custom ON PURPOSE, for three things credentials cannot do:
  #   * OPTIONAL sources. `LoadCredential=ID:/abs/path` is FATAL when the file is
  #     absent; systemd.exec(5) grants the non-fatal case only to an omitted path or
  #     a bare credential identifier resolved from the credstore, and the
  #     `SetCredential=` fallback that softens it takes a LITERAL value the same page
  #     forbids for secret data. `required = false` + `docsHint` is that missing mode.
  #   * SHARING one planted file. $CREDENTIALS_DIRECTORY is per-unit and scoped to the
  #     unit's UID, so N consumers means N declarations and N private copies; one /run
  #     target plus list-valued `before`/`requiredBy` feeds them all from one unit.
  #   * `postInstall`. A credential has no post-load hook, and some planted files only
  #     take effect via a side effect (`rfkill unblock wifi`).
  #   * A PERSISTENT CACHE of the last good plant, so an unreadable firmware partition
  #     degrades instead of taking the consumer down with it. A credential read is a
  #     single path with no fallback; there is no "or the last one that worked".
  # NOT a reason: LoadCredential= is settable on any upstream unit, and so is the mount
  # ordering below -- neither of those on its own would justify a module.
  # The mount unit behind firmwareDir ("/boot/firmware" -> boot-firmware.mount).
  firmwareMountUnit = "${utils.escapeSystemdPath cfg.firmwareDir}.mount";

  mkService =
    name: f:
    let
      cachePath = "${cfg.cacheDir}/${name}";
    in
    lib.nameValuePair "firmware-file-${name}" {
      description = "Install ${f.source} from the firmware partition";
      inherit (f) before requiredBy wantedBy;
      # WANTS, NOT REQUIRES, AND THAT ASYMMETRY IS THE WHOLE POINT.
      #
      # This was `unitConfig.RequiresMountsFor = firmwareDir`, which systemd expands to
      # Requires= + After= on the mount. A FAT partition that fails to mount therefore
      # DEPENDENCY-FAILED this unit -- and a dependency failure is not a start attempt,
      # so `Restart=` cannot retry it and `Type=oneshot` never ran again. Combined with
      # a consumer's `requiredBy`, one failed mount was a PERMANENT loss of that
      # consumer. For nixpi that consumer is the Cloudflare connector, i.e. the only
      # route in, and the recovery is a physical reflash.
      #
      # Wants= keeps the ordering and drops the veto: the mount is still pulled in and
      # still waited for, but if it fails the script RUNS and decides for itself --
      # which is what lets the cache below work and what lets `required` still fail
      # loudly when there is genuinely nothing to install.
      #
      # Same shape as the USB storage volume's `nofail` in hosts/nixpi.nix, and for the
      # same stated reason: on a remote-only host a failed mount must never be able to
      # block the way back in. That pattern was written down there and never applied to
      # the partition that gates the tunnel.
      after = [ firmwareMountUnit ];
      wants = [ firmwareMountUnit ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        src=${cfg.firmwareDir}/${f.source}
        dst=${f.target}
        ${lib.optionalString f.cache "cache=${cachePath}"}

        # Prefer the freshly planted file; fall back to the cached copy of the last
        # one that installed cleanly. `target` normally lives on tmpfs (/run), so it
        # is gone every boot and this runs on every boot -- which is exactly why an
        # unreadable firmware partition was fatal and why a persistent cache fixes it.
        from=""
        if [ -f "$src" ]; then
          from="$src"
        ${lib.optionalString f.cache ''
          elif [ -f "$cache" ]; then
            from="$cache"
            echo "firmware-file-${name}: $src unreadable or absent; using the cached copy at $cache." >&2
        ''}
        fi

        if [ -n "$from" ]; then
          install -D -m${f.mode} "$from" "$dst"
        ${lib.optionalString f.cache ''
          if [ "$from" = "$src" ]; then
            # Refresh the cache so a ROTATED plant propagates rather than being
            # shadowed forever by a stale copy. 0400 root: the FAT source is
            # world-readable with no permissions at all, so this copy is strictly
            # tighter at rest than the one the operator plants.
            install -D -m0400 "$src" "$cache" \
              || echo "firmware-file-${name}: could not refresh $cache (read-only root?)" >&2
          fi
        ''}
          ${f.postInstall}
        else
          echo "firmware-file-${name}: $src not found${lib.optionalString f.cache " and no cached copy"}${lib.optionalString f.required " (required)"}.${
            lib.optionalString (cfg.docsHint != "") " ${cfg.docsHint}"
          }" >&2
          ${lib.optionalString f.required "exit 1"}
        fi
      '';
    };
in
{
  options.local.firmwareProvisioning = {
    firmwareDir = lib.mkOption {
      type = lib.types.str;
      default = "/boot/firmware";
      example = "/boot";
      description = "Mount point of the FAT partition the planted files are read from.";
    };
    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/firmware-secrets";
      description = ''
        Directory holding the persistent cache for files with `cache = true`. Must be on
        storage that survives a reboot -- the point is to outlive a firmware partition
        that stops mounting.
      '';
    };
    docsHint = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "See https://example.com/flashing-runbook for how to plant files.";
      description = "Optional hint appended to the 'source not found' message (e.g. a link to your flashing runbook).";
    };
    files = lib.mkOption {
      default = { };
      description = "Files copied from the firmware partition into /run at boot.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Basename of the planted file under `firmwareDir`.";
            };
            target = lib.mkOption {
              type = lib.types.str;
              example = "/run/my-token";
              description = "Destination path (a root-only /run file the consumer reads).";
            };
            mode = lib.mkOption {
              type = lib.types.str;
              default = "0600";
              description = "Mode of the installed destination file.";
            };
            required = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If true the unit fails when the source is absent; if false it skips cleanly (the secret is optional).";
            };
            cache = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Keep a persistent copy under `cacheDir` and install from it when the
                firmware source is unreadable or absent.

                OPT-IN, and deliberately so: it writes a second copy of the secret to
                disk, which is only worth it when losing the file costs more than the
                extra copy. Turn it on for a file whose absence makes the host
                UNREACHABLE (a tunnel/connector token); leave it off for one that
                merely degrades a feature, where the extra copy buys little.
              '';
            };
            postInstall = lib.mkOption {
              type = lib.types.lines;
              default = "";
              example = "rfkill unblock wifi";
              description = "Shell run after a successful install.";
            };
            before = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "systemd `Before=` -- order ahead of the consuming unit.";
            };
            requiredBy = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "systemd `RequiredBy=` -- pull this in with the consumer and fail it if the (required) secret is missing.";
            };
            wantedBy = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "multi-user.target" ];
              description = "systemd `WantedBy=`.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.files != { }) {
    systemd.services = lib.mapAttrs' mkService cfg.files;

    # Only when something actually caches. 0700 root: the cached copies are 0400, but
    # the directory mode is what stops anything else enumerating what is cached.
    systemd.tmpfiles.rules = lib.mkIf (lib.any (f: f.cache) (lib.attrValues cfg.files)) [
      "d ${cfg.cacheDir} 0700 root root -"
    ];
  };
}
