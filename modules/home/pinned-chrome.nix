# A content-hash-pinned Chrome for Testing, exported as PUPPETEER_EXECUTABLE_PATH,
# plus the three agent browser-rail MCP launchers and a login helper (below).
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
  cftApp =
    "${pw.browsers-chromium}/chromium-${pw.browsersJSON.chromium.revision}"
    + "/chrome-mac-arm64/Google Chrome for Testing.app";
  chromeExecutable = cftApp + "/Contents/MacOS/Google Chrome for Testing";

  # Fails the BUILD if the zip layout ever moves, instead of puppeteer failing at
  # render time. The output holds no store path, so it adds no runtime reference.
  layoutCheck = pkgs.runCommand "pinned-chrome-layout-check" { } ''
    test -x ${lib.escapeShellArg chromeExecutable} || {
      echo "pinned-chrome.nix: no executable at ${chromeExecutable}" >&2
      exit 1
    }
    mkdir -p "$out"
  '';

  # ---- the three agent browser rails (page-tools plugin, github:kattakath/skills) ----
  # Every argument lives HERE, so each client config names only a command and has
  # nothing to drift. Claude Code, grok and qwen read the plugin's .mcp.json; agy
  # cannot, so it gets the same three names through programs.antigravity-cli below.
  #
  # playwright-chrome-mcp: nixpkgs playwright-mcp in --extension mode drives the
  #   operator's REAL Chrome through the force-installed Playwright Extension
  #   (infra/google-workspace/chrome.nix), one tab group per client. Measured
  #   2026-11-18: trusted clicks, no listening port. Rejected: Kapture (one
  #   maintainer, an Origin-less loopback port) and CDP autoConnect (whole browser).
  # chrome-devtools-cft-mcp: Google's chrome-devtools-mcp LAUNCHING the pinned CfT
  #   above, headless, throwaway profile, over a pipe. Measured the same day: trusted
  #   clicks. Not in nixpkgs, so it rides a pinned npx spec (the kapture-mcp precedent,
  #   docs/declarative-gaps-adr.md). It refuses chrome:// URLs by itself.
  # chrome-devtools-cft-profile-mcp: the same server on the same CfT, but HEADED and on a
  #   PERSISTENT profile, so a site login survives between sessions. CfT is a separate app
  #   (`com.google.chrome.for.testing`), and Chrome's enrollment and policy do not reach it.
  #   Measured 2026-11-19: CfT 156 answered on --remote-debugging-port while
  #   RemoteDebuggingAllowed = false was set for the enrolled Chrome. The launcher keeps the
  #   pipe anyway, so no local app gets a port into the logged-in profile.
  #   --ignoreDefaultChromeArg=--use-mock-keychain: puppeteer's default args include it, and
  #   that flag encrypts cookies with a fixed mock key instead of the login Keychain. Without
  #   it, the cookies stay Keychain-encrypted and match the ones `cft-profile` writes.
  # cft-profile: opens that profile by hand, with NO automation flags, so the operator can
  #   log in. Google's sign-in can refuse a browser carrying --enable-automation. Chrome
  #   locks a profile to one process, so close this window before the agent launches its own.
  playwrightChromeMcp = pkgs.writeShellApplication {
    name = "playwright-chrome-mcp";
    runtimeInputs = [ pkgs.playwright-mcp ];
    # --output-dir: snapshots and logs otherwise land in the agent's CWD (a repo).
    text = ''exec playwright-mcp --extension --output-dir "''${XDG_STATE_HOME:-$HOME/.local/state}/playwright-mcp" "$@"'';
  };
  chromeDevtoolsCftMcp = pkgs.writeShellApplication {
    name = "chrome-devtools-cft-mcp";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npx -y chrome-devtools-mcp@1.13.0 \
        --executablePath ${lib.escapeShellArg chromeExecutable} \
        --isolated --headless --no-usage-statistics "$@"
    '';
  };
  cftProfileDir = ''"''${XDG_STATE_HOME:-$HOME/.local/state}/cft-profile"'';
  chromeDevtoolsCftProfileMcp = pkgs.writeShellApplication {
    name = "chrome-devtools-cft-profile-mcp";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npx -y chrome-devtools-mcp@1.13.0 \
        --executablePath ${lib.escapeShellArg chromeExecutable} \
        --userDataDir ${cftProfileDir} \
        --ignoreDefaultChromeArg=--use-mock-keychain \
        --no-usage-statistics "$@"
    '';
  };
  cftProfile = pkgs.writeShellApplication {
    name = "cft-profile";
    text = ''
      # open -n, not a backgrounded exec: LaunchServices owns the process, so closing the
      # terminal does not take the window with it.
      exec /usr/bin/open -na ${lib.escapeShellArg cftApp} --args --user-data-dir=${cftProfileDir} --no-first-run "$@"
    '';
  };
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

    home.packages = [
      playwrightChromeMcp
      chromeDevtoolsCftMcp
      chromeDevtoolsCftProfileMcp
      cftProfile
    ];

    # agy only: the module writes ~/.gemini/config/mcp_config.json. `package = null`
    # because agy is already machine-wide (hosts/macos.nix environment.systemPackages).
    programs.antigravity-cli = {
      enable = true;
      package = null;
      mcpServers = {
        playwright.command = "playwright-chrome-mcp";
        chrome-devtools.command = "chrome-devtools-cft-mcp";
        cft-profile.command = "chrome-devtools-cft-profile-mcp";
      };
    };

    # qwen reads the page-tools PLUGIN itself (it installs Claude-marketplace plugins as
    # git-cloned extensions under ~/.qwen/extensions), so no second copy of the server list.
    # Its extension store is qwen's own state, so this is a guard, like claudeCodePlugins in
    # ./claude-plugins.nix: install only when missing, with --auto-update so a page-tools
    # release reaches it without Nix. qwen is machine-wide (hosts/macos.nix).
    home.activation.qwenPageTools = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      export PATH="${pkgs.git}/bin:$PATH"
      if [ ! -d "${config.home.homeDirectory}/.qwen/extensions/page-tools" ]; then
        ${lib.getExe pkgs.qwen-code} extensions install \
          https://github.com/kattakath/skills:page-tools --auto-update --consent 2>&1 || true
      fi
    '';
  };
}
