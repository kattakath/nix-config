# Eval check, carried over from the satellite flake's own `checks.module-evaluates`:
# the module produces the expected boot oneshot with the right ordering + mount
# relationship (it builds a tiny derivation only if every assertion holds).
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
#
# IT USED TO ASSERT `unitConfig.RequiresMountsFor == "/boot/firmware"`, i.e. it
# PINNED THE DEFECT. Requires= on the mount made an unreadable FAT partition a
# dependency failure, which no Restart= can retry, and a consumer's requiredBy then
# made that permanent — on nixpi, a permanent loss of the only route in. So the
# assertion is inverted: the mount must be WANTED and ORDERED, and
# `RequiresMountsFor` must be ABSENT. A test that pins the broken behaviour is worse
# than no test, because it makes the fix look like the regression.
{
  nixpkgs,
  pkgs,
  system,
  module,
}:
let
  mkSys =
    extra:
    nixpkgs.lib.nixosSystem {
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
          local.firmwareProvisioning = {
            docsHint = "See RUNBOOK.md.";
          }
          // extra;
        })
      ];
    };

  # (a) the default shape: no cache opted in.
  plain = mkSys {
    files.demo-token = {
      source = "demo-token";
      target = "/run/demo-token";
      required = true;
      before = [ "demo.service" ];
      requiredBy = [ "demo.service" ];
    };
  };
  unit = plain.config.systemd.services."firmware-file-demo-token";

  # (b) the same file with the cache opted in — the branch that keeps a remote-only
  # host reachable when the firmware partition stops mounting.
  cached = mkSys {
    files.demo-token = {
      source = "demo-token";
      target = "/run/demo-token";
      required = true;
      cache = true;
      before = [ "demo.service" ];
      requiredBy = [ "demo.service" ];
    };
  };
  cachedUnit = cached.config.systemd.services."firmware-file-demo-token";

  has = needle: hay: pkgs.lib.hasInfix needle hay;
  yesno = b: if b then "yes" else "no";
in
pkgs.runCommand "firmware-provisioning-eval" { } ''
  test "${unit.serviceConfig.Type}" = "oneshot"
  test "${pkgs.lib.elemAt unit.before 0}" = "demo.service"

  # The mount is ORDERED and WANTED, never REQUIRED. Both halves are asserted, so
  # dropping the ordering is as much a failure as restoring the veto.
  test "${pkgs.lib.elemAt unit.after 0}" = "boot-firmware.mount"
  test "${pkgs.lib.elemAt unit.wants 0}" = "boot-firmware.mount"
  test "${yesno (unit.unitConfig ? RequiresMountsFor)}" = "no"

  # cache = false (the default) must add no cache branch and no second copy of the
  # secret on disk — the opt-in has to actually be an opt-in.
  test "${yesno (has "cache=" unit.script)}" = "no"

  # cache = true renders all three halves: the fallback read, the refresh-on-success
  # (so a ROTATED plant is not shadowed by a stale copy), and the 0400 mode.
  test "${yesno (has "cache=/var/lib/firmware-secrets/demo-token" cachedUnit.script)}" = "yes"
  test "${yesno (has "elif [ -f \"\$cache\" ]" cachedUnit.script)}" = "yes"
  test "${yesno (has "install -D -m0400" cachedUnit.script)}" = "yes"

  # …and the directory it writes into is declared root-only, not left to umask.
  test "${
    yesno (
      pkgs.lib.any (
        r: has "/var/lib/firmware-secrets 0700 root root" r
      ) cached.config.systemd.tmpfiles.rules
    )
  }" = "yes"

  echo ok > "$out"
''
