# ---- Keep the PUBLIC output surface exactly what it was ---------------------
#
# flake-parts' core modules DECLARE `flake.legacyPackages`, `flake.nixosModules`
# and `flake.overlays` with `default = { }` (pinned flake-parts
# modules/legacyPackages.nix, modules/nixosModules.nix, modules/overlays.nix),
# and `legacyPackages` is additionally TRANSPOSED over every entry of `systems`
# (modules/transposition.nix:100-110). An option with a default is still a
# defined attribute, so a bare `mkFlake` emits all three — measured, not
# assumed: a throwaway flake-parts flake with one package produced
#
#   legacyPackages.{aarch64-darwin,aarch64-linux}   nixosModules{}   overlays{}
#
# in `nix flake show --json`, none of which this flake has ever exported.
#
# Wave 2's acceptance test is an EMPTY `nix flake show` diff, and adopting a
# framework is not a licence to grow the public surface by three attributes
# nobody asked for. `legacyPackages` in particular is not cosmetic: `nix flake
# show` marks it `isLegacy` and downstream tooling treats a flake that has one
# differently from a flake that does not (flake-parts' own transposition.nix:52
# has a special-case hint for exactly that confusion).
#
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.touchup` exists → using it.
# It is upstream's own answer to this, cited in flake-parts' source at
# modules/formatter.nix:88-98 ("To change the `formatter` output attribute, you
# can control it precisely with the `touchup` module"), and it works by
# replacing `processedFlake` (modules/flake.nix:40-57) rather than by
# post-processing the result. Deleting an attribute is one line each; the
# values of everything kept are passed through unchanged
# (extras/touchup/attrs.nix:122-128, `finish` defaults to the identity).
#
# TO RE-ENABLE ONE: delete its line. The day this flake genuinely exports an
# overlay or a nixosModule, that is the edit — a deliberate one, in a file whose
# only job is saying what the flake exports.
#
# ---- `modules` is a FOURTH suppression, and a different kind ----------------
#
# The three above are framework noise: flake-parts declares them empty and this
# flake never had them. `flake.modules` is not empty — ADR-002 wave 3 made it the
# capsule registry (modules/parts/capsules.nix), and today it really does carry
# `nixos.cloudflared-connector`. Suppressing it is therefore a DECISION, the one
# ADR-002 §7.3 says must not happen as a side effect:
#
#   github:kattakath/nix-cloudflared-connector published
#   `nixosModules.cloudflared-connector` to strangers. Absorbed, its only
#   consumer is hosts/nixpi.nix, reached through `config.flake.modules` INSIDE
#   this flake — which touchup does not touch. Re-exporting it would add a public
#   output with no consumer, and ADR-002 §7 is explicit that carrying a seam
#   nothing consumes is itself a cost. Across all seven satellites there were 2
#   stars and 0 forks, so there is no downstream to strand.
#
# TO RE-PUBLISH: delete the `modules` line below and the whole registry becomes
# a flake output again — or, to publish exactly one capsule and no more,
# `touchup.attr.modules.any.attr.<name>.enable` (extras/touchup.nix's own
# documented "hide a package from users, but not from your own modules" shape).
{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.touchup ];

  touchup.attr = {
    legacyPackages.enable = false;
    nixosModules.enable = false;
    overlays.enable = false;
    modules.enable = false;
  };
}
