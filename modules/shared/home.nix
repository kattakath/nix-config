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

{
  # Baseline toolset present on all hosts. git / tmux / neovim / ripgrep are
  # NOT listed here — each is installed by its `programs.*` module below, and
  # listing it twice collides on /bin/<tool> in the Home Manager buildEnv.
  home.packages = with pkgs; [
    fd
    jq
    curl
  ];

  # ---- Home Manager program modules --------------------------------------------
  programs = {
    # Let Home Manager manage itself.
    home-manager.enable = true;

    git = {
      enable = true;
      settings = {
        user.name = lib.mkDefault "user";
        user.email = lib.mkDefault "user@example.com";
        init.defaultBranch = "main";
        pull.rebase = true;
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

    # A login shell is required for `home-manager switch` to wire session vars.
    bash = {
      enable = true;
      initExtra = lib.mkIf (secretsDir != null) ''
        _tok="${config.age.secrets.github-token.path}"
        if [ -f "$_tok" ]; then
          _val=$(< "$_tok")
          export GH_TOKEN="$_val"
          unset _val
        fi
        unset _tok
      '';
    };
  };

  age = lib.mkIf (secretsDir != null) {
    identityPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519" ];
    secrets.github-token.file = "${secretsDir}/github-token.age";
  };
}
