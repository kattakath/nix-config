# Eval check, carried over VERBATIM from the satellite flake's own
# `checks.module-evaluates`: the module produces a hardened unit that reads the
# token from an EnvironmentFile (never argv) and honours extraArgs.
#
# `module` is an ARGUMENT, not `../module.nix`. A capsule is entered through its
# flake-module.nix and reached downward from there; a leaf that imports upward
# would break the invariant the ast-grep rule enforces (see the header of
# ../flake-module.nix).
{
  nixpkgs,
  pkgs,
  system,
  module,
}:
let
  inherit (nixpkgs) lib;

  sys = lib.nixosSystem {
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
        services.cloudflared-connector = {
          enable = true;
          tokenFile = "/run/cloudflared-token";
          extraArgs = [
            "--loglevel"
            "debug"
          ];
        };
      })
    ];
  };
  unit = sys.config.systemd.services.cloudflared-connector.serviceConfig;
in
pkgs.runCommand "cloudflared-connector-eval" { } ''
  test "${unit.EnvironmentFile}" = "/run/cloudflared-token"
  test "${lib.boolToString (unit.NoNewPrivileges && unit.MemoryDenyWriteExecute)}" = "true"
  case "${unit.ExecStart}" in
    *"tunnel run --loglevel debug") : ;;
    *) echo "unexpected ExecStart: ${unit.ExecStart}" >&2; exit 1 ;;
  esac
  echo ok > "$out"
''
