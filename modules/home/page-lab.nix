# The fleet half of page-lab's DEDICATED browser mode: a content-hash-pinned
# Chrome for Testing that page-lab launches on its own profile dirs, never the
# operator's daily Chromium. Design: github:kattakath/skills
# docs/page-lab-vnext-design.md §§ 4.1, 6 (plan step 6).
#
# ---- upstream-first --------------------------------------------------------
# grepped the pinned home-manager/modules for playwright | PLAYWRIGHT | page-lab |
# chrome-devtools: one hit, programs.github-copilot-cli's MCP example, which
# launches `@playwright/mcp` and pins no browser. No option owns "pin a browser
# for a plugin", so this is plain `home.sessionVariables` + `xdg.configFile`.
# The BROWSER is off the shelf: nixpkgs `playwright-driver.browsers-chromium`
# (fixed-output CfT). nixpkgs `chromium` lost on platform — `*-linux` only, so
# it cannot run on the Mac. The other candidates the design rejects are in its § 6.
#
# ---- why the pin lives HERE ------------------------------------------------
# A plugin cannot carry a /nix/store path. So the fleet exports PAGE_LAB_CHROME
# and the overlay points page-lab at that variable. The env var is the ONE copy
# of the path; the overlay holds no path at all.
#
# ---- what this does NOT do -------------------------------------------------
# It creates no profile dir and sets no Time Machine exclusion. page-lab's
# launcher owns `${XDG_STATE_HOME}/page-lab/profiles/<name>` (0700, `tmutil
# addexclusion`). The agent-side Read deny on that tree is
# modules/_lib/secret-read-paths.nix.
#
# darwin only. The executable path below is the macOS zip layout. aarch64-linux
# ships `chrome-linux-arm64/chrome` instead (nixpkgs playwright/chromium.nix) and
# no host here needs it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.pageLab;
  pw = pkgs.playwright-driver;

  # `browsers-chromium` is a linkFarm keyed `chromium-<revision>`. The revision
  # comes from the same derivation's passthru, so a nixpkgs bump cannot leave
  # this pointing at a directory that no longer exists.
  chromeExecutable =
    "${pw.browsers-chromium}/chromium-${pw.browsersJSON.chromium.revision}"
    + "/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";

  # The overlay holds only what the plugin's path-free defaults cannot know:
  # where the dedicated profiles' executable comes from. `daily` is attach mode
  # and needs nothing here. The schema `page-lab/profile@1` is the design's
  # § 4.1 table. It is not yet shipped by the plugin (skills plan step 1), so
  # this shape is the fleet's reading and must be re-checked when it lands.
  overlay = {
    schema = "page-lab/profile@1";
    profiles =
      map
        (name: {
          inherit name;
          executable.source = "env";
        })
        [
          "lab"
          "lab-diag"
        ];
  };

  # Built by a check, not by `builtins.toJSON` alone: the `test -x` fails the
  # BUILD if the zip layout ever moves. The output carries no store path, so
  # the build-time dependency on the browser adds no runtime reference.
  overlayFile =
    pkgs.runCommand "page-lab-profiles.json"
      {
        json = builtins.toJSON overlay;
        passAsFile = [ "json" ];
      }
      ''
        test -x ${lib.escapeShellArg chromeExecutable} || {
          echo "page-lab.nix: no executable at ${chromeExecutable}" >&2
          exit 1
        }
        cp "$jsonPath" "$out"
      '';
in
{
  options.local.pageLab.enable = lib.mkEnableOption ''
    page-lab's dedicated browser: PAGE_LAB_CHROME pointing at nixpkgs'
    Chrome for Testing, plus the page-lab/profiles.json overlay in XDG_CONFIG_HOME.
    The browser closure is ~370 MiB, so enable it only where page-lab runs
  '';

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    # Interpolating the store path is what roots the closure in the profile.
    # The linkFarm has no bin/, so a home.packages entry would add nothing.
    home.sessionVariables.PAGE_LAB_CHROME = chromeExecutable;

    xdg.configFile."page-lab/profiles.json".source = overlayFile;
  };
}
