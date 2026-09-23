# Rotation for the fleet's launchd agent logs, via nix-darwin's own newsyslog module.
#
#   upstream option system.newsyslog.{enable,files} exists -> using it
#   (pinned nix-darwin modules/system/newsyslog.nix:11-160, registered at
#   modules/module-list.nix:45). It was never used by this fleet, which is how
#   ~/Library/Logs reached 231 MB by 2026-09-22.
#
# WHY ONLY SOME LOGS — this is the whole design, and it is not a scoping whim.
# launchd opens StandardOutPath ONCE at spawn and hands the fd to the child.
# macOS newsyslog does rename+create and has NO copytruncate (man 5
# newsyslog.conf: the flags are B C D G J N U Z only). So for a LONG-LIVED
# KeepAlive agent, rotation renames the file out from under a process that keeps
# writing to the same inode — the archive grows, the fresh file stays empty, and
# not one byte is reclaimed. Verified with lsof: mcp-tunnel-connector (pid 832)
# and mcp-gateway (pid 61665) each hold fd 1u AND 2u directly on their log.
#
# So this module covers ONLY agents that re-exec — one-shot, interval, or
# queue-driven. Those genuinely re-open the path on their next spawn, which is
# exactly what rename+create needs. The long-lived set (mcp-gateway,
# mcp-tunnel-connector, colima-default, postgres-pgvector, claude-otel-collector,
# metube, yt-dlp-web-ui, the tart/gitlab runners) is deliberately absent: rotating
# them needs a pid file plus `signal`, which needs the launcher wrapper to write
# one first. Separate change; do not "complete" this list without it.
#
# PATHS ARE DERIVED, NOT TYPED. Two traps a hand-written list walks straight into:
#   (a) claude-desktop-mcp-sync declares StandardErrorPath and NO StandardOutPath,
#       so enumerating one key silently misses the file.
#   (b) media-queue and media-queue-power declare the SAME path (4 declarations,
#       one file), so a per-agent list double-covers it. newsyslog keys on the
#       PATH, so the set must be deduped.
# Reading both keys off the composed agents and uniq-ing makes both structural.
# What stays hand-picked is the only part that needs judgement: WHICH agents
# re-exec.
{
  config,
  lib,
  loginName,
  ...
}:
let
  hmAgents = config.home-manager.users.${loginName}.launchd.agents or { };
  darwinAgents = config.launchd.user.agents or { };

  # Home Manager agents that re-exec. Attr names, not paths — see the header.
  shortLivedHm = [
    "media-queue" # QueueDirectories worker; re-execs per batch
    "media-queue-power" # StartInterval tick
    "next-right-thing" # StartInterval tick
    "ollama-local-pull" # RunAtLoad one-shot, now KeepAlive-retried
    "ssh-keychain-load" # RunAtLoad one-shot
    "claude-desktop-mcp-sync" # RunAtLoad one-shot (stderr only — trap (a))
  ];

  # nix-darwin user agents that re-exec: the two hourly Trash sweeps.
  shortLivedDarwin = lib.filter (lib.hasPrefix "file-rotation-") (lib.attrNames darwinAgents);

  pathsOf =
    attrs: names: keyPath:
    lib.concatMap (
      name:
      let
        cfg = lib.attrByPath keyPath { } (attrs.${name} or { });
      in
      lib.filter (p: p != null && p != "") [
        (cfg.StandardOutPath or null)
        (cfg.StandardErrorPath or null)
      ]
    ) (lib.filter (n: attrs ? ${n}) names);

  logPaths = lib.unique (
    pathsOf hmAgents shortLivedHm [ "config" ]
    ++ pathsOf darwinAgents shortLivedDarwin [ "serviceConfig" ]
  );

  entry = path: {
    logfilename = path;
    owner = loginName;
    group = "staff";
    mode = "644";
    count = 3;
    # newsyslog.conf(5) sizes are in KILOBYTES: 1024 = 1 MB, so each log costs at
    # most ~4 MB on disk (current + 3 gzipped rotations). Size-triggered only —
    # `when` is left unset, because these are small and bursty, not daily.
    size = "1024";
    # N: nothing to signal (see the header — these re-exec on their own).
    # Z: gzip the rotations.
    flags = [
      "N"
      "Z"
    ];
  };
in
{
  config = lib.mkIf (config.networking.hostName == "macos") {
    system.newsyslog = {
      enable = true;
      files.nix-fleet = map entry logPaths;
    };
  };
}
