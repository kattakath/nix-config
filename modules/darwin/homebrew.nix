# Declarative Homebrew taps/brews/casks for the Macs (sourced from ~/Brewfile).
# nix-homebrew (./nix-homebrew.nix) installs brew itself; this module only
# declares its contents.
#
# What is DELIBERATELY NOT here (nixpkgs/Home Manager is the single source, and
# a duplicate on PATH causes buildEnv collisions): aws-cdk, awscli, make, node
# (unversioned), uv, gh, git-lfs, the claude-code cask, and 6 font casks — see
# modules/shared/home.nix. direnv was dropped from the repo entirely; reintroduce
# deliberately if a devShell ever needs it.
#
# What is INTENTIONALLY KEPT as a brew (not a nixpkgs dupe):
#   node@22, postgresql@14/@17 — version-pinned runtime/DB servers with their own
#     data dirs and services (nix `postgresql` is only the psql client).
#   cline, cypher-shell        — genuine nixpkgs misses.
#   (nodecg is an npm global, not a brew, so it is not declared at all.)
_:

{
  homebrew = {
    enable = true;

    # Conservative activation: additive and fast. cleanup = "none" installs
    # declared items but never uninstalls undeclared ones (flipping to "zap"
    # would make the Brewfile law and silently remove anything not listed here).
    # autoUpdate/upgrade off so a rebuild never silently bumps versions.
    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "none";
    };

    # ---- Taps --------------------------------------------------------------
    # Plain "owner/repo" taps are strings; a custom-git-URL tap uses the
    # attrset form with `clone_target`.
    taps = [
      {
        name = "comfy-org/comfy-cli";
        clone_target = "https://github.com/Comfy-Org/homebrew-comfy-cli";
      }
      "dail8859/notepadnext"
      "flschweiger/flutter"
      "jandedobbeleer/oh-my-posh"
      "loteoo/formulas"
      "minio/stable"
      "mongodb/brew"
      "nats-io/nats-tools"
      "runpod/runpodctl"
      "stripe/stripe-cli"
      "viarotel-org/escrcpy"
    ];

    # ---- Formulae (brews) --------------------------------------------------
    # See header for what was removed and what is intentionally kept. Entries
    # with special options use the attrset form.
    brews = [
      "age"
      "duf"
      "go"
      "kubernetes-cli"
      "ncdu"
      "nmap"
      "shellcheck"
      "tree"
      "wget"
      "yq"

      "act"
      "zstd"
      "aws-vault"
      "gettext"
      "bfg"
      "bruno-cli"
      "btop"
      "cline" # nixpkgs miss — kept as brew
      "cloudflare-cli4"
      "cloudflared"
      "cmake"
      "cocoapods"
      "cosign"
      "ctx7"
      "openjdk@21"
      "cypher-shell" # nixpkgs miss — kept as brew
      "devcontainer"
      "docker"
      "docker-buildx"
      "docker-compose"
      "dotnet"
      "ffmpeg"
      "firebase-cli"
      "flarectl"
      "flyctl"
      "fswatch"
      "gemini-cli"
      "git"
      "git-filter-repo"
      "git-xet"
      "glab"
      "go-task"
      "gollama"
      "graphviz"
      # link = false → don't symlink into the brew prefix.
      {
        name = "hf";
        link = false;
      }
      "imagemagick"
      "img2pdf"
      "jupyterlab"
      "midnight-commander"
      "nats-server"
      # restart_service = "changed" → restart only when the formula changes.
      {
        name = "neo4j";
        restart_service = "changed";
      }
      "node@22"
      "ocrmypdf"
      {
        name = "ollama";
        restart_service = "changed";
      }
      "pgvector"
      "podman"
      "poppler"
      "portaudio"
      "postgresql@14"
      "postgresql@17"
      "pv"
      "pyenv"
      "python@3.12"
      "qwen-code"
      {
        name = "redis";
        restart_service = "changed";
      }
      "scrcpy"
      "skaffold"
      "sshpass"
      "starship"
      "switchaudio-osx"
      "telnet"
      "terraform"
      "vercel-cli"
      "watch"
      "xcodes"
      "ykman"
      "yt-dlp"
      # Tap-qualified. The Brewfile's `trusted: true` is a `brew tap` flag with
      # no equivalent on a nix-darwin brew entry; the tap is already declared above.
      "nats-io/nats-tools/nats"
    ];

    # ---- Casks -------------------------------------------------------------
    # The "claude" cask is the Claude DESKTOP app (the claude-code CLI cask was
    # dropped for nixpkgs — see header). Font casks moved to nixpkgs too.
    casks = [
      "android-commandlinetools"
      "android-platform-tools"
      "applite"
      "audacity"
      "blackhole-2ch"
      "brave-browser"
      "bruno"
      "camo-studio"
      "capcut"
      "chatgpt"
      "claude"
      "cursor"
      "devpod"
      "docker-desktop"
      "droidcam-obs"
      "viarotel-org/escrcpy/escrcpy"
      "figma@beta"
      "firefox"
      "flutter"
      "gcloud-cli"
      "google-chrome"
      "inkscape"
      "lm-studio"
      "maccy"
      "microsoft-auto-update"
      "microsoft-edge"
      "microsoft-teams"
      "miniconda"
      "dail8859/notepadnext/notepadnext"
      "obs"
      "obsidian"
      "postman"
      "postman-cli"
      "prince"
      "privatevpn"
      "qlmarkdown"
      "raspberry-pi-imager"
      "slack"
      "slack-cli"
      "sourcetree"
      "syncthing-app"
      "telegram"
      "temurin"
      "ungoogled-chromium"
      "utm"
      "visual-studio-code"
      "visual-studio-code@insiders"
      "vlc"
      "vnc-viewer"
      "whatsapp"
      "yubico-authenticator"
      "zoom"
    ];

    # ---- Mac App Store apps (masApps) --------------------------------------
    # Only the public numeric App Store ID + a label — never Apple credentials.
    # nix-darwin drives installs via `mas`, but the App Store must already be
    # signed in and the apps already "owned" (GUI sign-in can't be automated).
    masApps = {
      "Xcode" = 497799835;
      "Plash" = 1494023538;
    };
  };
}
