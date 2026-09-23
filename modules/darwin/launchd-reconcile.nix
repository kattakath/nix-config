# A nix-darwin system daemon that has left its launchd domain comes back — at the
# next activation AND at the next boot.
#
# WHY THIS EXISTS — measured, twice, on this machine.
# nix-darwin's launchd activation is diff-gated: modules/system/launchd.nix:19
# wraps the whole unload/copy/load body in `if ! diff <old> <new>`. An unchanged
# plist therefore means the body never runs, so a daemon that is no longer in the
# domain is NEVER re-bootstrapped. Home Manager does not have this hole — it
# probes with `launchctl print` and re-bootstraps (pinned home-manager
# modules/launchd/default.nix:411-419) — which is exactly why 22 user agents
# stayed healthy through the outage below while the system tier did not.
#
# 2026-09-22: activate-agenix and both github-runner daemons sat outside the
# system domain for ~21h. /run is wiped at boot and on darwin agenix repopulates
# /run/agenix ONLY from launchd.daemons.activate-agenix (pinned agenix
# modules/age.nix:339-354; its activationScripts path at :303 is Linux-only), so
# all three host-decrypted secrets were gone and five CI lanes with them. The
# preserved launchd ring (/var/log/com.apple.xpc.launchd/launchd.log) holds 24k
# org.nix lines across four activations that day and, for those three labels,
# exactly one kind of event: `Could not find job with label …`. Never a spawn.
# `launchctl load`'s exit code is documented as meaningless, so every one of
# those activations reported success. ollama-daemon.nix:212 records the same
# class costing 10h52m an earlier time. This is upstream nix-darwin #1199.
#
# WHY BOTH HOOKS, not one.
#   postActivation  — covers `darwin-rebuild switch`. It is deliberately NOT
#                     activationScripts.launchd (upstream's own openssh.nix:115
#                     phase): activation-scripts.nix:128-140 orders
#                     launchd → userLaunchd → … → postActivation, and reconciling
#                     after both plist phases means we never race a plist that
#                     the same run is still writing.
#   activate-system — covers boot. The boot daemon runs ONLY checks, etc and
#                     keyboard (modules/services/activate-system/default.nix:68-70),
#                     so a postActivation-only fix leaves the next reboot broken.
#                     `script` is types.lines (modules/launchd/default.nix:53-56),
#                     so mkAfter merges into upstream's own RunAtLoad daemon
#                     instead of adding one of ours — and that daemon's arg0 is
#                     already the sanctioned `/bin/sh -c wait4path` shape, so the
#                     boot half is mount-protected for free.
#
# NOT A SUPERVISOR. Two launchctl verbs in an idempotent probe, reusing the
# `enable` + `bootstrap` idiom nix-darwin already ships in
# modules/services/openssh.nix:115-116, with Home Manager's `launchctl print`
# probe as the liveness test. No new daemon, no new option, no polling.
#
# Deliberately NOT `launchctl kickstart`: that only restarts a job ALREADY in the
# domain (the shape karabiner-elements/default.nix:44 uses). It cannot bootstrap
# an absent one, which is the entire failure here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # activate-system is excluded: it is the daemon that RUNS the boot half, and it
  # is bootstrapped by launchd itself before any of this can execute.
  reconciled = lib.filter (l: l != "org.nixos.activate-system") (
    lib.mapAttrsToList (_: d: d.serviceConfig.Label) config.launchd.daemons
  );

  # Escape hatch. A deliberate `launchctl bootout` is otherwise undone by the very
  # next activation, which would make debugging a daemon impossible. Absence from
  # the domain and `launchctl disable` are INDEPENDENT states — bootout does not
  # write the disabled DB (verified: all six labels read `=> enabled` while three
  # were absent) — so the disabled DB cannot serve as this signal.
  holdDir = "/etc/nix-darwin/launchd-hold";

  reconcile = pkgs.writeShellScript "nix-launchd-reconcile" ''
    # Every launchctl line is `|| true`: this text is spliced into activate-system's
    # boot script, which runs under `set -e`, and one "already loaded" would abort
    # the etc/keyboard activation that follows it.
    for label in ${lib.escapeShellArgs reconciled}; do
      [ -e ${lib.escapeShellArg holdDir}/"$label" ] && continue
      plist="/Library/LaunchDaemons/$label.plist"
      [ -f "$plist" ] || continue
      if ! /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        echo "launchd-reconcile: $label is not in the system domain — bootstrapping" >&2
        /bin/launchctl enable "system/$label" || true
        /bin/launchctl bootstrap system "$plist" || true
      fi
    done
    exit 0
  '';
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    # SWITCH coverage.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${reconcile}
    '';

    # BOOT coverage — merged into upstream's own RunAtLoad daemon.
    launchd.daemons.activate-system.script = lib.mkAfter ''
      ${reconcile}
    '';
  };
}
