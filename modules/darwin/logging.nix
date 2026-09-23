# Rotation for EVERY launchd log this fleet declares — agents and daemons,
# short-lived and long-lived. Two mechanisms, because macOS gives us two
# different physics and no single tool covers both well.
#
#   upstream option system.newsyslog.{enable,files} exists -> using it
#   (pinned nix-darwin modules/system/newsyslog.nix:11-160, registered at
#   modules/module-list.nix:45). It was never used by this fleet, which is how
#   ~/Library/Logs reached 231 MB by 2026-09-22.
#
# THE PHYSICS. launchd opens StandardOutPath ONCE at spawn and hands the fd to
# the child. macOS newsyslog does rename+create and has NO copytruncate (man 5
# newsyslog.conf: the flags are B C D G J N U Z only). So for a LONG-LIVED
# KeepAlive agent, rename+create renames the file out from under a process that
# keeps writing to the same inode — the archive grows, the fresh file stays
# empty, and not one byte is reclaimed.
#
# WHY NOT pidFile + signal, which this header used to defer to. The pinned
# nix-darwin module really does expose `pidFile`/`signal` (newsyslog.nix:130-160)
# — the option grep returns a hit — but the option cannot do the job, and that
# is the half of .claude/rules/upstream-first.md that matters here. newsyslog
# only DELIVERS the signal; the program must reopen its own path. Measured:
# `cloudflared --help` has zero sighup/reopen/rotate surface, and mcp-proxy is a
# Python process with no handler either. The only signal that would reclaim
# anything is one that kills the process so KeepAlive respawns it — i.e.
# rotation-by-restart, which drops the tunnel and any in-flight download. So the
# right move is a DIFFERENT off-the-shelf thing, not a pid-file seam bolted into
# home-manager's launcher (which upstream has no hook for: pinned home-manager
# modules/launchd/default.nix:140-143 emits exactly `#!<shell>` + `exec <args>`).
#
# WHAT ACTUALLY RECLAIMS: truncate-in-place, because launchd's inherited fd is
# O_APPEND. MEASURED on this Mac 2026-09-22, not reasoned — `lsof +fg -p 61665`
# on the live mcp-gateway prints file flags `R,W,AP` on fd 1u and 2u, and AP is
# O_APPEND. Every write therefore seeks to EOF, so truncating the file to zero
# is reclaimed immediately and completely BY THE SAME RUNNING PROCESS: no
# signal, no pid file, no restart, no cooperation from the program. (The trap
# this rules out: a log the program opened ITSELF without O_APPEND would keep
# its old offset and become a sparse file with a multi-MB NUL hole. None of
# these are — launchd opened all of them.)
#
# So: `pkgs.logrotate` with its own `copytruncate` directive, on a launchd
# StartInterval tick. logrotate is THE Unix log rotator and copytruncate is its
# named feature for exactly this case — its man page's rationale sentence
# describes cloudflared verbatim: "It can be used when some program cannot be
# told to close its logfile and thus might continue writing (appending) to the
# previous log file forever." That buys size thresholds, N compressed
# generations and a state file off the shelf. The custom surface is the config
# + the two ticks; neither pinned input ships a logrotate module (grepped both,
# zero hits), and that is the motto's required "why the off-the-shelf option
# didn't fit" disclosure — it is a far smaller surface than a launcher fork that
# would still reclaim nothing from cloudflared.
#
# COST, stated rather than discovered during an incident: copytruncate's own man
# page warns "there is a very small time slice between copying the file and
# truncating it, so some logging data might be lost". Acceptable for diagnostic
# chatter. It is why the re-exec set below keeps newsyslog's lossless
# rename+create instead of being folded into one mechanism.
#
# NOTHING IS HAND-PICKED ANY MORE. The old version carried a typed list of which
# agents re-exec. Classification is now derived from the KeepAlive shape:
#   KeepAlive absent                  -> re-exec   (interval / one-shot / queue)
#   KeepAlive.SuccessfulExit == false -> re-exec   (retry-until-success one-shot)
#   anything else                     -> long-lived
# The residual case is deliberately conservative: a re-exec agent misfiled as
# long-lived still gets its bytes back (copytruncate works either way), while
# the reverse silently reclaims nothing. And PATHS WIN OVER AGENTS — a path
# claimed by any long-lived declaration is removed from the newsyslog set, which
# is what resolves /var/log/ollama-daemon.log being written by BOTH the
# KeepAlive `ollama` daemon and the StartInterval `ollama-metal-guard`.
#
# PATHS ARE DERIVED, NOT TYPED. Two traps a hand-written list walks straight into:
#   (a) claude-desktop-mcp-sync declares StandardErrorPath and NO StandardOutPath,
#       so enumerating one key silently misses the file.
#   (b) media-queue and media-queue-power declare the SAME path (4 declarations,
#       one file), so a per-agent list double-covers it. newsyslog keys on the
#       PATH, so the set must be deduped.
# Reading both keys off the composed agents and uniq-ing makes both structural.
#
# THREE SOURCES, TWO TIERS. Home Manager agents and nix-darwin user agents are
# the user tier (rotated as the login user); `launchd.daemons` is the root tier
# and needs its own copy of the tick, because a user agent cannot truncate a
# root-owned file in /var/log. This module lives at the nix-darwin layer
# precisely because that is the only layer that can see all three.
{
  config,
  lib,
  pkgs,
  loginName,
  ...
}:
let
  hmAgents = config.home-manager.users.${loginName}.launchd.agents or { };
  darwinAgents = config.launchd.user.agents or { };
  daemons = config.launchd.daemons or { };

  home = "/Users/${loginName}";

  # Derived classification — see the header. Conservative on purpose: anything
  # that is not provably a re-exec is treated as long-lived.
  isReExec = ka: ka == null || (builtins.isAttrs ka && (ka.SuccessfulExit or null) == false);

  # Both keys off every named agent, nulls and empties dropped. keyPath is the
  # one place the two layers differ: home-manager stores the raw plist under
  # `config`, nix-darwin under `serviceConfig`.
  split =
    attrs: keyPath:
    let
      each =
        name:
        let
          s = lib.attrByPath keyPath { } attrs.${name};
          paths = lib.filter (p: p != null && p != "") [
            (s.StandardOutPath or null)
            (s.StandardErrorPath or null)
          ];
        in
        {
          reExec = lib.optionals (isReExec (s.KeepAlive or null)) paths;
          longLived = lib.optionals (!isReExec (s.KeepAlive or null)) paths;
        };
      all = map each (lib.attrNames attrs);
    in
    {
      reExec = lib.unique (lib.concatMap (x: x.reExec) all);
      longLived = lib.unique (lib.concatMap (x: x.longLived) all);
    };

  hmSplit = split hmAgents [ "config" ];
  darwinSplit = split darwinAgents [ "serviceConfig" ];
  daemonSplit = split daemons [ "serviceConfig" ];
  userSplit = {
    reExec = lib.unique (hmSplit.reExec ++ darwinSplit.reExec);
    longLived = lib.unique (hmSplit.longLived ++ darwinSplit.longLived);
  };

  # A path written by ANY long-lived declaration cannot be rename+create'd, even
  # if a re-exec job also writes it. Long-lived wins globally.
  allLongLived = lib.unique (userSplit.longLived ++ daemonSplit.longLived);
  userReExec = lib.subtractLists allLongLived userSplit.reExec;
  daemonReExec = lib.subtractLists allLongLived daemonSplit.reExec;

  # ---- mechanism 1: newsyslog, for the logs that re-exec ---------------------
  entry = owner: group: path: {
    logfilename = path;
    inherit owner group;
    mode = "644";
    count = 3;
    # newsyslog.conf(5) sizes are in KILOBYTES: 1024 = 1 MB, so each log costs at
    # most ~4 MB on disk (current + 3 gzipped rotations). Size-triggered only —
    # `when` is left unset, because these are small and bursty, not daily.
    size = "1024";
    # N: nothing to signal — these re-exec on their own, which is the whole
    # reason they are in this set and not the copytruncate one.
    # Z: gzip the rotations.
    flags = [
      "N"
      "Z"
    ];
  };

  # ---- mechanism 2: logrotate --copytruncate, for the logs that do not -------
  # Same budget as an newsyslog entry above: 1 MB live, 3 gzipped generations.
  # `missingok` because an agent may never have run; `notifempty` so an idle
  # service is not rotated into three empty archives.
  mkConf =
    name: paths:
    pkgs.writeText "logrotate-${name}.conf" (
      lib.concatMapStringsSep "\n" (p: ''
        "${p}" {
          size 1024k
          rotate 3
          copytruncate
          compress
          missingok
          notifempty
          nomail
        }
      '') paths
    );

  # writeShellApplication, not writeShellScriptBin: `runtimeInputs` bakes gzip
  # onto PATH, and a launchd job starts with a near-empty one. logrotate shells
  # out to gzip for `compress`, so without this the rotation silently stops
  # compressing. (pgvector-local.nix:246-248 uses the same idiom for the same
  # reason.) The `nix-` prefix IS hand-written here: launchd-launcher.nix only
  # renames home-manager agents, and these two are a nix-darwin agent and a
  # nix-darwin daemon.
  mkTick =
    {
      name,
      paths,
      stateFile,
    }:
    pkgs.writeShellApplication {
      name = "nix-${name}";
      runtimeInputs = [ pkgs.gzip ];
      text = ''
        mkdir -p "$(dirname ${lib.escapeShellArg stateFile})"
        exec ${lib.getExe pkgs.logrotate} \
          --state ${lib.escapeShellArg stateFile} \
          ${mkConf name paths}
      '';
    };

  userTick = mkTick {
    name = "file-rotation-logs";
    paths = userSplit.longLived;
    stateFile = "${home}/.local/state/logrotate/agents.state";
  };
  daemonTick = mkTick {
    name = "file-rotation-logs-system";
    paths = daemonSplit.longLived;
    stateFile = "/var/lib/logrotate/daemons.state";
  };
