# Sync operator-managed AWS CLI config/credentials into ~/.aws.
#
# Privacy: config/credentials contain SSO URLs, account IDs, and (for
# credentials) long-lived keys — never Nix store paths / flake inputs /
# committed sources. This module only `cp`s from a directory you maintain
# outside git at activation time, same shape as wireguard-configs.nix. See
# docs/private-home-modules.md ("WireGuard (and other private *files*)").
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.awsConfig;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
in
{
  options.local.awsConfig = {
    enable = mkEnableOption ''
      Sync AWS CLI config/credentials from an operator-managed source directory
      into ~/.aws. No-ops gracefully if the `aws` CLI isn't installed or the
      source directory hasn't been planted yet.
    '';

    sourceDir = mkOption {
      type = types.str;
      # Default keeps the files next to other local operator state, not in the flake.
      default = "${config.home.homeDirectory}/.local/share/aws-config";
      description = ''
        Directory holding `config` and/or `credentials` files you maintain
        outside git (or only in a private flake/host). Contents are copied to
        ~/.aws at HM activation with mode 600. Never point this at a path
        that Nix would copy into the store.
      '';
    };

    targetDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.aws";
      description = "Destination for synced files (AWS CLI's default config dir).";
    };
  };

  config = mkIf (cfg.enable && pkgs.stdenv.isDarwin) {
    home.activation.awsConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # HM activation runs with a minimal ambient PATH (no ~/.zshrc), so a bare
      # `command -v aws` misses awscli2 even when installed — it lands in
      # nix-darwin's per-user profile, not on this script's inherited PATH.
      if ! PATH="/etc/profiles/per-user/$(/usr/bin/id -un)/bin:$HOME/.nix-profile/bin:$PATH" command -v aws >/dev/null 2>&1; then
        echo "aws-config: aws CLI not installed — skip" >&2
      else
        src=${lib.escapeShellArg cfg.sourceDir}
        dst=${lib.escapeShellArg cfg.targetDir}
        if [ ! -d "$src" ]; then
          echo "aws-config: source missing ($src) — skip (plant config then re-activate)" >&2
        else
          /bin/mkdir -p "$dst"
          /bin/chmod 700 "$dst"
          synced=0
          for name in config credentials; do
            f="$src/$name"
            if [ -f "$f" ]; then
              /bin/cp -f "$f" "$dst/$name"
              /bin/chmod 600 "$dst/$name"
              synced=$((synced + 1))
            fi
          done
          if [ "$synced" -eq 0 ]; then
            echo "aws-config: no config/credentials in $src" >&2
          else
            echo "aws-config: synced $synced file(s) → $dst" >&2
          fi
        fi
      fi
    '';
  };
}
