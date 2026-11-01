# KDE Connect's Mac-side settings, MERGED into the app's own INI files.
#
# The app itself is the `kde-connect` cask (hosts/macos.nix says why it is not
# nixpkgs). This module owns only the settings keys you declare. Everything else in
# ~/Library/Preferences/kdeconnect stays the app's: pairing (`trusted_devices`,
# `certificate.pem`, `privateKey.pem`), the device name, and every key not listed here.
#
# upstream-first: grepped home-manager/modules and nix-darwin/modules for kdeconnect.
# home-manager's `services.kdeconnect` asserts `platforms.linux`
# (modules/services/kdeconnect.nix), and nix-darwin has nothing, so this is custom.
# The merge is done by `crudini` (nixpkgs), which sets one key and leaves the rest of
# the file alone. That makes it idempotent: a second run is byte-identical (measured,
# same md5), and the file mode is preserved. Rejected: `home.file` /
# `lib.generators.toINI`. Both own the WHOLE file, and the app rewrites these files
# itself (`trusted_devices` on pairing, `config` on a rename), so a store symlink
# would break it.
#
# THE FILE LAYOUT, read from upstream source at v26.08.1 (the installed cask; identical
# at v26.08.2):
#   config                              QSettings INI, [General]  (kdeconnectconfig.cpp)
#   <device-id>/config                  KConfig, [Plugins] <plugin>Enabled  (device.cpp)
#   <device-id>/<plugin>/config         QSettings INI, [General]  (kdeconnectpluginconfig.cpp)
# Device IDs are never written here. The activation applies the per-device settings to
# every section of `trusted_devices`, so a re-pair (which gets a new ID) needs no edit.
#
# WHEN IT TAKES EFFECT: plugin settings apply live, because `getBool` and friends call
# QSettings::sync() before every read (kdeconnectpluginconfig.cpp). Top-level `config`
# keys and plugin toggles are read at startup, so those need an app relaunch.
#
# The runcommand plugin's `commands` key is left out on purpose. It is a JSON blob, and
# QSettings splits an unquoted value on commas into a list, which would corrupt it. The
# string type below refuses `,` and `"` for the same reason.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.kdeConnect;
  dir = "${config.home.homeDirectory}/Library/Preferences/kdeconnect";
  crudini = "${lib.getExe pkgs.crudini} --ini-options=nospace";

  # A QSettings list is comma-joined, so a comma inside one string would split it.
  safeStr = lib.types.strMatching ''[^,"]*'';
  value = lib.types.oneOf [
    lib.types.bool
    lib.types.int
    safeStr
    (lib.types.listOf safeStr)
  ];
  render =
    v:
    if lib.isBool v then
      lib.boolToString v
    else if lib.isList v then
      lib.concatStringsSep "," v
    else
      toString v;

  # `file` arrives already shell-quoted, so a device path can splice in "$dev".
  setKey =
    file: section: key: v:
    "run ${crudini} --set ${file} ${lib.escapeShellArg section} ${lib.escapeShellArg key} ${lib.escapeShellArg (render v)}";
  qdir = lib.escapeShellArg dir;

  globalLines = lib.concatLists (
    lib.mapAttrsToList (
      section: keys: lib.mapAttrsToList (setKey "${qdir}/config" section) keys
    ) cfg.settings
  );
  # "$dev" stays a shell variable: these lines run inside the per-device loop.
  pluginToggleLines = lib.mapAttrsToList (
    plugin: on: setKey ''${qdir}/"$dev"/config'' "Plugins" "${plugin}Enabled" on
  ) cfg.plugins;
  pluginSettingLines = lib.concatLists (
    lib.mapAttrsToList (
      plugin: keys:
      let
        pdir = ''${qdir}/"$dev"/${lib.escapeShellArg plugin}'';
      in
      [ "run mkdir -p ${pdir}" ] ++ lib.mapAttrsToList (setKey "${pdir}/config" "General") keys
    ) cfg.pluginSettings
  );
in
{
  options.local.kdeConnect = {
    enable = lib.mkEnableOption "merging declared KDE Connect settings into its macOS config files";

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf value);
      default = { };
      example = {
        General.disabled_providers_v2 = [ "loopback" ];
      };
      description = ''
        Keys for the top-level `config` file, as section → key → value. Read at app
        startup, so a change needs a KDE Connect relaunch.
      '';
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf lib.types.bool;
      default = { };
      example = {
        kdeconnect_virtualmonitor = false;
      };
      description = ''
        Plugin on/off switches, written as `[Plugins] <name>Enabled` into each paired
        device's `config`. Applied to every device in `trusted_devices`.
      '';
    };

    pluginSettings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf value);
      default = { };
      example = lib.literalExpression ''
        {
          kdeconnect_clipboard.autoShare = true;
          kdeconnect_share.incoming_path = "''${config.home.homeDirectory}/Downloads";
        }
      '';
      description = ''
        Per-plugin keys, as plugin → key → value, written to
        `<device-id>/<plugin>/config` for every paired device. They apply live. Key names
        come from the plugin's source (`config()->getBool(...)` and friends), so
        check there first: a misspelt key is silently ignored.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    # Not a launchd unit, so launchd-naming.md's arg0 rule does not apply.
    #
    # Skips quietly until the app has run once: the directory and `trusted_devices`
    # only exist after first launch and first pairing. It never fails a rebuild.
    # It writes only the named `config` files and never reads `privateKey.pem`.
    home.activation.kdeConnect = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -d ${lib.escapeShellArg dir} ]; then
        echo "kdeconnect: ${dir} not there yet (app never launched) — skipped, retried next activation"
      else
        :
        ${lib.concatStringsSep "\n  " globalLines}
        if [ -f ${lib.escapeShellArg "${dir}/trusted_devices"} ]; then
          while IFS= read -r dev; do
            # A device ID is a hex UUID. Anything else would be a path we did not expect.
            case "$dev" in "" | *[!A-Za-z0-9_]*) continue ;; esac
            ${lib.concatStringsSep "\n      " (pluginToggleLines ++ pluginSettingLines)}
          done < <(${crudini} --get ${lib.escapeShellArg "${dir}/trusted_devices"})
        fi
      fi
    '';
  };
}
