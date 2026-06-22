# Unified user profile — loaded on EVERY machine (macOS, Ubuntu, Pi, container).
# This is the single home of "user logic". Nothing platform-specific belongs here;
# platform branches live in modules/linux and modules/darwin.
{
  pkgs,
  lib,
  config,
  secretsDir ? null,
  ...
}:
let
  managedSecrets = {
    "github-token" = "GH_TOKEN";
    "hf-token" = "HF_TOKEN";
    "claude-code-oauth-token" = "CLAUDE_CODE_OAUTH_TOKEN";
    "aws-bearer-token-bedrock" = "AWS_BEARER_TOKEN_BEDROCK";
    "dockerhub-username" = "DOCKERHUB_USERNAME";
    "dockerhub-token" = "DOCKERHUB_TOKEN";
    "cloudflare-api-token" = "CLOUDFLARE_API_TOKEN";
    "civitai-api-token" = "CIVITAI_API_TOKEN";
    "runpod-api-key" = "RUNPOD_API_KEY";
    "vast-api-key" = "VAST_API_KEY";
    "litellm-proxy-api-base" = "LITELLM_PROXY_API_BASE";
    "litellm-proxy-api-key" = "LITELLM_PROXY_API_KEY";
    "gitlab-token" = "GITLAB_TOKEN";
  };

  secretAliases = {
    "ANTHROPIC_BASE_URL" = "LITELLM_PROXY_API_BASE";
    "OPENAI_BASE_URL" = "LITELLM_PROXY_API_BASE";
    "ANTHROPIC_API_KEY" = "LITELLM_PROXY_API_KEY";
    "OPENAI_API_KEY" = "LITELLM_PROXY_API_KEY";
    "GITHUB_TOKEN" = "GH_TOKEN";
    "GLAB_TOKEN" = "GITLAB_TOKEN";
    "CF_API_TOKEN" = "CLOUDFLARE_API_TOKEN";
    "HUGGING_FACE_HUB_TOKEN" = "HF_TOKEN";
  };

  activeSecrets = lib.filterAttrs (
    name: _: secretsDir != null && builtins.pathExists "${secretsDir}/${name}.age"
  ) managedSecrets;

  hasSecrets = activeSecrets != { };
in

{
  imports = [ ../linux/nix-ld.nix ];

  # Baseline toolset present on all hosts. git / tmux / neovim / ripgrep are
  # NOT listed here — each is installed by its `programs.*` module below, and
  # listing it twice collides on /bin/<tool> in the Home Manager buildEnv.
  # curl is omitted — covered by system packages on all hosts (nixos/core.nix,
  # darwin/core.nix); including it here would add a redundant user-profile copy.
  home.packages = with pkgs; [
    fd
    jq
  ];

  # ---- Home Manager program modules --------------------------------------------
  programs = {
    # Let Home Manager manage itself.
    home-manager.enable = true;

    git = {
      enable = true;
      settings = {
        user.name = lib.mkDefault "Ismail Kattakath";
        user.email = lib.mkDefault "ismail@kattakath.com";
        init.defaultBranch = "main";
        pull.rebase = true;
        commit.gpgsign = true;
        gpg.format = "ssh";
        user.signingkey = "~/.ssh/id_ed25519.pub";
      };
    };

    neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      withRuby = false;
      withPython3 = false;
    };

    tmux = {
      enable = true;
      baseIndex = 1;
      keyMode = "vi";
      terminal = "tmux-256color";
    };

    ripgrep.enable = true;

    ssh = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      matchBlocks = {
        # Reach the NixOS hosts over their Cloudflare Tunnel: ssh routes through
        # `cloudflared access ssh` (no public port; the tunnel forwards to localhost:22).
        "nixbox.kattakath.com" = {
          user = config.home.username;
          identityFile = "~/.ssh/id_ed25519";
          proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
        };
        "nixrpi.kattakath.com" = {
          user = config.home.username;
          identityFile = "~/.ssh/id_ed25519";
          proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
        };
      };
    };

    # A login shell is required for `home-manager switch` to wire session vars.
    bash = {
      enable = true;
      initExtra = lib.mkIf hasSecrets (
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: envVar: ''
            if [ -f "${config.age.secrets.${name}.path}" ]; then
              export ${envVar}=$(< "${config.age.secrets.${name}.path}")
            fi
          '') activeSecrets
          ++ lib.mapAttrsToList (alias: source: ''
            export ${alias}="''${${source}}"
          '') secretAliases
        )
      );
    };
  };

  age = lib.mkIf hasSecrets {
    identityPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519" ];
    secrets = lib.mapAttrs (name: _: { file = "${secretsDir}/${name}.age"; }) activeSecrets;
  };
}
