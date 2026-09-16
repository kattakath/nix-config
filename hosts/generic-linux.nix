# A NixOS host that carries NOTHING personal — the `mkNixos` twin of
# hosts/generic-darwin.nix.
#
# WHY THIS EXISTS. `mkNixos` resolves its host profile from a string
# (`hosts/<hostname>.nix`), so until 2026-09-16 a consumer of the published
# `lib.mkNixos` had no way to decline the operator's host. Measured that day:
# `mkNixos { hostname = "nixvm"; }` evaluated, for a caller with no connection to
# this fleet, to `users.users.ismail` present — holding the OPERATOR'S
# ssh-ed25519 public key as its sole authorized key, in `wheel`, and with
# `loginName` in `nix.settings.trusted-users`. That is a login account plus a
# root-equivalent grant on a stranger's server.
#
# It is the identical failure `hosts/generic-darwin.nix` was created for the day
# before (c4a522a); only the darwin builder was hardened then.
#
# WHAT IT DELIBERATELY DOES NOT DO. No hostName, no users beyond what
# `modules/nixos/core.nix` declares, no SSH key (mkNixos now defaults
# `operatorSshKey` to null — the fleet's own hosts pass it explicitly at the
# call site), no hosted sites, no hardware. A consumer's own `extraModules` is
# where their machine gets described.
#
# NOTE ON hostName. Left unset on purpose — NixOS defaults it, and the consumer
# should set it in their own module. Setting a name here would rename every
# consumer's machine to the same thing.
#
# NOTE ON stateVersion. Also left unset, and this one is LOUD rather than
# silent: NixOS warns if `system.stateVersion` is undefined, which is the
# correct outcome. It encodes when a machine was first installed and only its
# owner knows that; a value inherited from this file would be a lie about their
# host, and picking one for them is how data-migration defaults silently point
# at the wrong release.
{
  # Deliberately empty. `modules/nixos/core.nix`, the Cachix substituter and the
  # Home Manager profile are already in mkNixos's base module list, so a generic
  # host needs to add nothing — unlike the darwin side, where the host profile is
  # what opts a Mac into the system layer at all.
}
