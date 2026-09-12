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
  ...
}:
let
  cfg = config.services.firmwareProvisioning;
  # PRIOR ART: systemd's own LoadCredential=, which nixpkgs already uses for exactly
  # this shape -- nixos/modules/services/networking/cloudflared.nix:406 loads the
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
  # NOT a reason: LoadCredential= is settable on any upstream unit, and so is the
  # RequiresMountsFor= below -- neither of those on its own would justify a module.
  mkService =
    name: f:
    lib.nameValuePair "firmware-file-${name}" {
      description = "Install ${f.source} from the firmware partition";
      inherit (f) before requiredBy wantedBy;
      # Gate on the FAT partition actually being mounted (a stage-2 systemd mount),
      # so this runs well after firmwareDir is available.
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
          echo "firmware-file-${name}: $src not found${lib.optionalString f.required " (required)"}.${
            lib.optionalString (cfg.docsHint != "") " ${cfg.docsHint}"
          }" >&2
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
      example = "/boot";
      description = "Mount point of the FAT partition the planted files are read from.";
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
  };
}
