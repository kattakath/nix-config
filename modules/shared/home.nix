# Unified user profile — loaded on EVERY machine (macOS, Pi, sandbox VM).
# The single home of "user logic"; system-level platform specifics live in
# modules/darwin and modules/nixos.
#
# Personal token VALUES are intentionally NOT managed here. On macOS they live
# in the login Keychain (encrypted at rest) — stored/registered by `set-secret`
# (packages/set-secret.nix) and exported into login shells by the darwin-only
# secretsKeychainInit hook in the let block below. Nothing plaintext is written
# to disk. The Keychain is macOS-only, so the Linux hosts get no personal-token
# mechanism here (use one-time CLI logins: gh/hf/docker/claude).
#
# SYSTEM/SERVICE secrets are separate from this profile: committed encrypted via
# agenix (secrets/*.age → /run/agenix/<name> at activation, e.g. the macos
# runner PAT). The exception is nixpi's Cloudflare tunnel token, planted on the
# FAT FIRMWARE partition → /run/cloudflared-token (agenix would bind it to the SSH
# host key a fresh SD flash rotates — see hosts/nixpi.nix).
#
# Deliberately MINIMAL: no nixvim/tmux — the operator uses VSCode/Cursor and
# prefers a lean profile with starship for the shell prompt. Add tools only for
# a clear cross-host need.
{
  pkgs,
  lib,
  config,
  fullName,
  userEmail,
  # Source-only flake inputs holding Claude Code skills (see programs.claude-code
  # below). flake.nix pins them; nothing is vendored into this repo.
  agent-skills-vercel,
  agent-skills-anthropic,
  # Live-wallpaper loopback port (single-sourced in flake.nix) — the darwin-gated
  # Plash activation below points Plash at it; inert on the NixOS hosts. Kept as
  # the opt-in live-wallpaper path alongside the default static wallpaper.
  wallpaperPort,
  ...
}:
let
  # VS Code Marketplace mirror — provided by the nix-vscode-extensions overlay,
  # which the darwin host (macos) adds to nixpkgs.overlays. Only referenced
  # inside the `mkIf isDarwin` vscode block, so the Linux hosts (which don't
  # apply the overlay) never touch it. CRUCIAL: reading the overlay attr off
  # `pkgs` (rather than the flake input's `.extensions.<sys>` output) means the
  # extensions are built against OUR nixpkgs and so respect the host's
  # `nixpkgs.config.allowUnfree` — the input's `.extensions` output uses its own
  # nixpkgs with default config and ignores our unfree allowance.
  marketplace = pkgs.vscode-marketplace or null;
  # #80: on aarch64-darwin, upstream claude-code sets `__noChroot = isDarwin`
  # (pkgs/by-name/cl/claude-code/package.nix), which a strict-sandbox darwin
  # builder (nix `sandbox = true`) rejects at derivation instantiation
  # ("has '__noChroot' set, but that's not allowed when 'sandbox' is 'true'").
  # The __noChroot exemption only exists so the versionCheckHook install-check
  # can run the bun binary at build time; with doInstallCheck=false the darwin
  # build reduces to `installBin $src` (src is a fixed-output fetchurl, fetchable
  # in-sandbox) + wrapProgram — both network-free — so __noChroot is unnecessary.
  # Drop it too. No-op on linux (both attrs already false there → identical drv).
  claudeCode = pkgs.claude-code.overrideAttrs (_: {
    doInstallCheck = false;
    __noChroot = false;
  });

  # `set-secret <KEY> [VALUE]` — stores a secret in the macOS login Keychain
  # (encrypted at rest) and registers it in an in-Keychain index. macOS-only.
  setSecret = pkgs.callPackage ../../packages/set-secret.nix { };

  # `android-emu [avd-name] [emulator-args…]` — boot an Android emulator,
  # provisioning on first run. If the SDK packages or the AVD are missing it
  # installs them via the Homebrew `sdkmanager`/`avdmanager` (the
  # android-commandlinetools cask + ANDROID_HOME set below), then launches.
  # Uses a native arm64 system image (fast on Apple Silicon). macOS-only.
  androidEmu = pkgs.writeShellApplication {
    name = "android-emu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      ANDROID_HOME="''${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
      export ANDROID_HOME
      image="system-images;android-35;google_apis;arm64-v8a"
      avd="''${1:-pixel}"
      sdkmanager="/opt/homebrew/bin/sdkmanager"
      avdmanager="/opt/homebrew/bin/avdmanager"
      emulator="$ANDROID_HOME/emulator/emulator"

      if [ ! -x "$sdkmanager" ]; then
        echo "android-emu: sdkmanager not found — run 'darwin-rebuild switch' to install the android-commandlinetools cask" >&2
        exit 1
      fi

      # First run: accept licenses + install emulator/platform-tools/system image.
      if [ ! -x "$emulator" ] || [ ! -d "$ANDROID_HOME/system-images" ]; then
        echo "android-emu: installing SDK packages (first run, a few GB)…" >&2
        yes | "$sdkmanager" --licenses >/dev/null || true
        "$sdkmanager" "platform-tools" "emulator" "$image"
      fi

      # Create the AVD on first use (decline the custom-hardware prompt).
      if ! "$avdmanager" list avd -c | grep -qx "$avd"; then
        echo "android-emu: creating AVD '$avd'…" >&2
        echo "no" | "$avdmanager" create avd -n "$avd" -k "$image"
      fi

      exec "$emulator" -avd "$avd" "''${@:2}"
    '';
  };

  # Shell login init for the Keychain-backed secret store (macOS only). Two jobs:
  #   1. EXPORT every registered secret from the login Keychain into this login
  #      shell (the source of truth is the Keychain; nothing plaintext on disk).
  #   2. Define a `set-secret` FUNCTION that persists via the binary AND exports
  #      the value into the CURRENT shell immediately (a bare binary can't touch
  #      its parent's env). Shared verbatim by the zsh and bash profileExtra.
  # Empty string on non-darwin hosts, so this is a pure macOS feature.
  secretsKeychainInit = lib.optionalString pkgs.stdenv.isDarwin ''
    __ss_account="$(id -un)"
    __ss_index="$(/usr/bin/security find-generic-password -a "$__ss_account" -s __set_secret_index__ -w 2>/dev/null || true)"
    # Split the SPACE-separated index by peeling one token at a time with POSIX
    # parameter expansion — identical in zsh and bash (whereas `for k in $index`
    # does NOT word-split in zsh). No subshell, so the exports land in THIS shell.
    __ss_rest="$__ss_index"
    while [ -n "$__ss_rest" ]; do
      __ss_k="''${__ss_rest%% *}" # first token
      __ss_rest="''${__ss_rest#"$__ss_k"}" # drop it
      __ss_rest="''${__ss_rest# }" # trim one leading space
      [ -n "$__ss_k" ] || continue
      __ss_v="$(/usr/bin/security find-generic-password -a "$__ss_account" -s "$__ss_k" -w 2>/dev/null)" \
        && export "$__ss_k=$__ss_v"
    done
    unset __ss_account __ss_index __ss_rest __ss_k __ss_v

    # Wrapper: persist to the Keychain, then apply to THIS shell right away.
    set-secret() {
      command set-secret "$@" || return
      case "''${1:-}" in
        [A-Za-z_]*)
          export "$1=$(/usr/bin/security find-generic-password -a "$(id -un)" -s "$1" -w 2>/dev/null)"
          ;;
      esac
    }
  '';
