# macOS host config for "macos" (Apple Silicon, aarch64-darwin) — the fleet's
# sole client Mac. NO incoming traffic: no tunnel, no listening services, no
# self-hosted runner. Home Manager and the nix-vscode-extensions overlay are wired
# centrally by mkDarwin in flake.nix — this file only provides host-specific settings.
#
# First activation (after Determinate Nix is installed, before darwin-rebuild is
# on PATH) — a single line straight from the flake (the darwin analog of nixpi's
# `nixos-rebuild switch --flake .#nixpi`; see flake.nix apps.aarch64-darwin.macos):
#   nix run github:kattakath/nix-config#macos
# Thereafter: darwin-rebuild switch --flake .#macos
{ loginName, ... }:
{
  imports = [
    ../modules/darwin/core.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # Stable identity for host-gated modules (login openers, RAG launchd, …).
  networking.hostName = "macos";

  users.users.${loginName} = {
    name = loginName;
    home = "/Users/${loginName}";
  };

  # ---- Homebrew apps for THIS host --------------------------------------------
  # The framework (enable/onActivation/taps) lives in modules/darwin/homebrew.nix;
  # this is macos's app set. onActivation.cleanup = "uninstall" removes anything
  # installed but not listed here. macvm carries its own (leaner) list.
  homebrew = {
    # ---- Formulae (brews) ----------------------------------------------------
    # Entries with special options use the attrset form.
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
      # Mac App Store CLI. Kept for on-demand installs alongside masApps;
      # `mas install` needs an App Store sign-in.
      "mas"
      "nats-server"
      "ncdu"
      "ocrmypdf"
      "poppler"
      "pyenv"
      # scrcpy — mirror/control a PHYSICAL Android phone on the Mac (pulls its own
      # adb; the android-platform-tools cask provides the adb mobile-mcp uses).
      "scrcpy"
      "shellcheck"
      "starship"
      "switchaudio-osx"
      "tree"
      "wget"
      # CLI (wg / wg-quick); GUI is masApps.WireGuard. Both can coexist.
      "wireguard-tools"
      "xcodes"
      "yq"
      "yt-dlp"
      "zstd"
    ];

    # ---- Casks ---------------------------------------------------------------
    # The "claude" cask is Claude DESKTOP (the chat GUI); the claude-code CLI is
    # separate and comes from nixpkgs. Font casks moved to nixpkgs too.
    casks = [
      # Android SDK cmdline tools (sdkmanager/avdmanager) — backs `android-emu`
      # (modules/shared/home.nix), which boots VIRTUAL Android emulators.
      "android-commandlinetools"
      # adb/fastboot — the bridge mobile-mcp drives to automate a physical phone.
      "android-platform-tools"
      "blackhole-2ch"
      "brave-browser"
      "bruno"
      # Claude Desktop — the chat GUI (distinct from the claude-code CLI, nixpkgs).
      "claude"
      "docker-desktop"
      "dropbox"
      "google-chrome"
      "inkscape"
      "maccy"
      "microsoft-auto-update"
      "microsoft-teams"
      # OBS Studio. Its macOS Virtual Camera ships as a system extension
      # (com.obsproject.obs-studio.mac-camera-extension), installed on first launch
      # and persisting independently of OBS.app.
      "obs"
      "obsidian"
      "proton-drive"
      "raspberry-pi-imager"
      "slack"
      "telegram"
      "utm"
      "visual-studio-code"
      "whatsapp"
    ];

    # ---- Mac App Store apps (masApps) ----------------------------------------
    # macos only — macvm cannot sign into an Apple ID / App Store login, so any
    # masApps entry fails brew bundle there (hosts/macvm.nix keeps masApps = { }).
    # `mas` brew stays for on-demand installs; anything listed here is also
    # protected from onActivation.cleanup = "uninstall" (undeclared MAS apps
    # get removed — that is how Xcode was wiped before this entry).
    masApps = {
      # Official client is App Store–only (no Homebrew cask).
      WireGuard = 1451685025;
      # Full Xcode IDE from the Mac App Store (not the CLI tools alone).
      Xcode = 497799835;
    };
  };
}
