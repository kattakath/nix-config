# A content-hash-pinned Chrome for Testing, exported as PUPPETEER_EXECUTABLE_PATH.
# puppeteer renders the JSON Resume PDFs (packages/jsonresume.nix), and a render must
# not change because the daily browser auto-updated overnight. So puppeteer gets a
# browser that moves only with a nixpkgs bump. listing-lens pins the same nixpkgs
# derivation in its own flake, independently of this module.
#
# ---- upstream-first --------------------------------------------------------
# grepped the pinned home-manager/modules for playwright | PLAYWRIGHT | puppeteer |
# PUPPETEER | chrome-devtools (re-run 2026-11-14): one hit, programs.github-copilot-cli's MCP example, which
# launches `@playwright/mcp` and pins no browser. No option owns "pin a browser
# for a tool", so this is plain `home.sessionVariables`.
# The BROWSER is off the shelf: nixpkgs `playwright-driver.browsers-chromium`
# (fixed-output CfT). nixpkgs `chromium` lost on platform — `*-linux` only, so
# it cannot run on the Mac.
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
  cfg = config.local.pinnedChrome;
  pw = pkgs.playwright-driver;

  # `browsers-chromium` is a linkFarm keyed `chromium-<revision>`. The revision
  # comes from the same derivation's passthru, so a nixpkgs bump cannot leave
  # this pointing at a directory that no longer exists.
  chromeExecutable =
    "${pw.browsers-chromium}/chromium-${pw.browsersJSON.chromium.revision}"
    + "/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";

  # Fails the BUILD if the zip layout ever moves, instead of puppeteer failing at
  # render time. The output holds no store path, so it adds no runtime reference.
  layoutCheck = pkgs.runCommand "pinned-chrome-layout-check" { } ''
    test -x ${lib.escapeShellArg chromeExecutable} || {
      echo "pinned-chrome.nix: no executable at ${chromeExecutable}" >&2
      exit 1
    }
    mkdir -p "$out"
  '';
in
{
  options.local.pinnedChrome.enable = lib.mkEnableOption ''
    a Nix-pinned Chrome for Testing as PUPPETEER_EXECUTABLE_PATH, so puppeteer's
    PDF renders never follow an auto-updating browser. The browser closure is
    ~370 MiB, so enable it only where puppeteer runs
  '';

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    # Interpolating the store path is what roots the closure in the profile.
    # The linkFarm has no bin/, so a home.packages entry would add nothing.
    home.sessionVariables.PUPPETEER_EXECUTABLE_PATH = chromeExecutable;

    # Puts the layout check in the build graph; it installs nothing.
    home.extraDependencies = [ layoutCheck ];
  };
}
