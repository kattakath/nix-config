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
{ config, loginName, ... }:
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
  # appId/installationId: the "ismailkattakath-ci" App (4849830) — the SAME App
  # the Tart lane below uses. Neither value is secret on its own.
  #
  # 2026-09-06: this lane used to have its own App, "dontsell-ai" (4689619),
  # org-owned and granted only Organization/Self-hosted-runners RW. That was
  # retired because it stopped buying anything: ismailkattakath-ci is already
  # installed on dontsell-ai with repos=all, so the broader access existed
  # regardless, and a second narrow credential for the same job was defence in
  # depth that depth no longer had. (It WOULD still be worth keeping if
  # dontsell-ai were a third party who might need to revoke this Mac's access
  # without touching a personal account — it is not.)
  #
  # WHY THERE ARE STILL TWO AGENIX SECRETS FOR ONE APP: an agenix secret has
  # exactly one owner, and these two lanes run as different users —
  # gh-app-dontsell-ai-key is owned by `_github-runner` (these launchd DAEMONS)
  # and gh-app-fleet-key by the login user (the Tart USER AGENTS, which need a
  # GUI session). Same key material, two files, because of OS ownership rather
  # than credential separation. Consolidating Apps does not consolidate these.
  #
  # Both .age files therefore have to be re-encrypted together when the App key
  # rotates. Use `age -R` directly, NOT `agenix -e` (which silently encrypts
  # empty stdin when non-interactive), and verify the recipient tags match the
  # file being replaced.
  services.macosGithubRunner = {
    enable = true;
    org = "dontsell-ai";
    appId = 4849830;
    installationId = 159496676;
    count = 2;
  };

  # ---- Ephemeral Tart-VM CI runners (tart.githubRunners.*, nix-tart-vms) ---------
  # Every job gets a disposable macOS VM; the VM is the isolation boundary.
  # All instances share ONE fleet GitHub App ("ismailkattakath-ci", public,
  # appId 4849830, owned by the OPERATOR's personal account, not an org) and
  # its single agenix-delivered key below; each scope has its own
  # installationId.
  #
  # Consolidated 2026-09-06 from two Apps into this one. It replaced BOTH
  # "kattakath-fleet-ci" (4845230, runners) and "kattakath-ci" (4243998, the
  # Actions CI bot behind auto-merge and update-flake-lock), which is why its
  # permission set is the UNION of the two roles:
  #   Repository:   Contents RW, Pull requests RW, Actions RW, Metadata R
  #   Organization: Self-hosted runners RW
  # Deliberately NOT granted: Repository/Administration. The fleet App carried
  # it, but it is only needed for REPO-scoped runner registration and every
  # lane here is org-scoped — so it stayed off. Adding `scope.type = "repo"`
  # later needs that grant first.
  #
  # THE COST, recorded so it is a decision and not a surprise: App permissions
  # are App-GLOBAL, not per-installation (verified — all installations report
  # an identical set). So any key for this App can push to every repo in every
  # account it is installed on. Consolidating two Apps into one traded that
  # away for a single rotation surface; the previous split kept the Actions key
  # off this machine and the runner key unable to push code.
  #
  # Partly bought back 2026-09-06: agenix and the kattakath org secret
  # CI_BOT_APP_PRIVATE_KEY now hold TWO DIFFERENT keys of this same App, so
  # either is revocable alone (see secrets/secrets.nix for the fingerprints).
  # That is independent REVOCATION only — the permission blast radius above is
  # unchanged, because it is a property of the App, not of the key.
  #
  # The bare-metal dontsell lane above now uses this SAME App (4849830); its
  # own "dontsell-ai" App (4689619) was retired the same day — see that block.
  #
  # The two bare-metal dontsell runners
  # above STAY for that org's nix/cachix/pgvector-heavy CI (the Cirrus guest
  # image carries none of that toolchain) — dontsell workflows opt into VM
  # isolation with `runs-on: [self-hosted, tart, dontsell-vm]`. Apple caps
  # concurrent macOS guests at TWO; the module's slot semaphore shares that
  # budget across all three instances (asserted at eval).
  # The base clone AND the SSH host-key pin are content-keyed by oci@digest, so
  # bumping the digest below renames both — one elected instance re-pulls and
  # re-pins itself on its next cycle; the other two share that image/base/pin.
  # `tart-runner-setup-kattakath [image|pin|all]` pre-warms a bump by hand.
  # Slots, pins and both lanes' logs live in tart.runnerStateDir
  # (~/.local/state/tart-runner) — durable by assertion, never /tmp.
  age.secrets."gh-app-fleet-key" = {
    file = ../secrets/gh-app-fleet-key.age;
    owner = loginName;
    mode = "0400";
  };
  # The GitLab lane's glrt- runner token (runner "macos-ismail-dev",
  # gitlab.com). tart.gitlabRunner's agent renders config.toml from it at
  # start — the token never enters the store; secrets/secrets.nix has the
  # registration/rotation story.
  age.secrets."gitlab-runner-token" = {
    file = ../secrets/gitlab-runner-token.age;
    owner = loginName;
    mode = "0400";
  };
  tart =
    let
      fleetApp = {
        appId = 4849830;
        privateKeyPath = config.age.secrets."gh-app-fleet-key".path;
        image = {
          oci = "ghcr.io/cirruslabs/macos-runner:tahoe";
          # Resolved 2026-09-05; bump deliberately (a moving tag is refused).
          digest = "sha256:98acf50794306bc293f2e30e40115f1452772e4e17eb257968b7c98f39ebf231";
        };
      };
    in
    {
      githubRunners = {
        # DISABLED 2026-09-06, and the reason is the whole design constraint:
        # a lane holds its guest slot for the ENTIRE long-poll wait, not just
        # while a job runs. Measured — these two sat up for an hour with 0.0%
        # CPU, 8192 MB each of 36 GB, holding BOTH of Apple's two concurrent
        # macOS guests, having run zero jobs. Neither org has a single workflow
        # targeting a self-hosted runner (verified across all 63 repos), so the
        # cost bought nothing and starved dontsell-vm, which never acquired a
        # slot after coming up at 08:04:56.
        #
        # Re-enable when a workflow in that org actually needs macOS — and
        # preferably only after the controller provisions on demand rather than
        # pre-booting a guest to wait. Keeping the scope/installationId here so
        # re-enabling is a one-word change, not a re-derivation.
        kattakath = fleetApp // {
          enable = false;
          scope = {
            type = "org";
            value = "kattakath";
          };
          installationId = 159496730;
        };
        silvercreek = fleetApp // {
          enable = false;
          scope = {
            type = "org";
            value = "silvercreek-ai";
          };
          installationId = 159496756;
        };
        # Re-enabled 2026-09-06 after the label flip closed a real misroute.
        # GitHub matching is case-insensitive and a runner matches on a SUPERSET,
        # so this lane's {self-hosted, macOS, arm64, tart, dontsell-vm} answered
        # dontsell-ai/app's jobs when they asked for only
        # {self-hosted, macOS, ARM64} — and those jobs need nix/cachix/postgres
        # from the HOST, which a stock Cirrus guest does not have.
        #
        # Closed in the only place it CAN be closed, consumer-side: app's 10
        # `runs-on:` entries now require `nix` (dontsell-ai/app 1332beb), a label
        # only the bare-metal lane carries. Adding `nix` to that lane made the
        # flip possible; the consumer edit is what actually closed it.
        #
        # KEEP BOTH SIDES POSITIVE. Do not "simplify" by dropping `tart` here or
        # `nix` there — GitHub has no negative selector, so a lane identified
        # only by the ABSENCE of a label is exactly how this collision happened.
        dontsell-vm = fleetApp // {
          scope = {
            type = "org";
            value = "dontsell-ai";
          };
          installationId = 159496676;
        };
      };

      # GitLab lane on the SAME slot budget (civitai pipeline): declarative
      # gitlab-runner → Tart custom executor. Replaced the brew service +
      # hand-edited ~/.gitlab-runner/config.toml on 2026-09-05; registration
      # (minting the glrt- token) stays the one-time manual act.
      gitlabRunner = {
        enable = true;
        runnerName = "macos-ismail-dev";
        runnerId = 54669377;
        tokenFile = config.age.secrets."gitlab-runner-token".path;
        concurrent = 2;
      };
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
  # — set via home-manager.users)
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

  # ---- OpenDesign: kill the in-app self-updater --------------------------------
  # Pairs with the greedy `open-design` cask below — versioning belongs to brew,
  # not the app's own updater (see the cask's comment for the measured drift).
  # launchd.user.envVariables is nix-darwin's own lever for env that reaches
  # Finder/Dock-launched GUI apps (`launchctl setenv` at activation — same
  # mechanism as the GUI PATH in modules/darwin/core.nix); the app's updater
  # honors OD_UPDATE_ENABLED as a truthy/falsy kill-switch for both the 6h check
  # and the auto-download. Takes effect for apps launched after activation.
  launchd.user.envVariables.OD_UPDATE_ENABLED = "0";

  # ---- Homebrew apps for THIS host --------------------------------------------
  # The framework (enable/onActivation/taps) lives in modules/darwin/homebrew.nix;
  # this is macos's app set. onActivation.cleanup = "uninstall" removes anything
  # installed but not listed here.
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
      # gitlab-runner moved OFF brew 2026-09-05: tart.gitlabRunner below runs
      # pkgs.gitlab-runner as a launchd agent with a runtime-rendered config
      # (nix-tart-vms darwinModules.gitlab-runner). After activating, retire
      # the brew copy once: `brew services stop gitlab-runner`.
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
      # IMPORT into the app, never run (local.wireguardConfigs, home.nix).

      "xcodes"
      "yq"
      "yt-dlp"
      "zstd"
    ];

    # ---- Casks ---------------------------------------------------------------
    casks = [
      # Affinity — the fleet's image/vector/layout editor, one app since v3
      # (Designer + Photo + Publisher merged). Free for individuals and
      # self-updating (auto_updates), so the cask only bootstraps it. Closed
      # source is the accepted cost of a Photoshop-shaped tool; the FOSS
      # alternatives (GIMP, Krita) are deliberately not carried.
      "affinity"
      # Audacity — multi-track audio editor. Pairs with the blackhole-2ch cask
      # below: BlackHole is a virtual output device, so routing an app's audio
      # into it gives Audacity a capture source for system audio, which macOS
      # otherwise refuses to expose.
      "audacity"
      # Android SDK cmdline tools (sdkmanager/avdmanager) — backs `android-emu`
      # (modules/shared/home.nix), which boots VIRTUAL Android emulators.
      "android-commandlinetools"
      # adb/fastboot — the bridge mobile-mcp drives to automate a physical phone.
      "android-platform-tools"
      "blackhole-2ch"
      "bruno"
      # CapCut — the fleet's video editor.
      "capcut"
      # Claude Desktop — the chat GUI (distinct from the claude-code CLI, nixpkgs).
      "claude"
      "docker-desktop"
      "dropbox"
      # escrcpy — graphical frontend for scrcpy (the `scrcpy` brew above), for
      # driving a PHYSICAL Android phone by mouse instead of remembering flags.
      # Complements, never replaces, `android-phone` (packages/android-phone.nix):
      # that CLI still owns the adb pairing/connect footguns it exists to encode,
      # and its header's refusal to VENDOR a third-party pairing tool is unaffected
      # by installing one alongside. From the sole third-party tap — see the tap's
      # comment in modules/darwin/homebrew.nix for the other accepted cost.
      #
      # postinstall is LOAD-BEARING — without it the app installs but cannot be
      # opened at all. Upstream ships Escrcpy.app with no _CodeSignature, only the
      # linker's adhoc signature (measured 2026-08-31: `Sealed Resources=none`,
      # `Identifier=Electron`, `Info.plist=not bound`). Unsigned + quarantined is
      # what macOS reports as "damaged and can't be opened", and that variant is
      # NOT clearable by right-click ▸ Open — the flag must actually be gone. The
      # cask's own postflight tries to strip it, but only interactively, which
      # `brew bundle` can never satisfy (no stdin; a method-level rescue swallows
      # the failure), so the flag survived every activation.
      #
      # Why postinstall and not `args.no_quarantine = true`: nix-darwin still
      # offers that arg, but Homebrew 6.0.18 has REMOVED the flag — brew bundle
      # turns it into `brew install --cask --no-quarantine`, which aborts with
      # "Error: invalid option: --no-quarantine" and fails activation. Verified
      # 2026-08-31 against this exact brew. Do not switch back to it.
      #
      # `xattr -dr` exits 0 when the attribute is already absent, so this is
      # idempotent, and brew only fires postinstall on a real install/upgrade —
      # not on every activation (bundle/cask.rb `preinstall!` returns false for an
      # already-installed cask, and `install!` early-returns on that). No sudo:
      # the .app is owned by the operator.
      #
      # NOTHING STATICALLY VALIDATES THIS KEY. Measured 2026-08-31: `brew bundle
      # list` parses a Brewfile carrying a completely made-up cask key without any
      # error, so a typo here is a SILENT no-op — the app installs, quarantine
      # stays, and the only symptom is the "damaged" dialog again. Verify against
      # brew's own source (bundle/cask.rb), never against a green bundle command.
      #
      # The tradeoff is deliberate: Gatekeeper never gets to evaluate this app, so
      # the viarotel-org build is trusted directly. Scoped to this ONE cask — never
      # generalise it to the whole casks list.
      {
        name = "escrcpy";
        postinstall = "/usr/bin/xattr -dr com.apple.quarantine /Applications/Escrcpy.app";
      }
      # Google Drive for desktop — the File Provider client (a mounted volume under
      # ~/Library/CloudStorage/, NOT a plain folder). It replaced `google-chrome`
      # here: Chrome's only load-bearing job on this host was rendering JSON Resume
      # PDFs through puppeteer, and that now points at the ungoogled-chromium cask
      # (PUPPETEER_EXECUTABLE_PATH, modules/shared/home.nix).
      "google-drive"
      # GCP CLI (gcloud/gsutil/bq) — Google-official SDK cask so `gcloud components
      # install` works and it self-updates (vs. the pinned nixpkgs derivation).
      # Homebrew renamed `google-cloud-sdk` → `gcloud-cli`; use the new name.
      "gcloud-cli"
      # Ghostty — GPU-accelerated terminal. A CASK because nixpkgs' `ghostty` is
      # LINUX-ONLY and refuses to evaluate on aarch64-darwin, which is exactly the
      # case home-manager documents for `programs.ghostty.package = null`:
      # Homebrew ships the app, Nix owns the config. Same split as the
      # ungoogled-chromium cask. Settings live in modules/shared/home.nix.
      "ghostty"
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
      # OpenDesign — the local-first design-agent desktop app (Electron; its
      # stdio MCP server is declared per-client in modules/shared/mcp.nix).
      # Adopts the previously hand-dragged /Applications copy: `brew bundle`
      # passes --adopt to every fresh cask install, and for an auto_updates cask
      # adoption is unconditional (no re-copy, no touch of the app's ~1GB state).
      #
      # greedy is LOAD-BEARING, paired with launchd.user.envVariables.
      # OD_UPDATE_ENABLED below — the in-app updater's launcher-tree relaunch
      # path caused a measured version split (docs/open-design.md has the
      # numbers). greedy opts this one cask back into upgrades past
      # onActivation.upgrade = false, so versions land at activation instead
      # and /Applications stays the only copy that ever runs.
      {
        name = "open-design";
        greedy = true;
      }
      "proton-drive"
      "raspberry-pi-imager"
      "slack"
      # Slack's official CLI for building/deploying Slack apps (docs.slack.dev/tools/slack-cli).
      # Cask, not nixpkgs' same-named "slack-cli" — that's an unrelated, unmaintained
      # rockymadden/slack-cli webhook-poster, not this tool.
      "slack-cli"
      "telegram"
      # ungoogled-chromium — Chromium without the Google integration. Cask because
      # nixpkgs' chromium/ungoogled-chromium are *-linux only (no darwin build), and
      # the plain `chromium` cask is deprecated (fails the macOS Gatekeeper check,
      # disabled 2026-09-01). Its declarative config — the sideloaded iCloud
      # Passwords extension + Apple's native-messaging host, which macOS otherwise
      # ships to Chrome and Firefox ONLY — lives in modules/shared/chromium.nix.
      "ungoogled-chromium"
      "visual-studio-code"
      "whatsapp"
    ];

    # ---- Mac App Store apps (masApps) ----------------------------------------
    # macos only — a sandbox host cannot sign into an App Store login, so any
    # masApps entry fails brew bundle there.
    # `mas` brew stays for on-demand installs; anything listed here is also
    # protected from onActivation.cleanup = "uninstall" (undeclared MAS apps
    # get removed — that is how Xcode was wiped before this entry).
    masApps = {
      # Official client is App Store–only (no Homebrew cask). This GUI is the
      # ONLY way macos touches WireGuard — no CLI tools, no vpn operator. The
      # user imports a synced conf and connects manually in-app; nothing here
      # (or on activation) ever starts a tunnel.
      WireGuard = 1451685025;
      # Display My IP — public IP + country in the menu bar, with a notification
      # when it changes. The companion to masApps.WireGuard above: because that
      # GUI is the only way a tunnel comes up here (no `wg`, no `vpn` operator),
      # no shell can answer "is the tunnel actually up?" — this makes the answer
      # permanently visible. Free, and App Store–only like WireGuard itself.
      # https://apps.apple.com/ca/app/display-my-ip/id1493408723
      "Display My IP" = 1493408723;
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
