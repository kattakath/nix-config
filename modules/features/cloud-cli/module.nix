# home-manager module: local.cloudCli.aws
#
# SHAPE, NOT CONTENT. This installs the AWS CLI (and SSO helpers) and writes
# `~/.aws/config.example` — placeholders only. It NEVER writes `~/.aws/config`:
# that file is the human's, written by `aws configure sso` (or by copying the
# example and filling it in), lives outside Nix and git, and is what
# modules/shared/claude-bedrock-gate.nix reads at runtime.
#
# WHY the real file may not be declared here, even though it holds no credential:
#   * Account ids, SSO start-URL ids and regions are not secrets, but they ARE
#     reconnaissance — they tell an attacker where to aim. A public repo ships the
#     shape; the values stay on the machine (ADR-004 §7, inventory #1).
#   * Every user's shape differs — an SSO admin, an IAM-less junior, a preview-only
#     senior — so no single committed file could be right for anyone but its author.
#   * Sessions are SSO/OIDC-minted at `aws sso login`, so almost nothing needs
#     long-lived storage anyway; the one long-lived thing (the SSO token cache in
#     ~/.aws/sso/cache) never was in Nix either.
#
# UPSTREAM FIRST (2026-09-20): ✅ upstream option home-manager.programs.awscli exists →
# using it for the package (pinned modules/programs/awscli.nix:17). Its `settings`
# option is deliberately NOT set: with `settings = { }` upstream writes no
# ~/.aws/config (awscli.nix:64 gates the file on `settings != { }`), which is
# exactly the boundary this capsule exists to keep. The example file is a plain
# `home.file` — there is no upstream "write an example" option to reach for.
# `aws-sso-util` is nixpkgs' (aws-sso-util-4.33.0, darwin-clean).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.cloudCli.aws;
in
{
  options.local.cloudCli.aws = {
    enable = lib.mkEnableOption "the AWS CLI + SSO helpers, with a placeholder-only ~/.aws/config.example (never the real file)";

    ssoTooling = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also install aws-sso-util (login/configure helpers for IAM Identity Center).";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.awscli.enable = true; # package only — `settings` stays { }, so no ~/.aws/config
    home.packages = lib.optional cfg.ssoTooling pkgs.aws-sso-util;

    home.file.".aws/config.example".text = ''
      # ~/.aws/config.example — SHAPE ONLY (written by nix-config's cloud-cli capsule).
      # Copy to ~/.aws/config and fill in YOUR values, or let `aws configure sso` write it.
      # ~/.aws/config is yours: not in Nix, not in git, gitignored everywhere.
      #
      # Why an example and not the real file: account ids / start-URL ids / regions are
      # not credentials, but they are reconnaissance; every user's shape differs; and
      # sessions are SSO-minted (`aws sso login`), so nothing here needs long-lived storage.
      #
      # Claude Code's Bedrock route selects a profile at runtime with
      # `secret set AWS_PROFILE <profile>` (modules/shared/claude-bedrock-gate.nix).

      [sso-session <<SESSION_NAME>>]
      sso_start_url = https://<<START_URL_ID>>.awsapps.com/start
      sso_region = <<SSO_REGION>>
      sso_registration_scopes = sso:account:access

      [profile <<PROFILE_NAME>>]
      sso_session = <<SESSION_NAME>>
      sso_account_id = <<ACCOUNT_ID>>
      sso_role_name = <<ROLE_NAME>>
      region = <<REGION>>
      output = json
    '';
  };
}
