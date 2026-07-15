# Generic "operator-planted file on the FAT FIRMWARE partition → root-only /run file
# at boot" mechanism. This is the reusable core behind nixpi's Cloudflare connector
# token AND its Wi-Fi credentials: both are secrets that must reach a headless Pi
# WITHOUT agenix, because a fresh SD flash mints a new SSH host key and agenix (which
# encrypts to that key) would then fail to decrypt — killing the tunnel with no
# console to recover over (see hosts/nixpi.nix for the full rationale).
#
# The FAT partition is the only part of the card macOS can write, so the operator
# plants files there after each flash (see the nixpi-provision flake app and
# docs/nixpi-sd-flashing-runbook.md). Each `files.<name>` entry becomes a oneshot
# that, once /boot/firmware is mounted, copies the planted file into a root-only
# /run destination the consuming service reads. The FAT mount is world-readable, so
# the /run copy (0600) is where the secret actually rests on the running system.
#
# Declaring a firmware-planted secret is then one attribute set; adding a third is
# trivial. The CONSUMER (cloudflared-connector, wpa_supplicant, …) stays with its
# own service — this module only owns the plant→/run copy.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.firmwareProvisioning;
  mkService =
    name: f:
    lib.nameValuePair "firmware-file-${name}" {
      description = "Install ${f.source} from the FIRMWARE partition";
      inherit (f) before requiredBy wantedBy;
      # Gate on the FAT partition actually being mounted (a stage-2 systemd mount),
      # so this runs well after /boot/firmware is available.
      unitConfig.RequiresMountsFor = cfg.firmwareDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        src=${cfg.firmwareDir}/${f.source}
        dst=${f.target}
        if [ -f "$src" ]; then
          install -D -m${f.mode} "$src" "$dst"
          ${f.postInstall}
        else
          echo "firmware-file-${name}: $src not found${lib.optionalString f.required " (required)"} — see docs/nixpi-sd-flashing-runbook.md." >&2
          ${lib.optionalString f.required "exit 1"}
        fi
      '';
    };
in
{
  options.services.firmwareProvisioning = {
    firmwareDir = lib.mkOption {
      type = lib.types.str;
      default = "/boot/firmware";
      description = "Mount point of the FAT partition the planted files are read from.";
    };
    files = lib.mkOption {
      default = { };
      description = "Files copied from the FIRMWARE partition into /run at boot.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Basename of the planted file under `firmwareDir`.";
            };
            target = lib.mkOption {
              type = lib.types.str;
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
            postInstall = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Shell run after a successful install (e.g. `rfkill unblock wifi`).";
            };
            before = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "systemd `Before=` — order ahead of the consuming unit.";
            };
            requiredBy = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "systemd `RequiredBy=` — pull this in with the consumer and fail it if the (required) secret is missing.";
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
    systemd.services = lib.listToAttrs (lib.mapAttrsToList mkService cfg.files);
  };
}
