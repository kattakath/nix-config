# ---- CAPSULE: cloud-cli (ADR-004 phase 3) -------------------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Born in-tree (no satellite
# provenance): the worked example of ADR-003's "content out, governance in" applied
# to a cloud CLI — the flake ships the TOOL and the SHAPE of its config
# (`~/.aws/config.example`, placeholders only); the CONTENT (account ids, roles,
# regions) is written by the human, locally, outside Nix and git.
#
# Home-manager class, so it rides the RAW seam (`capsuleModules`), not
# `flake.modules` — modules/parts/capsules.nix § The RAW module seam records why
# (deferredModule's wrapper reorders `home.packages`).
{ inputs, ... }:
{
  capsules = [ "cloud-cli" ];

  capsuleModules.homeManager.cloud-cli = ./module.nix;

  perSystem =
    { pkgs, ... }:
    let
      checks = import ./checks/module-evaluations.nix {
        inherit (inputs) home-manager;
        inherit pkgs;
        module = ./module.nix;
      };
    in
    {
      # Both systems: awscli2 and aws-sso-util are Linux-clean, and the Pi/VM
      # profiles must be able to enable this too.
      checks = {
        cloud-cli-module = checks.module-evaluates;
        cloud-cli-inert = checks.inert;
      };
    };
}