in
{
  # Read-only, internal: what each mechanism ended up covering. Declared so
  # `checks.<system>.launchd-log-rotation` can compare the module's own answer
  # against a set it re-walks off the composed agents itself — a check that read
  # only the module's inputs would agree with it by construction.
  options.local.launchdLogRotation = {
    reExecPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = userReExec ++ daemonReExec;
      description = "Log paths handed to system.newsyslog (rename+create).";
    };
    longLivedPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = allLongLived;
      description = "Log paths handed to logrotate --copytruncate.";
    };
  };

  config = lib.mkIf (config.networking.hostName == "macos") {
    system.newsyslog = {
      enable = true;
      files.nix-fleet =
        map (entry loginName "staff") userReExec ++ map (entry "root" "wheel") daemonReExec;
    };

    # Hourly, matching the Trash sweeps in modules/darwin/core.nix. This tick is
    # itself a re-exec job, so its own log lands in the newsyslog set above with
    # no special-casing — the classification sees it like any other agent.
    launchd.user.agents.file-rotation-logs = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe userTick) ];
        StartInterval = 3600;
        RunAtLoad = true;
        StandardOutPath = "${home}/Library/Logs/file-rotation-logs.log";
        StandardErrorPath = "${home}/Library/Logs/file-rotation-logs.log";
      };
    };

    # The root tier. A login-user agent cannot truncate /var/log/ollama-daemon.log
    # (root:wheel), and that file is the one log in the fleet NO mechanism could
    # reach before: it is written by the KeepAlive `ollama` daemon, so newsyslog
    # can never reclaim it, and it is shared with `ollama-metal-guard`, so even a
    # re-exec rename would orphan the long-lived writer's fd.
    launchd.daemons.file-rotation-logs-system = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe daemonTick) ];
        StartInterval = 3600;
        RunAtLoad = true;
        StandardOutPath = "/var/log/file-rotation-logs.log";
        StandardErrorPath = "/var/log/file-rotation-logs.log";
      };
    };
  };
}