in
{
  imports = [
    ./mcp.nix # darwin-gated MCP server registry for Claude Code
  ];

  # Expose the kapture browser-automation server PUBLICLY as an OAuth-gated MCP
  # connector (Cloudflare Access Managed OAuth in front, provisioned by
  # infra/cloudflare/macos-mcp-tunnel.nix). Darwin-only — the gateway itself is
  # darwin-gated. This starts a kapture-only mcp-proxy + the Mac cloudflared
  # connector, but NOTHING is exposed until the operator runs `nix run
  # .#cf-mcp-apply` and stores the printed token with `set-secret MCP_TUNNEL_TOKEN
  # <token>` (the connector is inert without it). See docs/mcp-connector-oauth-runbook.md.
  services.mcpGateway = lib.mkIf pkgs.stdenv.isDarwin {
    publicServers = [ "kapture" ];
    publicTunnel.enable = true;
  };

  # Make Home-Manager-installed font packages discoverable by applications.
  # Essential on Linux (registers fonts with fontconfig); harmless no-op on macOS.
  fonts.fontconfig.enable = true;

  # PERSONAL, cross-host packages only — tools wanted on EVERY machine, not
  # project toolchains (those live in each repo's own devShell). claude-code is
  # the one CLI kept here: genuinely personal, used in every repo.
  #
  # gh / git-lfs stay OUT of this list — they come from their `programs.*`
  # modules below (listing them here too would be a buildEnv /bin collision).
  #
  # Fonts: only the two wired to a VS Code setting are kept. nixpkgs unstable
  # uses the per-font `nerd-fonts.<name>` attrs (24.05+ restructure), not the
  # old `(nerdfonts.override { ... })`.
  home.packages =
    with pkgs;
    [
      fh # FlakeHub CLI — flake input publishing/management, wanted on every host
      # fonts (each is referenced by a VS Code font setting below)
      nerd-fonts.jetbrains-mono # "JetBrainsMono Nerd Font" — VS Code editor font (pairs with the JetBrains theme)
      nerd-fonts.ubuntu-mono # "UbuntuMono Nerd Font" — VS Code terminal font (matches the devcontainer)
    ]
    # claude-code: on darwin it is installed by the programs.claude-code module
    # below (so the mcp-servers-nix integration can inject the shared MCP
    # registry — see ./mcp.nix). On the Linux hosts we don't enable that module,
    # so install the bare CLI here instead. Avoids a buildEnv /bin collision.
    ++ lib.optionals (!stdenv.isDarwin) [ claudeCode ]
    # set-secret: Keychain-backed secret writer, macOS-only (see the let block).
    # On PATH so the `set-secret` shell function can call `command set-secret`.
    ++ lib.optionals stdenv.isDarwin [
      setSecret
      androidEmu
    ];

  # ---- Android SDK (macOS only) ------------------------------------------------
  # The `android-commandlinetools` Homebrew cask installs sdkmanager/avdmanager
  # under the Homebrew prefix. Point ANDROID_HOME there so `sdkmanager` downloads
  # the emulator + system images into it, and put the emulator/platform-tools
  # bins on PATH (adb itself also comes from the `android-platform-tools` cask).
  # After switching, just run `android-emu` (the helper in the let block) — it
  # installs the SDK packages + creates the AVD on first run, then boots it.
  home.sessionVariables = lib.mkIf pkgs.stdenv.isDarwin {
    ANDROID_HOME = "/opt/homebrew/share/android-commandlinetools";
  };
  home.sessionPath = lib.optionals pkgs.stdenv.isDarwin [
    "/opt/homebrew/share/android-commandlinetools/emulator"
    "/opt/homebrew/share/android-commandlinetools/platform-tools"
  ];

  # ---- Home Manager program modules --------------------------------------------
  programs = {
    # Let Home Manager manage itself.
    home-manager.enable = true;

    # Claude Code CLI. On darwin we manage it via the module (not just as a bare
    # package) so ./mcp.nix can attach `mcpServers` — the localhost MCP gateway's
    # SSE endpoints (+ desktop-commander stdio) — into a managed .mcp.json.
    # `package` preserves our darwin strict-sandbox override (claudeCode above,
    # also used by the VS Code "claude" terminal profile). On the Linux hosts
    # claude-code stays a plain home.packages entry with no MCP wiring.
    claude-code = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      package = claudeCode;

      # Flake-managed GLOBAL skills for Claude Code — the declarative, reproducible
      # replacement for `npx skills add --global` (which drops a loose symlink into
      # ~/.claude/skills). Each entry writes ~/.claude/skills/<name>/ at activation
      # from a PINNED flake input (flake.nix), so a `darwin-rebuild switch`
      # reproduces the exact skills on any machine and `nix flake update` bumps
      # them — nothing vendored. (Repo-SPECIFIC skills stay in .claude/skills/ and
      # activate only when working in this repo.)
      skills = {
        # Skill discovery from skills.sh (vercel-labs/skills).
        find-skills = "${agent-skills-vercel}/skills/find-skills";
        # Anthropic's official authoring toolkit for smarter claude-code project
        # setup — the full plugin-dev skill set (agent/skill/command/hook/plugin/
        # mcp authoring) plus hookify (hook rules).
        agent-development = "${agent-skills-anthropic}/plugins/plugin-dev/skills/agent-development";
        skill-development = "${agent-skills-anthropic}/plugins/plugin-dev/skills/skill-development";
        command-development = "${agent-skills-anthropic}/plugins/plugin-dev/skills/command-development";
        hook-development = "${agent-skills-anthropic}/plugins/plugin-dev/skills/hook-development";
        mcp-integration = "${agent-skills-anthropic}/plugins/plugin-dev/skills/mcp-integration";
        plugin-structure = "${agent-skills-anthropic}/plugins/plugin-dev/skills/plugin-structure";
        plugin-settings = "${agent-skills-anthropic}/plugins/plugin-dev/skills/plugin-settings";
        writing-hookify-rules = "${agent-skills-anthropic}/plugins/hookify/skills/writing-rules";
      };
    };

    git = {
      enable = true;
      lfs.enable = true; # git-lfs, wired into git config (devcontainer feature)
      settings = {
        user.name = lib.mkDefault fullName;
        user.email = lib.mkDefault userEmail;
        init.defaultBranch = "main";
        pull.rebase = true;
        commit.gpgsign = true;
        gpg.format = "ssh";
        user.signingkey = "~/.ssh/id_ed25519.pub";
      };
    };

    ssh = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;

      # Forward-compat with the home-manager `programs.ssh` deprecation: the module
      # is dropping its implicit `settings."*"` defaults (and warns while they remain
      # on by default), and `matchBlocks` is now a deprecated alias for `settings`.
      # We opt out with `enableDefaultConfig = false`, re-declare the exact 10 defaults
      # ourselves under `settings."*"`, and move the per-host blocks to `settings` so
      # generated ~/.ssh/config stays byte-identical while both warnings are silenced.
      enableDefaultConfig = false;

      settings = {
        # The former implicit defaults, re-stated verbatim (OpenSSH directive names).
        "*" = {
          ForwardAgent = false;
          AddKeysToAgent = "no";
          Compression = false;
          ServerAliveInterval = 0;
          ServerAliveCountMax = 3;
          HashKnownHosts = false;
          UserKnownHostsFile = "~/.ssh/known_hosts";
          ControlMaster = "no";
          ControlPath = "~/.ssh/master-%r@%n:%p";
          ControlPersist = "no";
        };

        # Local NixOS hosts (mDNS .local) — agent forwarding on for interactive
        # admin work over SSH from the Mac.
        "*.local" = {
          User = config.home.username;
          IdentityFile = "~/.ssh/id_ed25519";
          ForwardAgent = true;
        };

      };
    };

    # GitHub CLI (`gh`) — devcontainer github-cli feature.
    gh.enable = true;

    direnv = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };

    # A login shell is required for `home-manager switch` to wire session vars.
    bash = {
      enable = true;
      # macOS: load Keychain-backed secrets + define set-secret on a bash login
      # too. Empty on non-darwin (see secretsKeychainInit in the let block).
      profileExtra = secretsKeychainInit;
    };

    # zsh as the interactive shell — matches the devcontainer default
    # (common-utils configureZshAsDefaultShell). Kept lean: no oh-my-zsh /
    # framework, default prompt. bash stays enabled above for login-shell
    # compatibility.
    starship = {
      enable = true;
      settings = {
        format = "$username$hostname$directory$git_branch$git_state$git_status$cmd_duration$line_break$python$character";
        directory.style = "blue";
        character = {
          success_symbol = "[❯](purple)";
          error_symbol = "[❯](red)";
          vimcmd_symbol = "[❮](green)";
        };
        git_branch = {
          format = "[$branch]($style)";
          style = "bright-black";
        };
        git_status = {
          format = "[[(*$conflicted$untracked$modified$staged$renamed$deleted)](218) ($ahead_behind$stashed)]($style)";
          style = "cyan";
          conflicted = "";
          untracked = "";
          modified = "";
          staged = "";
          renamed = "";
          deleted = "";
          stashed = "≡";
        };
        git_state = {
          format = ''\'([$state( $progress_current/$progress_total)]($style)\) '';
          style = "bright-black";
        };
        cmd_duration = {
          format = "[$duration]($style) ";
          style = "yellow";
        };
        python = {
          format = "[$virtualenv]($style) ";
          style = "bright-black";
          detect_extensions = [ ];
          detect_files = [ ];
        };
      };
    };

    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      # macOS: at login, export every secret registered in the login Keychain
      # and define the `set-secret` function (persist + apply to this shell).
      # We can't hand-edit ~/.zprofile (home-manager owns it as a read-only
      # store symlink), so the hook lives here. Login-shell scope (.zprofile).
      # Empty on non-darwin (see secretsKeychainInit in the let block).
      profileExtra = secretsKeychainInit;
    };

    # ---- VS Code (macOS only) --------------------------------------------------
    # GUI app; the shared profile also loads on headless NixOS hosts, so the
    # whole block is gated to darwin (like the ssh block above). Replicates the
    # devcontainer's editor: extensions via the nix-vscode-extensions Marketplace
    # mirror, plus the PORTABLE settings (container/workspace-specific paths are
    # omitted — see notes below).
    vscode = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      # Allow hand-installed / Settings-Sync extensions alongside the declared
      # ones — lower-maintenance than a fully locked extensions dir.
      mutableExtensionsDir = true;

      profiles.default = {
        # PERSONAL extensions only — the standing toolkit wanted in every repo,
        # resolved from the Marketplace mirror. Publisher/name are lowercased in
        # Nix per nix-vscode-extensions' convention. Project/stack-specific
        # extensions belong in each project's devcontainer / .vscode instead.
        extensions = with marketplace; [
          anthropic.claude-code # AI coding — every repo
          github.vscode-pull-request-github # PR review — every repo
          ms-azuretools.vscode-docker # Docker — general
          ms-azuretools.vscode-containers # containers/devcontainers — general
          shd101wyy.markdown-preview-enhanced # markdown — everywhere
          fuadpashayev.bottom-terminal # terminal-in-panel UI preference
          qvist.jetbrains-new-ui-dark-theme # the theme set in userSettings
        ];

        # Portable subset of the devcontainer settings block. OMITTED as
        # workspace/container-specific (would be wrong on the Mac):
        #   python.defaultInterpreterPath, ruff.interpreter, mypy-type-checker.path
        #     — all hardcode /workspaces/.../.venv/...; belong in per-project .vscode
        #   terminal.integrated.defaultProfile.linux + .profiles.linux
        #     — container paths (/usr/bin/zsh, /usr/local/.../claude, /usr/bin/psql)
        userSettings = {
          # -- Theme --
          "workbench.activityBar.iconSize" = "comp";
          "workbench.colorTheme" = "JetBrains New UI Dark Theme";
          "workbench.activityBar.compact" = true;
          "workbench.activityBar.iconClickBehavior" = "toggle";
          "workbench.editor.splitOnDragAndDrop" = false;
          "workbench.settings.alwaysShowAdvancedSettings" = true;
          "window.density.editorTabHeight" = "compact";
          "chat.agent.enabled" = false;
          # -- Terminal: Ubuntu 24 palette --
          "workbench.colorCustomizations" = {
            "terminal.background" = "#300A24";
            "terminal.foreground" = "#FFFFFF";
            "terminal.ansiBlack" = "#2E3436";
            "terminal.ansiRed" = "#CC0000";
            "terminal.ansiGreen" = "#4E9A06";
            "terminal.ansiYellow" = "#C4A000";
            "terminal.ansiBlue" = "#3465A4";
            "terminal.ansiMagenta" = "#75507B";
            "terminal.ansiCyan" = "#06989A";
            "terminal.ansiWhite" = "#D3D7CF";
            "terminal.ansiBrightBlack" = "#555753";
            "terminal.ansiBrightRed" = "#EF2929";
            "terminal.ansiBrightGreen" = "#8AE234";
            "terminal.ansiBrightYellow" = "#FCE94F";
            "terminal.ansiBrightBlue" = "#729FCF";
            "terminal.ansiBrightMagenta" = "#AD7FA8";
            "terminal.ansiBrightCyan" = "#34E2E2";
            "terminal.ansiBrightWhite" = "#EEEEEC";
            "statusBarItem.remoteForeground" = "#0c0a14";
            "statusBarItem.remoteBackground" = "#3e3657";
            "statusBarItem.remoteHoverBackground" = "#a98cf0";
          };
          "terminal.integrated.fontFamily" = "'UbuntuMono Nerd Font', 'Ubuntu Mono', monospace";
          "terminal.integrated.fontSize" = 16;
          "terminal.integrated.copyOnSelection" = true;
          "terminal.integrated.drawBoldTextInBrightColors" = true;
          "terminal.integrated.tabs.defaultColor" = "terminal.ansiMagenta";
          "terminal.integrated.tabs.defaultIcon" = "terminal-ubuntu";
          "terminal.integrated.persistentSessionReviveProcess" = "onExitAndWindowClose";
          # Personal "claude" terminal profile — one-click Claude Code with
          # permission prompts skipped. `.osx` (not `.linux`) because the whole
          # block is darwin-gated. `path` is the exact store path of the
          # claude-code derivation HM installs, so it resolves regardless of PATH.
          "terminal.integrated.profiles.osx" = {
            "claude" = {
              "path" = "${claudeCode}/bin/claude";
              "args" = [
                "--permission-mode"
                "bypassPermissions"
              ];
              "icon" = "claude";
              "color" = "terminal.ansiYellow";
            };
          };
          # -- Editor --
          # JetBrainsMono Nerd Font (pkgs.nerd-fonts.jetbrains-mono) — pairs with
          # the JetBrains New UI Dark theme; ligatures on. Terminal stays UbuntuMono.
          "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'JetBrains Mono', monospace";
          "editor.fontLigatures" = true;
          "editor.formatOnSave" = true;
          "editor.codeActionsOnSave" = {
            "source.organizeImports" = "explicit";
          };
          # NOTE: genuinely project-specific settings (python.*/[python]/mypy,
          # files.associations, git.defaultBranchName, and the files/search
          # exclude blocks for build artifacts) intentionally live in each
          # project's devcontainer / .vscode — NOT in this global personal
          # profile, where they would wrongly apply to every repo.
          # -- Claude Code (global prefs) --
          "claudeCode.allowDangerouslySkipPermissions" = true;
          "claudeCode.initialPermissionMode" = "bypassPermissions";
          # -- Git --
          "git.addAICoAuthor" = "off";
          "git.autofetch" = "all";
          "git.autoStash" = true;
          "git.enableCommitSigning" = true; # personal — uses your ~/.ssh signing key
          "git.branchProtectionPrompt" = "alwaysPrompt";
          "git.closeDiffOnOperation" = true;
          "git.detectWorktrees" = true;
          "git.fetchOnPull" = true;
          "git.mergeEditor" = true;
          "git.openAfterClone" = "always";
          "git.openRepositoryInParentFolders" = "always";
          "git.pullBeforeCheckout" = true;
          "git.rebaseWhenSync" = true;
          # -- GitHub (personal PR-review UI; merge POLICY like squash /
          # delete-branch is project-owned → lives in each repo's .vscode) --
          "github-actions.workflows.pinned.refresh.enabled" = true;
          "github-actions.workflows.pinned.refresh.interval" = 30;
          "githubPullRequests.defaultDeletionMethod.selectWorktree" = true;
          "githubPullRequests.fileListLayout" = "flat";
          "githubPullRequests.notifications" = "pullRequests";
          # -- Merge Conflict --
          "merge-conflict.autoNavigateNextConflict.enabled" = true;
          "merge-conflict.diffViewPosition" = "Beside";
          # -- Markdown preview (personal rendering pref; ext is in the set above) --
          "markdown-preview-enhanced.previewMode" = "Previews Only";
          "markdown-preview-enhanced.previewColorScheme" = "editorColorScheme";
          # -- Editor suggest UI (personal taste) --
          "editor.suggest.showStatusBar" = true;
        };
      };
    };
  };

  # ---- Terminal.app "Ubuntu" profile (macOS only) ---------------------------
  # Installs ./terminal/Ubuntu.terminal — an Ubuntu-GNOME-look profile whose
  # colors + font mirror the VS Code integrated-terminal palette above.
  #
  # Terminal.app OWNS com.apple.Terminal and rewrites it from memory while it is
  # running, so a plain `defaults write` gets clobbered. The reliable path is to
  # let the running Terminal import the profile itself via `open`, which persists.
  # Guarded on absence so it runs ONCE (first activation on a fresh Mac) — later
  # rebuilds are a no-op and never pop a window. Setting it as the default is
  # best-effort (again, Terminal may overwrite while running): if it doesn't
  # stick, select Ubuntu → "Default" in Terminal ▸ Settings ▸ Profiles once.
  home.activation = lib.mkIf pkgs.stdenv.isDarwin {
    ubuntuTerminalProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! /usr/bin/defaults read com.apple.Terminal "Window Settings" 2>/dev/null \
           | /usr/bin/grep -q 'name = Ubuntu;'; then
        $DRY_RUN_CMD /usr/bin/open ${./terminal/Ubuntu.terminal}
        $DRY_RUN_CMD /usr/bin/defaults write com.apple.Terminal \
          "Default Window Settings" -string "Ubuntu" || true
        $DRY_RUN_CMD /usr/bin/defaults write com.apple.Terminal \
          "Startup Window Settings" -string "Ubuntu" || true
      fi
    '';

    # Static desktop wallpaper (the DEFAULT): the vendored wallpaper.png
    # (./wallpaper/wallpaper.png, version-controlled → served from its immutable
    # /nix/store copy). macOS keeps the desktop picture in a sqlite db that
    # `defaults` can't reliably read/write, so drive it via System Events, which
    # sets it for every display. Re-run each activation (cheap, idempotent — it
    # just re-points at the same store path).
    setWallpaper = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD /usr/bin/osascript -e \
        'tell application "System Events" to tell every desktop to set picture to "${./wallpaper/wallpaper.png}"' || true
    '';

    # OPT-IN live wallpaper: point Plash (masApps, modules/darwin/homebrew.nix) at
    # the local live-wallpaper server (modules/darwin/core.nix). Plash stores its
    # site list in its OWN prefs (not a file we manage), so this is a one-time
    # GUI-scheme call guarded on absence — it configures Plash once, then is a
    # no-op. Plash is no longer launched at login (see modules/darwin/core.nix), so
    # the static wallpaper above wins by default; open Plash to use the live one.
    plashWallpaper = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! /usr/bin/defaults read com.sindresorhus.Plash websites 2>/dev/null \
           | /usr/bin/grep -q '127.0.0.1:${toString wallpaperPort}'; then
        $DRY_RUN_CMD /usr/bin/open -ga Plash || true
        $DRY_RUN_CMD /usr/bin/open "plash:add?url=http%3A%2F%2F127.0.0.1%3A${toString wallpaperPort}" || true
      fi
    '';
  };

}
