# Unified user profile — loaded on EVERY machine (macOS, Ubuntu, Pi, container).
# This is the single home of "user logic". Nothing platform-specific belongs here;
# platform branches live in modules/linux and modules/darwin.
{ pkgs, lib, ... }:

{
  # Let Home Manager manage itself.
  programs.home-manager.enable = true;

  # Baseline toolset present on all hosts. git / tmux / neovim / ripgrep are
  # NOT listed here — each is installed by its `programs.*` module below, and
  # listing it twice collides on /bin/<tool> in the Home Manager buildEnv.
  home.packages = with pkgs; [
    fd
    jq
    curl
  ];

  # ---- Dotfiles via Home Manager program modules -------------------------------
  programs.git = {
    enable = true;
    userName = lib.mkDefault "user";
    userEmail = lib.mkDefault "user@example.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };

  programs.tmux = {
    enable = true;
    baseIndex = 1;
    keyMode = "vi";
    terminal = "tmux-256color";
  };

  programs.ripgrep.enable = true;

  # A login shell is required for `home-manager switch` to wire session vars.
  programs.bash.enable = true;
}
