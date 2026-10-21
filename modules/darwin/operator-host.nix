# local.operatorHost — "this is the operator's own Mac", as a FLAG rather than a
# hostname string.
#
# WHY NOT `networking.hostName == "macos"`: the template's own attribute is
# `darwinConfigurations.macos`, and hosts/generic-darwin.nix tells a consumer to set
# `hostName` so a bare `darwin-rebuild` can find it. A stranger who names their Mac
# "macos" is following the instructions — and the hostname test switched every
# operator-only gate ON for them, including the activation that fetches the
# operator's résumé gist. Set ONLY in hosts/macos.nix, which the template never
# imports, this cannot be reached from a consumer's flake by naming.
# `checks.<system>.template-consumer` builds a consumer named "macos" to prove it.
#
# upstream-first: grepped the pinned nix-darwin modules/ for an owner/operator
# flag — none exists; `system.primaryUser` is the consumer's OWN login, not ours.
{ lib, ... }:
{
  options.local.operatorHost = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      True only on the operator's own Mac (set in hosts/macos.nix). Read by
      modules/_lib/is-macos-host.nix, the one predicate every operator-only
      Home Manager gate uses.
    '';
  };
}
