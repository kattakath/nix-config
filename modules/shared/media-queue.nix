# media-queue (macOS only) — the launchd half of the media toolkit's work queue.
#
# The Finder Services no longer DO the work; they enqueue it and return. This
# module is what turns that queue into a service, and almost all of it is
# launchd configuration rather than code:
#
#   QueueDirectories               THE QUEUE. launchd starts the worker whenever
#                                  the directory is non-empty, and again after
#                                  it exits if anything is left. No polling
#                                  loop, no scheduler, no daemon of ours.
#   ProcessType = "Background"     THE LOAD CONTROL. macOS throttles CPU and I/O
#                                  bandwidth for Background jobs specifically so
#                                  they cannot disrupt the user experience — a
#                                  200-file re-encode stops being something you
#                                  feel in the foreground. `Nice` and
#                                  `LowPriorityIO` reinforce it.
#   KeepAlive.SuccessfulExit=false THE RETRY, for the worker PROCESS. Per-JOB
#   + ThrottleInterval             retry is the worker's own three-strikes rule;
#                                  this covers the worker dying outright, and
#                                  ThrottleInterval bounds the restart rate so a
#                                  reproducible crash cannot spin.
#   RunAtLoad                      recovery: a logout mid-batch left jobs in the
#                                  queue, and login drains them.
#   StandardOutPath                the log, written where Console.app looks for
#                                  it, so the viewer is off-the-shelf too.
#
# QueueDirectories ALONE makes pickup as slow as ThrottleInterval, because the
# throttle spaces every start of a job and not merely its respawns — measured on
# this Mac, a right-click waited a full minute at ThrottleInterval = 60. So
# `media-enqueue` also `launchctl kickstart`s the agent: the watch stays as the
# safety net for jobs that arrive some other way, and the click no longer waits.
#
# The agent's arg0 is `nix-media-queue` — modules/shared/hm-launchd forces
# `nix-<name>` on every agent it emits. That is not cosmetic here: per
# .claude/rules/launchd-naming.md a /nix/store arg0 is what lets the worker READ
# the TCC-protected folders it exists to work on (~/Pictures, ~/Desktop,
# ~/Downloads). A bare interpreter would run, log nothing useful, and quietly do
# no work.
#
# STATUS lives in the menu bar via SwiftBar, which is the off-the-shelf host for
# exactly this: a plugin is a script whose stdout becomes the menu, so there is
# no UI code here at all. macOS has no native way to drive a menu-bar item from
# a script — NSStatusItem needs an app, Shortcuts' "Pin in Menu Bar" is a
# launcher rather than a display — so this is the standard pattern, not a
# reinvention. Two findings, both measured on this Mac rather than assumed:
#
#   - `defaults write com.ameba.SwiftBar PluginDirectory <path>` IS honoured and
#     is what makes the plugin folder declarative. SwiftBar 2.0.1's `--folders`
#     launch argument is NOT: launched with it and nothing else, SwiftBar never
#     ran the plugin.
#   - A plugin reached through a SYMLINK runs fine, so `home.file` is enough.
#     This is the opposite of the Automator bundles next door, which must be
#     copied because NSFileWrapper rejects a symlinked document.wflow.
#
# Sparkle's auto-update is turned off: the app lives in /nix/store and cannot
# update itself, so the only thing an update check can produce is a nag.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  home = config.home.homeDirectory;
  stateDir = "${home}/Library/Application Support/nix-media-queue";
  pluginDir = "${stateDir}/plugins";

  mediaQueue = pkgs.callPackage ../../packages/media-queue.nix { };

  # The refresh interval is encoded in the FILENAME — that is SwiftBar's
  # convention, not a setting. 5s is fast enough to feel live while a batch
  # runs and costs nothing while the queue is empty, because the plugin prints
  # nothing when idle and SwiftBar then shows no menu-bar item at all.
  pluginName = "nix-media-queue.5s.sh";
in
lib.mkIf isDarwin {
  home.packages = [
    mediaQueue
    pkgs.swiftbar
  ];

  home.file."Library/Application Support/nix-media-queue/plugins/${pluginName}".source =
    "${mediaQueue}/bin/media-queue-status";

  targets.darwin.defaults."com.ameba.SwiftBar" = {
    PluginDirectory = pluginDir;
    # Declared, because SwiftBar's own menu can turn the status plugin off in
    # one click — "Disable All" sits two items above "Open Plugin Folder" — and
    # a disabled plugin fails SILENTLY: the queue keeps working, the menu-bar
    # item simply never appears, and the only clue is SwiftBar falling back to
    # showing its own name. Measured on this Mac: disabled → a "SwiftBar" text
    # item; enabled and idle → no status item at all; enabled with work → the
    # plugin's own item. Declaring it empty means activation repairs a stray
    # click. The cost is that turning the plugin off from SwiftBar's menu no
    # longer sticks, which is the right trade for a plugin this repo installs
    # and whose whole job is to be visible when something is queued.
    DisabledPlugins = [ ];
    # A /nix/store app cannot update itself; an update check can only nag.
    SUEnableAutomaticChecks = false;
    SUAutomaticallyUpdate = false;
  };

  launchd.agents = {
    # The worker. Started by launchd whenever the queue directory is non-empty.
    media-queue = {
      enable = true;
      config = {
        ProgramArguments = [ "${mediaQueue}/bin/media-worker" ];
        QueueDirectories = [ "${stateDir}/queue" ];
        RunAtLoad = true;
        ProcessType = "Background";
        Nice = 5;
        LowPriorityIO = true;
        KeepAlive.SuccessfulExit = false;
        # launchd's default, stated rather than inherited because it is
        # LOAD-BEARING FOR LATENCY and not only for crash bounding: the throttle
        # spaces every start of the job, so at 60 a right-click waited a full
        # minute (measured). `media-enqueue` kickstarts the agent, so this is now
        # only the ceiling for the paths that cannot: a job arriving without an
        # enqueue, and a crash restart.
        ThrottleInterval = 10;
        StandardOutPath = "${home}/Library/Logs/nix-media-queue.log";
        StandardErrorPath = "${home}/Library/Logs/nix-media-queue.log";
      };
    };

    # The menu bar. Interactive, not Background: it is a UI element, and
    # throttling it would make the status stale exactly when it matters.
    media-statusbar = {
      enable = true;
      config = {
        ProgramArguments = [
          "${pkgs.swiftbar}/Applications/SwiftBar.app/Contents/MacOS/SwiftBar"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardOutPath = "${home}/Library/Logs/nix-media-statusbar.log";
        StandardErrorPath = "${home}/Library/Logs/nix-media-statusbar.log";
      };
    };
  };
}
