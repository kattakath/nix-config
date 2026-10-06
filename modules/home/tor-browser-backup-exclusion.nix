# Keep the Tor Browser profile out of Time Machine.
#
# ---- upstream-first: NO OPTION EXISTS, and I grepped both inputs -------------
# grepped nix-darwin/modules AND home-manager/modules for
#   tmutil | TimeMachine | time-machine | SkipPaths | ExcludeByPath | addexclusion
# — ZERO hits in either, and nothing under nix-darwin's
# modules/system/defaults/ models backups → custom, because neither input
# models Time Machine exclusions at all. Apple's own `tmutil` is the mechanism;
# this is not a setting either module could have owned.
#
# no community tool owns this (searched: the above terms plus the fleet's own
# modules/home, hosts and modules/darwin trees — `grep -rn tmutil` is empty).
# `tmutil` IS the off-the-shelf tool; this module only calls it.
#
# ---- WHY, AND IT IS PRE-EMPTIVE. NOTHING WAS LEAKING. -----------------------
# Measured on this Mac, 2026-10-06, before the change:
#   /usr/bin/tmutil destinationinfo  →  "tmutil: No destinations configured."
#   /usr/bin/tmutil isexcluded <profile>  →  "[Included]"
# So there is no Time Machine destination today and nothing has ever been backed
# up. A future reader should not think this fixed a live leak — it did not.
#
# It is still worth doing: attaching a TM destination later is a one-click action
# in System Settings that nobody would re-audit this path for, and by then the
# profile — browsing history, bookmarks, Tor consensus/state — would be captured
# on the very first backup. Excluding it now costs nothing and is irreversible in
# the useful direction.
#
# ---- WHAT THIS DOES *NOT* COVER. Do not over-trust it. ----------------------
# Two other traces were measured on 2026-10-06 and the operator DECLINED fixing
# them that day — a decision, not an oversight:
#   * `~/Downloads` is CONTENT-indexed by Spotlight — `mdfind` returned a match
#     from INSIDE a file, not just a filename. A Spotlight exclusion was offered
#     and declined, as was moving the download directory.
#   * The unified log recorded the app launch at millisecond precision, with
#     roughly 23.5 h of retention. Nothing here touches that.
# So this module narrows ONE channel (backups) and leaves those two open.
#
# ---- MECHANICS ---------------------------------------------------------------
# `tmutil addexclusion` on a PATH sets a sticky xattr and needs NO privilege —
# verified on a throwaway directory: add exited 0, the path then reported
# "[Excluded]", and removeexclusion exited 0, all as the login user. There is
# deliberately no sudo here; if a future macOS requires elevation this should
# start FAILING VISIBLY rather than silently acquiring privilege.
#
# `/usr/bin/tmutil` by ABSOLUTE PATH. Bare binary names are a measured hazard on
# this machine — Nix's coreutils shadow the BSD ones on PATH, which is how
# `stat -f` silently returned filesystem instead of file info once.
#
# Idempotent and NON-FATAL by construction: re-excluding an excluded path is a
# no-op, and the profile directory does not exist until Tor Browser has been run
# once, so a missing directory logs and skips. Activation must never break
# because a browser has not been launched yet.
{
  config,
  lib,
  osConfig ? { },
  ...
}:
let
  # HOST SCOPE: `macos` only. `tmutil` exists on no Linux host, and the path is
  # macOS-shaped, so this must not reach nixpi or nixvm. Same `osConfig`
  # hostName gate as modules/home/{default,macos-user-agents,spotlight-actions}.nix
  # (CLAUDE.md § Configuration: per-host divergence is a gate, not a fork).
  # A Tart darwin GUEST is also excluded — its hostName is not `macos`.
  # `osConfig ? { }` with the `or ""` fallback matches those siblings — this
  # module must still evaluate where there is no darwin/NixOS parent (the
  # standalone-HM path in checks), and an unknown host simply gets nothing.
  isMacosHost = (osConfig.networking.hostName or "") == "macos";

  # Built from config.home.homeDirectory, never a /Users/<name> literal in a Nix
  # value (ast-grep nix-hardcoded-home-path enforces this).
  profileDir = "${config.home.homeDirectory}/Library/Application Support/TorBrowser-Data";
in
{
  home.activation = lib.mkIf isMacosHost {
    torBrowserBackupExclusion = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      dir=${lib.escapeShellArg profileDir}
      if [ -d "$dir" ]; then
        /usr/bin/tmutil addexclusion "$dir" \
          && echo "tor-browser: excluded from Time Machine → $dir" >&2 \
          || echo "tor-browser: tmutil addexclusion FAILED for $dir (not fatal)" >&2
      else
        echo "tor-browser: profile absent — nothing to exclude yet ($dir)" >&2
      fi
    '';
  };
}
