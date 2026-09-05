# The macOS user-folder seam — mkOption'd so a host (or the private layer)
# can relocate an inbox, while an UNSET option is exactly the macOS system
# default. Only folders with a real consumer are declared (LEAN): desktop and
# downloads feed the file-rotation sweeps (core.nix).
# Add pictures/documents/movies/music only when
# something actually consumes them.
#
# An INVALID value fails LOUDLY at eval — types.path rejects a non-absolute
# string — instead of silently falling back to the default: a declarative
# option that ignores what was written is worse than one that refuses it.
# Forgiving "warn and fall back" semantics belong at runtime, in CLIs
# (cf. social-kit's --out in nix-personal). Whether the directory exists is a
# runtime fact no eval can check; consumers mkdir -p where it matters.
#
# upstream-first: grepped home-manager's modules/misc/xdg/user-dirs.nix —
# xdg.userDirs models the freedesktop user-dirs.dirs file, which nothing on
# macOS reads (and these consumers are nix-darwin SYSTEM modules, not HM);
# grepped nix-darwin's modules/system/defaults for a folder-location surface —
# none (dock.nix merely uses ~/Downloads in examples). No upstream option
# exists → custom, because the seam must live where the sweeps consume it.
{
  config,
  lib,
  loginName,
  ...
}:
let
  home = config.users.users.${loginName}.home;
in
{
  options.local.folders = {
    desktop = lib.mkOption {
      type = lib.types.path;
      default = "${home}/Desktop";
      defaultText = lib.literalExpression ''"''${home}/Desktop"'';
      description = ''
        The screen-capture inbox. macOS's own capture target while
        system.defaults.screencapture.location stays unset (nix-darwin#1240
        documents the fallback); swept daily by file-rotation-desktop.
      '';
    };
    downloads = lib.mkOption {
      type = lib.types.path;
      default = "${home}/Downloads";
      defaultText = lib.literalExpression ''"''${home}/Downloads"'';
      description = ''
        The browser/AirDrop inbox — every app's default download target;
        nothing in this repo overrides it. Swept weekly (disposable types
        only) by file-rotation-downloads.
      '';
    };
  };
}
