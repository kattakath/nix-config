# The fleet's ONE Nix store retention policy — every host reads it from here.
#
# Consumers: modules/nixos/core.nix (`programs.nh.clean`, every NixOS host) and
# modules/darwin/store-clean.nix (a root launchd daemon, because nix-darwin's own
# `programs.nh.clean` asserts `nix.enable`, which Determinate forces off). Change
# the numbers here and both platforms follow; never restate them in a consumer.
#
# `nh clean all --keep N --keep-since D` (nh 4.4.2 `--help`): BOTH are floors —
# "at least keep this number of generations" and "at least keep gcroots and
# generations in this time range since now". So a busy day keeps MORE than
# `keep`; nothing older than `keepSince` survives past the `keep` newest. The
# same window also prunes stale gcroots (old `result` links, nix-direnv roots of
# worktrees untouched for `keepSince`): measured 2026-11-27 dry run on macos,
# 92 of 239 roots would go — nix-direnv roots of worktrees idle past the
# window, plus a stray `result` link. The live checkouts' roots were kept.
#
# Decided 2026-11-27 by the operator: 3 generations is enough rollback, and GC
# need not wait 7 days — 3 is the window. Rationale and the rejected options:
# docs/nix-implementation-adr.md (ADR-017) § Store retention.
{
  keep = 3;
  keepSince = "3d";

  # Daily, so a 3-day window means ~3 days. A weekly timer would let a path
  # live up to 3 + 7 = 10 days, which is what made the old `--delete-older-than
  # 30d` weekly timer free 0 KiB for the whole first month after nixpi's reflash.
  # systemd calendar spec (NixOS) and launchd StartCalendarInterval (darwin).
  systemdCalendar = "daily";
  launchdCalendar = {
    Hour = 3;
    Minute = 15;
  };

  # The build-time floor, Nix's own primitive (nix.conf `min-free`/`max-free`):
  # when free store space drops below `minFree` DURING A BUILD, the daemon GCs
  # until `maxFree` is free. It stays on beside the timer: the timer bounds what
  # is RETAINED, this bounds a single large build from hitting ENOSPC.
  minFree = 3 * 1024 * 1024 * 1024; # 3 GiB
  maxFree = 10 * 1024 * 1024 * 1024; # 10 GiB
}
