# Declarative Google Chrome extensions (darwin only).
#
# Chrome is the fleet's only browser; the passkey rationale is on the cask in hosts/macos.nix.
# The .app comes from the Homebrew `google-chrome` cask (hosts/macos.nix), so
# `programs.google-chrome.package = null` and Home Manager writes only the config
# files Chrome reads. Upstream precedent: home-manager `modules/programs/chromium.nix`
# — `package` is `nullOr package`, `supportsUserExtensions` is true for proprietary
# Chrome on darwin, and each extension becomes `External Extensions/<id>.json`.
#
# Unlike chromium.nix, the Web Store is live in Chrome, so a plain `{ id; }` entry
# makes Home Manager write the Web Store `external_update_url` — no pinned crx, no
# version, no hash to bump.
#
# The external-extension files live in Chrome's user-data dir, so the extensions
# install into EVERY Chrome profile, including the work profile.
#
# Two manual steps remain, neither a bug:
#   - Violentmonkey's MV3 build needs a one-time "Allow User Scripts" toggle in
#     chrome://extensions (Chrome 138+ refuses to let policy set it).
#   - Advanced Font Settings replaces the repo's old malayalam-font-setter crx: set
#     Malayalam (Mlym) to Noto Sans/Serif Malayalam once; Chrome Sync carries it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.googleChrome;
in
{
  options.local.googleChrome.enable = lib.mkEnableOption ''
    Google Chrome's declared extensions (programs.google-chrome). The browser
    itself is the `google-chrome` Homebrew cask; Home Manager adds only the
    External Extensions files
  '';

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    programs.google-chrome = {
      enable = true;
      package = null;
      extensions = [
        { id = "ddkjiahejlhfcafbddmgiahcphecmpfh"; } # uBlock Origin Lite
        { id = "caclkomlalccbpcdllchkeecicepbmbm"; } # Advanced Font Settings
        { id = "jinjaccalgkegednnccohejagnlnfdag"; } # Violentmonkey
        { id = "faeadnfmdfamenfhaipofoffijhlnkif"; } # Into The Black Hole — True Amoled Black theme
        { id = "fbmkmdnlhacefjljljlbhkodfmfkijdh"; } # MeTube Downloader
        { id = "pejdijmoenmkgeppbflobdenhhabjlaj"; } # iCloud Passwords
        { id = "fcoeoabgfenejglbffodgkkbkcdhcgfn"; } # Claude in Chrome
      ];
    };
  };
}
