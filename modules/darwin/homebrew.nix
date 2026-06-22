# nix-darwin Homebrew module — make Homebrew DECLARATIVE on macOS (m3pro).
#
# This module brings the operator's previously-imperative Homebrew state under
# nix-darwin's `homebrew` module, sourced from ~/Brewfile (regenerated 2026-06-22).
#
# Split of responsibilities:
#   - nixpkgs is the SINGLE SOURCE for the tools now provided by the shared Home
#     Manager profile (modules/shared/home.nix). Their Homebrew equivalents were
#     DUPLICATES on PATH and have been removed from this file:
#       brews removed → aws-cdk (nix aws-cdk-cli), awscli (nix awscli2),
#         make (nix gnumake), node — UNVERSIONED (nix nodejs), uv (nix uv),
#         gh (programs.gh), git-lfs (programs.git.lfs).
#       direnv: brew removed and NOT re-added — direnv was dropped from this
#         repo entirely (no longer in home-manager either); reintroduce
#         deliberately if a future devShell workflow wants it.
#       casks removed → claude-code (nix claude-code CLI in home.packages).
#   - Version-pinned servers/runtimes are INTENTIONALLY RETAINED in Homebrew —
#     they are NOT plain dupes of the nixpkgs tools:
#       node@22                     — deliberate pinned Node version
#                                     (nix provides only unversioned nodejs).
#       postgresql@14, postgresql@17 — version-pinned DATABASE SERVERS with
#                                     data dirs/services; the nix `postgresql`
#                                     is only the psql client.
#   - FONTS were promoted to nixpkgs (cross-host: macOS + NixOS + devcontainers)
#     — see modules/shared/home.nix. Their 6 cask equivalents were removed from
#     the `casks` list below.
#   - All remaining GUI apps (casks) and CLI formulae are managed here.
#
# Hard nixpkgs-misses intentionally kept as brews:
#   - cline       → brew formula, stays in homebrew.brews
#   - cypher-shell → brew formula, stays in homebrew.brews
#   (nodecg is an npm global, NOT a brew — so it is NOT declared here at all.)
#
# nix-darwin only MANAGES Homebrew here; it does not INSTALL Homebrew itself.
# `brew` must already be present on the host (it is, on m3pro).
_:

{
  homebrew = {
    enable = true;

    # ---- Activation behaviour: deliberately CONSERVATIVE first pass --------
    #
    # These are the SAFE, NON-destructive defaults for the initial rollout.
    # The operator can tighten them later.
    #
    #   cleanup trade-off:
    #     "none" (current) — ADDITIVE/SAFE. nix-darwin installs anything
    #         declared here but NEVER uninstalls packages it doesn't know
    #         about. Existing hand-installed brews/casks are left untouched.
    #     "zap"            — FULLY REPRODUCIBLE but DESTRUCTIVE. nix-darwin
    #         uninstalls (and zaps the data of) ANY brew/cask/tap not declared
    #         in this file on every rebuild. This is the "the Brewfile is law"
    #         mode — only flip to it once this list is known-complete, or it
    #         will silently remove undeclared software. Operator's choice later.
    #     "uninstall"      — like "zap" but leaves app data behind.
    #
    # autoUpdate/upgrade are OFF so a `darwin-rebuild switch` stays fast and
    # predictable and never silently bumps formula/cask versions underfoot.
    onActivation = {
      autoUpdate = false; # don't `brew update` on every rebuild
      upgrade = false; # don't `brew upgrade` formulae/casks on every rebuild
      cleanup = "none"; # do NOT uninstall undeclared items (safe / additive)
    };

    # ---- Taps (11) --------------------------------------------------------
    # Plain "owner/repo" taps are strings. Taps that point at a custom git
    # URL use the attrset form with `clone_target`.
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

    # ---- Formulae (brews) -------------------------------------------------
    # All `brew "..."` entries from the Brewfile EXCEPT those removed per the
    # header (aws-cdk, awscli, make, node, uv, gh, git-lfs; direnv dropped
    # entirely). Version-pinned servers/runtimes (node@22,
    # postgresql@14/@17) are intentionally retained. Version-pinned and
    # tap-qualified names are preserved verbatim. Entries with special options
    # use the attrset form.
    brews = [
      "age"
      "chezmoi"
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
      # `brew "hf", link: false` → don't symlink into the brew prefix.
      {
        name = "hf";
        link = false;
      }
      "imagemagick"
      "img2pdf"
      "jupyterlab"
      "midnight-commander"
      "nats-server"
      # `brew "neo4j", restart_service: :changed` → restart only when the
      # formula changes. nix-darwin accepts the "changed" string here.
      {
        name = "neo4j";
        restart_service = "changed";
      }
      "node@22"
      "ocrmypdf"
      # `brew "ollama", restart_service: :changed`
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
      # `brew "redis", restart_service: :changed`
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
      # `brew "nats-io/nats-tools/nats", trusted: true` — tap-qualified.
      # nix-darwin has no `trusted` key on a brew entry; `trusted` is a
      # `brew tap` security flag, and the nats-io/nats-tools tap is already
      # declared above. Declared here as the plain tap-qualified formula.
      "nats-io/nats-tools/nats" # TODO: special opt `trusted: true` not representable on a brew entry
    ];

    # ---- Casks (52) -------------------------------------------------------
    # All `cask "..."` entries from the Brewfile EXCEPT claude-code (now the
    # nixpkgs claude-code CLI in home.packages). The "claude" cask below is the
    # separate Claude DESKTOP app and is intentionally retained. Version-pinned names
    # (figma@beta, visual-studio-code@insiders) and tap-qualified names
    # (viarotel-org/escrcpy/escrcpy, dail8859/notepadnext/notepadnext) are
    # preserved verbatim as full strings.
    # All 6 font casks (font-fira-code-nerd-font, font-hack-nerd-font,
    # font-roboto, font-roboto-condensed, font-ubuntu-mono-nerd-font,
    # font-ubuntu-nerd-font) were removed. Of these, only the two actually used
    # are kept — now via nixpkgs, cross-host (see modules/shared/home.nix):
    # nerd-fonts.ubuntu-mono (terminal) + nerd-fonts.jetbrains-mono (editor).
    # The rest were dropped as unused.
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

    # ---- Mac App Store apps (masApps) -------------------------------------
    # Only the app's PUBLIC numeric App Store ID (from the apps.apple.com URL,
    # e.g. .../id497799835) plus a cosmetic label live here — NEVER the Apple
    # ID/credentials. nix-darwin installs the `mas` CLI to drive installs, but
    # the App Store app must already be signed in with an Apple ID (the GUI
    # sign-in cannot be automated, and the apps must already be "owned").
    masApps = {
      "Xcode" = 497799835;
      "Plash" = 1494023538;
    };
  };
}
