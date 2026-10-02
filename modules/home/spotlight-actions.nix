# The .app bundles this fleet plants in ~/Applications so Spotlight's
# Applications lane indexes them. Two kinds, both from
# packages/spotlight-launchers.nix:
#
#   commandApps — `Nix Activate`, `Nix Flake Check`, `Nix Open Repo`. Type "nix"
#                 in Spotlight and the three list together.
#   aliasApps   — `Terminal`, which opens Ghostty. It exists only so Ghostty
#                 answers to a name it does not carry; the key that does the
#                 work (CFBundleAlternateNames) belongs in Ghostty's own
#                 Info.plist, but that is a Homebrew cask and editing it would
#                 be clobbered by the next upgrade AND break its code signature.
#
# The two merge into one `home.file` map below — same placement rules, same gate.
#
# WHY NOT SPOTLIGHT'S "ACTIONS" LANE (the one macOS 26 added, and the one people
# reach for first): it is fed only by App Intents — a Swift-only framework
# needing an Xcode app target and a signing identity — or by Shortcuts.app,
# whose shortcuts live in an iCloud-synced sqlite store that the `shortcuts` CLI
# can run/list/view/sign but NOT import. Creating one is therefore a GUI act,
# repeated by hand on every Mac, which is the opposite of what this repo is for.
# A Shortcuts "Run Shell Script" launched FROM Spotlight also fails "Operation
# not permitted" until Spotlight.app itself is hand-granted Full Disk Access
# (the shortcut inherits the CALLING app's sandbox, not Shortcuts'). The bundle
# geometry, the Ghostty invocation and the argv-not-environment rule all live in
# packages/spotlight-launchers.nix; this module only decides WHERE they land.
#
# UPSTREAM-FIRST (.claude/rules/upstream-first.md). home-manager DOES own app
# placement, and the option even says so:
# `targets.darwin.copyApps.enable` — "copying macOS applications to the user
# environment (works with Spotlight)" (pinned
# modules/targets/darwin/copyapps.nix:14). NOT used, for two measured reasons:
#   · it is OFF here. Its default is `isDarwin && stateVersion >= 25.11`, and
#     this profile is on 24.05, so what is actually live is the older
#     `linkApps` — ~/Applications/Home Manager Apps is a SYMLINK into
#     /nix/store (verified 2026-09-23). Spotlight does not index app bundles
#     behind that symlink, which is the whole reason upstream added copyApps.
#   · both place bundles inside a SUBFOLDER and drive it from `home.packages`,
#     and copyApps additionally needs the App Management TCC grant (its own
#     `checkAppManagementPermission` activation step) — a click, per Mac, which
#     is the thing this route exists to avoid.
# `home.file` with `recursive = true` lands a real directory at the top of
# ~/Applications, needs no grant, and is what the in-tree Android Emulator
# bundle already does.
#
# TOOL AXIS: Platypus is the community tool that wraps a shell script into a
# .app — `nix search nixpkgs platypus` returns only perlPackages.FFI::Platypus,
# and `appify` returns nothing, so nixpkgs packages neither. It is also a GUI
# that emits a bundle imperatively, which a flake cannot consume.
#
# macos only — Spotlight is macOS's, and the operations name darwin tooling.
{
  pkgs,
  lib,
  osConfig,
  ...
}:
let
  isMacosHost = (osConfig.networking.hostName or "") == "macos";

  # Its own callPackage rather than a value threaded from home.nix: the two
  # calls are identical, so Nix realises ONE derivation, and this module stays
  # independently importable instead of depending on a binding next door.
  inherit (pkgs.callPackage ../../packages/spotlight-launchers.nix { })
    commandApps
    aliasApps
    ;
in
{
  # `recursive = true` for the same reason the Android Emulator bundle uses it
  # (modules/shared/home.nix): a symlinked .app DIRECTORY confuses
  # LaunchServices, so link the contents and leave a real directory behind.
  home.file = lib.mkIf isMacosHost (
    lib.mapAttrs' (
      name: app:
      lib.nameValuePair "Applications/${name}.app" {
        source = app;
        recursive = true;
      }
    ) (commandApps // aliasApps)
  );
}
