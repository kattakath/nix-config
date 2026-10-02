# Every home-manager launchd agent starts through a `nix-<name>` launcher whose
# interpreter lives in the Nix store.
#
# THIS REPLACES A 560-LINE VENDORED FORK. modules/shared/hm-launchd/ used to copy
# home-manager's whole modules/launchd/default.nix just to change one thing: the
# agent's arg0. home-manager 87c391f (2026-09-14) made that expressible upstream,
# so the fork, its `disabledModules` line and the hm-launchd-drift check all
# retire together. This file is the whole replacement.
#
# WHY arg0 MATTERS — measured, not stylistic. macOS attributes a process to its
# arg0 binary for TCC. A /nix/store arg0 can read ~/Downloads; `/bin/sh` is
# refused with EPERM, which is how media-cli's queue agent failed before the fork
# existed. Upstream now documents exactly this on `launcher.shell`: "with /bin/sh
# the attribution follows Apple's shell, with a store-resident shell it follows
# the launcher itself".
#
# It is also what the operator sees in System Settings > Login Items &
# Extensions: `nix-media-queue`, not eight rows all called `sh`.
# .claude/rules/launchd-naming.md is the prose; this is the mechanism, and
# ast-grep/rules/ still gates the arg0 convention independently.
#
# WHY waitForNixStore = false. Upstream's default wraps the command in
# `/bin/sh -c "/bin/wait4path /nix/store && exec …"`, which guards against
# launchd firing before the store is mounted — at the cost of making `sh` the
# arg0, i.e. the exact trade this fleet cannot take. Disabling it is upstream's
# own documented alternative, and the accepted risk is unchanged from the fork:
# an agent that launches before /nix is mounted fails its exec rather than
# waiting. FileVault has not produced that race here.
#
# mkDefault throughout, so any single agent can still opt out.
{ lib, pkgs, ... }:
{
  options.launchd.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config = {
            waitForNixStore = lib.mkDefault false;
            # The fork derived this from the Label minus `org.nix-community.home.`;
            # upstream derives it from the attribute name. Those are the same
            # string whenever the Label is left at its default, which is every
            # agent in this fleet — verified, not assumed.
            launcher.name = lib.mkDefault "nix-${name}";
            # The fork used writeShellScriptBin, whose shebang is runtimeShell.
            # Same interpreter here, so the attribution target does not move.
            launcher.shell = lib.mkDefault pkgs.runtimeShell;
          };
        }
      )
    );
  };
}
