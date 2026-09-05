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
# STATUS IS NOTIFICATIONS ONLY, deliberately. This used to also drive a menu-bar
# item through SwiftBar — a whole GUI app in the closure, a plugin file, a
# `defaults` domain and a second launchd agent, to show a queue depth. It was
# removed as not worth its surface: the notifications already say when a batch is
# queued and how it ended, which is the part an operator acts on, and the log
# answers everything else. The CLI half needs nothing either — `photo-describe`
# run from a shell prints its own progress.
#
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

  mediaQueue = pkgs.callPackage ../../packages/media-queue.nix { };

in
lib.mkIf isDarwin {
  home.packages = [ mediaQueue ];

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

  };
}
