# home-manager module: local.ytDlpWebUi — yt-dlp-web-ui on 127.0.0.1.
#
# Loopback only. Downloads stay in the login user's home, the same directory
# the Colima trial was aimed at. A system daemon would put them in /var/lib
# and the operator would not see them in the folder they already have.
#
# The agent binary is built from source (packages/yt-dlp-web-ui.nix). yt-dlp,
# ffmpeg, deno and aria2 come from nixpkgs and are put on PATH: launchd does
# not inherit Homebrew, and YouTube extraction fails without deno.
#
# WHY HOME MANAGER AND NOT nix-darwin's `launchd.user.agents` — see the same
# paragraph in modules/shared/metube.nix; both moved layers together on
# 2026-09-22 for the self-heal Home Manager has and the system tier does not.
# The Label becomes `org.nix-community.home.yt-dlp-web-ui`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.ytDlpWebUi;
  pkg = pkgs.callPackage ../../packages/yt-dlp-web-ui.nix { };
  home = config.home.homeDirectory;
  stateDir = "${home}/.local/share/yt-dlp-webui";
  configFile = pkgs.writeText "yt-dlp-web-ui-config.yml" ''
    server:
      host: 127.0.0.1
      port: ${toString cfg.port}
      queue_size: ${toString cfg.queueSize}
    paths:
      download_path: ${stateDir}/downloads
      downloader_path: ${lib.getExe pkgs.yt-dlp}
      local_database_path: ${stateDir}
      js_runtime_path: deno:${lib.getExe pkgs.deno}
    logging:
      enable_file_logging: false
  '';
  # Plain name, not `nix-yt-dlp-web-ui`: modules/shared/launchd-launcher.nix
  # already renames arg0 to `nix-<agent>`, which is what Login Items and TCC
  # attribute the process by. Two scripts with the same name was the old shape.
  runner = pkgs.writeShellScriptBin "yt-dlp-web-ui-run" ''
    set -eu
    mkdir -p ${lib.escapeShellArg "${stateDir}/downloads"}
    exec ${lib.getExe pkg} -conf ${configFile}
  '';
in
{
  options.local.ytDlpWebUi = {
    enable = lib.mkEnableOption "yt-dlp-web-ui on 127.0.0.1, started at login";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3033;
      description = "Loopback port for the UI and /api/v1.";
    };

    queueSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "How many yt-dlp processes run at once. Not a cap on waiting URLs.";
    };
  };

  # isDarwin is load-bearing, not decoration — modules/shared/home.nix imports
  # this for nixpi and nixvm too, and `launchd.enable` defaulting to isDarwin
  # would hide the agent while still forcing the package to build there.
  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    launchd.agents.yt-dlp-web-ui = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe runner) ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        # No WorkingDirectory. launchd chdirs before the script runs, and the
        # state directory does not exist until the script creates it.
        # Library/Logs already exists. stateDir does not, until the script
        # creates it, and launchd opens these files before that script runs.
        StandardOutPath = "${home}/Library/Logs/yt-dlp-web-ui.log";
        StandardErrorPath = "${home}/Library/Logs/yt-dlp-web-ui.log";
        EnvironmentVariables = {
          PATH = lib.makeBinPath [
            pkgs.yt-dlp
            pkgs.ffmpeg
            pkgs.deno
            pkgs.aria2
            pkgs.coreutils
          ];
        };
      };
    };
  };
}
