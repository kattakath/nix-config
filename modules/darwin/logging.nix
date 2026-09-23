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
# A THIRD class falls out of that derivation rather than being classified: the
# four open-* login openers (modules/darwin/core.nix, mkNixAgent) declare neither
# StandardOutPath nor StandardErrorPath, so `paths` below is empty for them and
# they reach neither set. Nothing excludes them — there is nothing to exclude.
#
# PATHS ARE DERIVED, NOT TYPED. Two traps a hand-written list walks straight into:
#   (a) claude-desktop-mcp-sync declares StandardErrorPath and NO StandardOutPath,
#       so enumerating one key silently misses the file.
#   (b) media-queue and media-queue-power declare the SAME path (4 declarations,
#       one file), so a per-agent list double-covers it. newsyslog keys on the
#       PATH, so the set must be deduped.
# Reading both keys off the composed agents and uniq-ing makes both structural.
#
# FOUR SOURCES, TWO TIERS. Home Manager `launchd.agents`, nix-darwin
# `launchd.user.agents` and nix-darwin `launchd.agents` are the user tier,
# rotated as the login user; `launchd.daemons` is the root tier and needs its own
# copy of the tick, because a login-user agent cannot truncate a root-owned file
# in /var/log. This module lives at the nix-darwin layer precisely because that
# is the only layer that can see all four.
#
# The fourth source is easy to miss: nix-darwin's `launchd.agents` (system-wide
# /Library/LaunchAgents, pinned modules/launchd/default.nix:139, rendered to
# environment.launchAgents at :211) is a DIFFERENT option from
# `launchd.user.agents` (~/Library/LaunchAgents, rendered to
# environment.userLaunchAgents). Nothing in this tree uses it today — it is
# enumerated anyway so a first use is not silently unrotated behind a green gate.
#
# TIER IS DECIDED BY WHO CAN WRITE THE FILE, not by who classified it. A path
# goes to the ROOT tick if ANY daemon declares it (root can truncate a user-owned
# file; a login user cannot truncate root's), and to the user tick otherwise.
# Without that rule a path that is long-lived in the user tier and re-exec in the
# root tier would leave the newsyslog set GLOBALLY (see "PATHS WIN OVER AGENTS"
# below) and then land on a login-user logrotate that gets EPERM — covered on
# paper, reclaiming nothing in practice. No such path exists today;
# `checks.<system>.launchd-log-rotation` asserts it from the composed daemons
# rather than trusting that to stay true.
#
# THE USER TICK IS A HOME MANAGER AGENT, not `launchd.user.agents` — the same
# move metube and yt-dlp-web-ui made on 2026-09-22, for the same reason.
# nix-darwin's user-agent activation is diff-gated (pinned
# modules/system/launchd.nix:36) and modules/darwin/launchd-reconcile.nix filters
# `config.launchd.daemons` ONLY, so a nix-darwin user agent that falls out of its
# launchd domain is never re-bootstrapped: its plist stops changing and every
# later activation skips it. Home Manager probes with `launchctl print` and
# re-bootstraps (pinned home-manager modules/launchd/default.nix:411-419). A
# rotator that silently stops is precisely the unbounded-growth failure this
# module exists to end, and no flake check can observe a launchd domain. The ROOT
# tick stays a nix-darwin daemon — Home Manager has no root tier — and
# launchd-reconcile.nix already covers that tier.
{
  config,
  lib,
  pkgs,
  loginName,
  ...
}:
let
  hmAgents = config.home-manager.users.${loginName}.launchd.agents or { };
  darwinUserAgents = config.launchd.user.agents or { };
  darwinSystemAgents = config.launchd.agents or { };
  daemons = config.launchd.daemons or { };

  # The nix-darwin option, not a literal — modules/darwin/core.nix:13 and
  # user-folders.nix:28 already read it, and a `/Users/${loginName}` string here
  # would be the hardcoded-home anti-pattern CLAUDE.md § Conventions rejects
  # (and one ast-grep/rules/nix-hardcoded-home-path.yml structurally cannot see,
  # because the interpolation splits the string_fragment).
  home = config.users.users.${loginName}.home;

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
  darwinUserSplit = split darwinUserAgents [ "serviceConfig" ];
  darwinSystemSplit = split darwinSystemAgents [ "serviceConfig" ];
  daemonSplit = split daemons [ "serviceConfig" ];
  userSplit = {
    reExec = lib.unique (hmSplit.reExec ++ darwinUserSplit.reExec ++ darwinSystemSplit.reExec);
    longLived = lib.unique (
      hmSplit.longLived ++ darwinUserSplit.longLived ++ darwinSystemSplit.longLived
    );
  };

  # A path written by ANY long-lived declaration cannot be rename+create'd, even
  # if a re-exec job also writes it. Long-lived wins globally.
  allLongLived = lib.unique (userSplit.longLived ++ daemonSplit.longLived);
  userReExec = lib.subtractLists allLongLived userSplit.reExec;
  daemonReExec = lib.subtractLists allLongLived daemonSplit.reExec;

  # WRITABILITY, not authorship, picks the tick — see the header. Every path a
  # daemon declares in EITHER bucket is root's to truncate, so it goes to the
  # root tick even when only a user agent classified it long-lived.
  daemonDeclared = lib.unique (daemonSplit.reExec ++ daemonSplit.longLived);
  daemonLongLived = lib.filter (p: lib.elem p daemonDeclared) allLongLived;
  userLongLived = lib.subtractLists daemonDeclared allLongLived;

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
  # reason.)
  #
  # `binName` is separate from `name` because the two ticks sit in different
  # layers. The ROOT tick is a hand-written nix-darwin daemon, so it must spell
  # the `nix-` arg0 out itself (.claude/rules/launchd-naming.md item 2). The USER
  # tick is a home-manager agent, and launchd-launcher.nix already forces
  # `launcher.name = "nix-<attr>"` — naming the inner script `nix-…` as well maps
  # one name to two store paths, which is why metube ships `metube-run`.
  mkTick =
    {
      name,
      binName,
      paths,
      stateFile,
    }:
    pkgs.writeShellApplication {
      name = binName;
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
    binName = "file-rotation-logs-run";
    paths = userLongLived;
    stateFile = "${home}/.local/state/logrotate/agents.state";
  };
  daemonTick = mkTick {
    name = "file-rotation-logs-system";
    binName = "nix-file-rotation-logs-system";
    paths = daemonLongLived;
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
    userLongLivedPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = userLongLived;
      description = "The long-lived paths the login-user logrotate tick truncates.";
    };
    daemonLongLivedPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = daemonLongLived;
      description = "The long-lived paths the root logrotate tick truncates.";
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
    # no special-casing — the classification sees it like any other agent, which
    # is also why declaring it into `hmAgents` (read at the top of this file) is
    # not a cycle: the split reads only KeepAlive and the two path keys, never
    # ProgramArguments.
    home-manager.users.${loginName}.launchd.agents.file-rotation-logs = {
      enable = true;
      config = {
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
