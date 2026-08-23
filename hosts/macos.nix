# macOS host config for "macos" (Apple Silicon, aarch64-darwin) — the fleet's
# sole client Mac. No public tunnel / inbound SSH from the internet; the machine
# may still run local agent services (MCP gateway) and a self-hosted GitLab CI
# runner for private pipelines (civitai-live-wallpaper — see gitlab-runner brew).
# Home Manager and the nix-vscode-extensions overlay are wired centrally by
# mkDarwin in flake.nix — this file only provides host-specific settings.
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
    ../modules/darwin/github-runner.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # ---- Self-hosted GitHub Actions runner(s) for dontsell-ai ------------------
  # See modules/darwin/github-runner.nix for the full why/how. Org-level
  # registration serves every dontsell-ai repo (app, idea, ...) from this one
  # config, not just whichever repo happened to need it first. count = 2:
  # dontsell-ai/app's ci.yml fans one push into 7 parallel jobs; two instances
  # let two run at once instead of the whole backlog draining one job at a time
  # through a single runner (12 cores / 36GB on this Mac — comfortable headroom).
  #
  # appId/installationId: the "dontsell-ci" GitHub App (slug "dontsell-ai"),
  # created + owned by the dontsell-ai org itself (not a personal account),
  # installed ONLY on that org, granted ONLY "Organization permissions:
  # Self-hosted runners: Read and write" — confirmed via
  # `gh api orgs/dontsell-ai/installations` after creation, not assumed. Neither
  # value is secret on its own (see the module's option docs).
  #
  # Requires the gh-app-dontsell-ai-key agenix secret to exist first (the App's
  # private key, downloaded once from its settings page as a .pem) — mint it,
  # then `nix run github:ryantm/agenix -- -e secrets/gh-app-dontsell-ai-key.age`
  # and paste the .pem's contents into $EDITOR; never through chat/Claude.
  services.macosGithubRunner = {
    enable = true;
    org = "dontsell-ai";
    appId = 4689619;
    installationId = 155878309;
    count = 2;
  };

  # Stable identity for host-gated modules (login openers, RAG launchd, …) AND the
  # machine's declared name, so it's config-owned rather than manual scutil drift.
  # computerName is the Settings ▸ About ▸ Name; localHostName (the `.local` name)
  # defaults from hostName, so these two cover all three scutil names.
  networking.hostName = "macos";
  networking.computerName = "macos";

  users.users.${loginName} = {
    name = loginName;
    home = "/Users/${loginName}";
  };

  # ---- Gmail multi-account MCP (modules/shared/mcp.nix, a home-manager option
  # — set via home-manager.users, same as macvm.nix's services.mcpGateway.enable)
  # These two emails are safe to name in the PUBLIC repo — both are the
  # operator's own accounts under identities already public elsewhere in this
  # very tree (userEmail = ismail@kattakath.com in flake.nix's identityArgs;
  # kattakath.com is this repo's own namesake domain). Any OTHER account
  # (family/associates, or accounts the operator would rather not name here)
  # is added by the PRIVATE nix-personal flake instead, via extraHomeModules —
  # see the option's description in modules/shared/mcp.nix for the contract.
  home-manager.users.${loginName} = {
    services.mcpGateway.gmail.accounts = [
      "ismail@kattakath.com"
      "ismailkattakath@gmail.com"
    ];
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
      "git-cliff" # release stage — changelog / release notes (GitLab CI)
      "git-filter-repo"
      "gitlab-runner" # self-hosted GitLab CI runner (civitai pipeline on this host)
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
      "neonctl" # Neon DB CLI (https://neon.tech/docs/reference/neon-cli)
      "ocrmypdf"
      "pyenv"
      # scrcpy — mirror/control a PHYSICAL Android phone on the Mac (pulls its own
      # adb; the android-platform-tools cask provides the adb mobile-mcp uses).
      "scrcpy"
      "shellcheck"
      "starship"
      "swiftlint" # lint stage — SwiftLint --strict gate (GitLab CI)
      "switchaudio-osx"
      "tree"
      "vercel-cli" # Vercel CLI (`vercel`) — deploy/manage Vercel projects
      "wget"
      # NB: no `wireguard-tools` here — macos manages WireGuard through the GUI
      # (masApps.WireGuard) ONLY. Deliberately no `wg`/`wg-quick` CLI and no `vpn`
      # operator on this host, so nothing can bring a tunnel up from a shell (a
      # botched tunnel = no-internet on the sole client Mac). Confs are synced for
      # IMPORT into the app, never run (local.wireguardConfigs, home.nix). macvm —
      # which has no App Store — keeps the CLI (hosts/macvm.nix).
      "xcodes"
      "yq"
      "yt-dlp"
      "zstd"
    ];

    # ---- Casks ---------------------------------------------------------------
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
      # GCP CLI (gcloud/gsutil/bq) — Google-official SDK cask so `gcloud components
      # install` works and it self-updates (vs. the pinned nixpkgs derivation).
      # Homebrew renamed `google-cloud-sdk` → `gcloud-cli`; use the new name.
      "gcloud-cli"
      "iina"
      "inkscape"
      # LibreOffice — provides the `soffice` CLI the docx/pptx/xlsx/pdf Claude Code
      # skills (modules/shared/home.nix programs.claude-code.skills) already hardcode
      # as their document-conversion engine. Cask (not nixpkgs libreoffice-bin)
      # because its command_wrapper execs the real Mach-O soffice binary directly —
      # nixpkgs' wrapper shells out via `open -na`, which won't block/report exit
      # status for scripted --convert-to pipelines. First headless run may need a
      # one-time profile warm-up (soffice -env:UserInstallation=file:///tmp/... );
      # see the NOTE at the skills block below.
      "libreoffice"
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
      # Slack's official CLI for building/deploying Slack apps (docs.slack.dev/tools/slack-cli).
      # Cask, not nixpkgs' same-named "slack-cli" — that's an unrelated, unmaintained
      # rockymadden/slack-cli webhook-poster, not this tool.
      "slack-cli"
      "telegram"
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
      # Official client is App Store–only (no Homebrew cask). This GUI is the
      # ONLY way macos touches WireGuard — no CLI tools, no vpn operator. The
      # user imports a synced conf and connects manually in-app; nothing here
      # (or on activation) ever starts a tunnel.
      WireGuard = 1451685025;
      # Full Xcode IDE from the Mac App Store (not the CLI tools alone).
      # License is accepted *before* brew bundle by modules/darwin/xcode-license.nix
      # (Brewfile installs brews before masApps — without that, formulae fail with
      # "You have not agreed to the Xcode license" on first activation).
      Xcode = 497799835;
      # Plash — put a website on your desktop as the wallpaper. App Store–only
      # (no Homebrew cask). https://apps.apple.com/ca/app/plash/id1494023538
      Plash = 1494023538;
    };
  };
}
