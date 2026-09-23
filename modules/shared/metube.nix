# home-manager module: local.meTube — MeTube on 127.0.0.1, started at login.
#
# The app ships with no login. SECURITY.md says that is intentional: a login,
# if wanted, is a reverse proxy. This agent binds 127.0.0.1 so the open API is
# only reachable from this Mac.
#
# CORS_ALLOWED_ORIGINS=* is required for the Chrome extension. Its requests
# come from chrome-extension://<id>, which is not a site we can name. The
# README says to use * for that case. * does not send credentials, and there
# is no login cookie to send.
#
# WHY HOME MANAGER AND NOT nix-darwin's `launchd.user.agents` (moved 2026-09-22).
# Both layers can place a user agent; only one repairs it. nix-darwin's
# activation is diff-gated — `if ! diff` the plist, load, else skip (pinned
# nix-darwin modules/system/launchd.nix:19,36) — and modules/darwin/
# launchd-reconcile.nix covers `launchd.daemons` ONLY, so a nix-darwin user
# agent that has fallen out of its launchd domain is never re-bootstrapped.
# Home Manager probes with `launchctl print` and re-bootstraps an
# up-to-date-but-not-loaded agent (pinned home-manager modules/launchd/
# default.nix:411-419) — which is why 22 HM agents survived the 2026-09-22
# outage while the system tier did not (launchd-reconcile.nix:8-11).
#
# The move renames the Label `org.nixos.metube` -> `org.nix-community.home.metube`.
# nix-darwin unloads and removes any user-agent plist the new generation lacks
# (pinned modules/system/launchd.nix:150-161), so the old one goes in the same
# switch — but that removal is SINGLE-TRANSITION. Run `nix run .#launchd-doctor`
# after the first activation; its orphaned-plists section exists for exactly this.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.meTube;
  pkg = pkgs.callPackage ../../packages/metube.nix { };
  # Downloads must NOT live inside the state directory. main.py's
  # state_dir_guard returns 404 for any file whose real path is under
  # STATE_DIR, so cookies.txt cannot be fetched through /download/. The
  # first layout put the mp3s in a child of STATE_DIR, so the button
  # 404'd and Chromium saved that text/plain error as a .txt.
  home = config.home.homeDirectory;
  # Video and audio go to the standard home folders. State stays under
  # ~/.local so cookies.txt is not inside either of those trees: the
  # download routes 404 anything whose path is under STATE_DIR.
  rootDir = "${home}/.local/share/metube";
  stateDir = "${rootDir}/state";
  videoDir = "${home}/Movies";
  audioDir = "${home}/Music";
  # NOT `nix-metube`: modules/shared/launchd-launcher.nix already defaults
  # `launcher.name = "nix-${name}"` for every agent, so the arg0 the operator
  # and TCC see is `nix-metube` regardless. Naming the inner script that too
  # produced `nix-metube` exec'ing `nix-metube` — two store paths, one name.
  runner = pkgs.writeShellScriptBin "metube-run" ''
    set -eu
    mkdir -p ${lib.escapeShellArg videoDir} ${lib.escapeShellArg audioDir} \
      ${lib.escapeShellArg stateDir} ${lib.escapeShellArg "${rootDir}/tmp"}
    # State files from the first layout sat next to the downloads directory.
    legacy=${lib.escapeShellArg rootDir}
    for name in completed.json queue.json pending.json subscriptions.json cookies.txt; do
      if [ -f "$legacy/$name" ] && [ ! -e ${lib.escapeShellArg stateDir}/"$name" ]; then
        mv "$legacy/$name" ${lib.escapeShellArg stateDir}/"$name"
      fi
    done
    # Media from that layout. Move once, and do not overwrite a file already
    # in Movies or Music.
    old=${lib.escapeShellArg "${rootDir}/downloads"}
    audio=${lib.escapeShellArg audioDir}
    video=${lib.escapeShellArg videoDir}
    if [ -d "$old" ]; then
      find "$old" -maxdepth 1 -type f \( \
        -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.opus' -o -iname '*.flac' \
        -o -iname '*.wav' -o -iname '*.aac' -o -iname '*.ogg' \
        \) -exec sh -c 'dest="$1/$(basename "$2")"; [ -e "$dest" ] || mv "$2" "$dest"' _ "$audio" {} \;
      find "$old" -maxdepth 1 -type f \( \
        -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.mov' \
        \) -exec sh -c 'dest="$1/$(basename "$2")"; [ -e "$dest" ] || mv "$2" "$dest"' _ "$video" {} \;
    fi
    export HOST=127.0.0.1
    export PORT=${toString cfg.port}
    export DOWNLOAD_DIR=${lib.escapeShellArg videoDir}
    export AUDIO_DOWNLOAD_DIR=${lib.escapeShellArg audioDir}
    export STATE_DIR=${lib.escapeShellArg stateDir}
    export TEMP_DIR=${lib.escapeShellArg "${rootDir}/tmp"}
    export CORS_ALLOWED_ORIGINS='*'
    export MAX_CONCURRENT_DOWNLOADS=${toString cfg.maxConcurrentDownloads}
    # Age-gated YouTube needs a signed-in browser session. This is the
    # Chromium profile the extension runs in. A one-element list is what
    # yt-dlp's cookiesfrombrowser parser accepts. The secret stays in the
    # browser's cookie store; the first download may raise a Keychain prompt
    # for "Chromium Safe Storage".
    export YTDL_OPTIONS=${
      lib.escapeShellArg (
        builtins.toJSON {
          cookiesfrombrowser = [ "chromium" ];
        }
      )
    }
    exec ${lib.getExe pkg}
  '';
in
{
  options.local.meTube = {
    enable = lib.mkEnableOption "MeTube on 127.0.0.1, started at login";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Loopback port. The Chrome extension is pointed at this.";
    };

    maxConcurrentDownloads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "How many yt-dlp downloads run at once. MeTube's own default.";
    };
  };

  # The darwin test is NOT redundant with home-manager's own launchd assertion:
  # `launchd.enable` defaults to isDarwin, so on nixpi/nixvm the agent would
  # silently evaluate to nothing while `pkgs.callPackage` above still had to
  # build for aarch64-linux. modules/shared/home.nix imports this file for
  # EVERY host. House spelling: modules/shared/next-right-thing.nix:170.
  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    launchd.agents.metube = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe runner) ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        StandardOutPath = "${home}/Library/Logs/metube.log";
        StandardErrorPath = "${home}/Library/Logs/metube.log";
      };
    };
  };
}
