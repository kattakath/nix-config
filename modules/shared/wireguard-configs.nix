# Sync operator-managed WireGuard *.conf into ~/.config/wireguard (no autostart).
#
# Privacy: confs contain private keys and must NEVER be Nix store paths / flake
# inputs / committed sources. This module only `cp`s from a directory you
# maintain outside git at activation time. See docs/private-home-modules.md
# (private flake) and docs/macvm-tart-runbook.md (wireguard section).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wireguardConfigs;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
in
{
  options.local.wireguardConfigs = {
    enable = mkEnableOption ''
      Sync WireGuard interface configs from an operator-managed source directory
      into ~/.config/wireguard. Does not run wg-quick / start tunnels.
    '';

    sourceDir = mkOption {
      type = types.str;
      # Default keeps confs next to other local operator state, not in the flake.
      default = "${config.home.homeDirectory}/.local/share/wireguard-configs";
      description = ''
        Directory of `*.conf` files you maintain outside git (or only in a
        private flake/host). Contents are copied at HM activation with mode 600.
        Never point this at a path that Nix would copy into the store.
      '';
    };

    targetDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.config/wireguard";
      description = "Destination for synced confs (wg-quick compatible).";
    };
  };

  config = mkIf (cfg.enable && pkgs.stdenv.isDarwin) {
    home.activation.wireguardConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      src=${lib.escapeShellArg cfg.sourceDir}
      dst=${lib.escapeShellArg cfg.targetDir}
      /bin/mkdir -p "$dst"
      /bin/chmod 700 "$dst"
      if [ ! -d "$src" ]; then
        echo "wireguard-configs: source missing ($src) — skip (plant confs then re-activate)" >&2
      else
        # Copy only *.conf; never follow into unrelated trees.
        shopt -s nullglob
        confs=( "$src"/*.conf )
        if [ "''${#confs[@]}" -eq 0 ]; then
          echo "wireguard-configs: no *.conf in $src" >&2
        else
          for f in "''${confs[@]}"; do
            base="$(/usr/bin/basename "$f")"
            /bin/cp -f "$f" "$dst/$base"
            /bin/chmod 600 "$dst/$base"
          done
          echo "wireguard-configs: synced ''${#confs[@]} conf(s) → $dst (not started)" >&2
        fi
      fi
    '';
  };
}
