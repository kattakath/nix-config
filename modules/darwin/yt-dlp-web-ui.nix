# yt-dlp-web-ui as a per-user launchd agent on the Mac.
#
# Loopback only. Downloads stay in the login user's home, the same directory
# the Colima trial was aimed at. A system daemon would put them in /var/lib
# and the operator would not see them in the folder they already have.
#
# The agent binary is built from source (packages/yt-dlp-web-ui.nix). yt-dlp,
# ffmpeg, deno and aria2 come from nixpkgs and are put on PATH: launchd does
# not inherit Homebrew, and YouTube extraction fails without deno.
{
  config,
  lib,
  pkgs,
  loginName,
  ...
}:
let
  cfg = config.local.ytDlpWebUi;
  pkg = pkgs.callPackage ../../packages/yt-dlp-web-ui.nix { };
  stateDir = "/Users/${loginName}/.local/share/yt-dlp-webui";
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
  # Basename `nix-yt-dlp-web-ui`, not a bare shell. Login Items names a
  # background item by ProgramArguments[0], and a /bin/sh wrapper shows up as
  # "sh". See modules/darwin/core.nix.
  runner = pkgs.writeShellScriptBin "nix-yt-dlp-web-ui" ''
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

  config = lib.mkIf cfg.enable {
    launchd.user.agents.yt-dlp-web-ui = {
      serviceConfig = {
        ProgramArguments = [ "${runner}/bin/nix-yt-dlp-web-ui" ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        # No WorkingDirectory. launchd chdirs before the script runs, and the
        # state directory does not exist until the script creates it.
        # Library/Logs already exists. stateDir does not, until the script
        # creates it, and launchd opens these files before that script runs.
        StandardOutPath = "/Users/${loginName}/Library/Logs/yt-dlp-web-ui.log";
        StandardErrorPath = "/Users/${loginName}/Library/Logs/yt-dlp-web-ui.log";
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
