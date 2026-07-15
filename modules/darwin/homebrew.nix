# Declarative Homebrew taps/brews/casks for the Mac (sourced from ~/Brewfile).
# nix-homebrew (./nix-homebrew.nix) installs brew itself; this module only
# declares its contents.
#
# What is DELIBERATELY NOT here (nixpkgs/Home Manager is the single source, and
# a duplicate on PATH causes buildEnv collisions): aws-cdk, awscli, make, node
# (unversioned), uv, gh, git-lfs, the claude-code cask, and 6 font casks — see
# modules/shared/home.nix. direnv was dropped from the repo entirely; reintroduce
# deliberately if a devShell ever needs it.
#
# The brew/cask/tap lists below are the full lean set — anything not listed
# is uninstalled on activation (onActivation.cleanup = "uninstall").
_:

{
  homebrew = {
    enable = true;

    # Lean activation: cleanup = "uninstall" removes any installed brew/cask/tap
    # not declared below (but never touches the App Store apps `zap` would also
    # wipe app data for — "uninstall" is the safer of the two enforcing modes).
    # autoUpdate/upgrade stay off so a rebuild never silently bumps versions.
    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "uninstall";
    };

    # ---- Taps --------------------------------------------------------------
    # No third-party taps. escrcpy (viarotel-org/escrcpy) was removed — its cask
    # emitted a deprecated `depends_on macos:` warning on every activation.
    # nats-server is homebrew-core, so no tap is needed.
    taps = [ ];

    # ---- Formulae (brews) --------------------------------------------------
    # See header for what was removed and what is intentionally kept. Entries
    # with special options use the attrset form.
    brews = [
      "age"
      "aws-vault"
      "btop"
      "bruno-cli"
      "cloudflared"
      "cmake"
      "devcontainer"
      "docker"
      "docker-buildx"
      "docker-compose"
      "duf"
      "ffmpeg"
      "gettext"
      "git"
      "git-filter-repo"
      "glab"
      "go"
      "graphviz"
      # link = false → don't symlink into the brew prefix.
      {
        name = "hf";
        link = false;
      }
      "imagemagick"
      "img2pdf"
      "kubernetes-cli"
      "nats-server"
      "ncdu"
      "ocrmypdf"
      "poppler"
      "pyenv"
      "scrcpy"
      "shellcheck"
      "starship"
      "switchaudio-osx"
      "tree"
      "wget"
      "xcodes"
      "yq"
      "yt-dlp"
      "zstd"
    ];

    # ---- Casks -------------------------------------------------------------
    # The "claude" cask is the Claude DESKTOP app (the claude-code CLI cask was
    # dropped for nixpkgs — see header). Font casks moved to nixpkgs too.
    casks = [
      "android-platform-tools"
      "applite"
      "blackhole-2ch"
      "brave-browser"
      "bruno"
      "camo-studio"
      "claude"
      "cursor"
      "docker-desktop"
      "gcloud-cli"
      "google-chrome"
      "inkscape"
      "lm-studio"
      "maccy"
      "microsoft-auto-update"
      "microsoft-teams"
      "obs"
      "obsidian"
      "proton-drive"
      "raspberry-pi-imager"
      "slack"
      "telegram"
      "utm"
      "visual-studio-code"
      "whatsapp"
      "zoom"
    ];

    # ---- Mac App Store apps (masApps) --------------------------------------
    # Empty: Xcode now comes via the `xcodes` brew above (no `mas`/App-Store
    # sign-in needed); Plash was dropped entirely.
    masApps = { };
  };
}
