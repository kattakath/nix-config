# Eval check, carried over VERBATIM from the satellite flake's own
# `checks.module-evaluates`: the module produces the expected boot oneshot with
# the right ordering + mount gate (it builds a tiny derivation only if all three
# assertions hold).
#
# `module` is an ARGUMENT, not `../module.nix`. A capsule is entered through its
# flake-module.nix and reached downward from there; a leaf that imported upward
# would break the invariant ast-grep/rules/capsule-must-not-reach-out.yml
# enforces (see the header of ../flake-module.nix).
#
# `nixpkgs` is likewise an argument rather than `pkgs`: `lib.nixosSystem` lives
# on the FLAKE's nixpkgs.lib, not on `pkgs.lib` (which is the plain stdlib
# without it) — the satellite's own comment said exactly this, and it is the
# reason this file takes both.
{
  nixpkgs,
  pkgs,
  system,
  module,
}:
let
  sys = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      module
      (_: {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/sda1";
          fsType = "ext4";
        };
        system.stateVersion = "24.05";
        services.firmwareProvisioning = {
          docsHint = "See RUNBOOK.md.";
          files.demo-token = {
            source = "demo-token";
            target = "/run/demo-token";
            required = true;
            before = [ "demo.service" ];
            requiredBy = [ "demo.service" ];
          };
        };
      })
    ];
  };
  unit = sys.config.systemd.services."firmware-file-demo-token";
in
pkgs.runCommand "firmware-provisioning-eval" { } ''
  test "${unit.serviceConfig.Type}" = "oneshot"
  test "${unit.unitConfig.RequiresMountsFor}" = "/boot/firmware"
  test "${pkgs.lib.elemAt unit.before 0}" = "demo.service"
  echo ok > "$out"
''
