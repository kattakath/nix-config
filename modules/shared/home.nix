# Unified user profile — loaded on EVERY machine (macOS, Ubuntu, Pi, container).
# This is the single home of "user logic". Nothing platform-specific belongs here;
# platform branches live in modules/linux and modules/darwin.
# Personal tokens are intentionally NOT managed here. agenix was dropped for
# user secrets (each rotation = a committed .age = version-control churn). On
# macOS the raw env-var tokens live in the login Keychain, exported by the
# host-local ~/.zprofile; login-style tokens use one-time CLI logins
# (gh/hf/docker/claude). agenix now covers only system/cloudflared host secrets.
# See secrets/README.
#
# Deliberately MINIMAL: editor/multiplexer/prompt niceties (nixvim, tmux,
# starship, …) are intentionally NOT managed here — the operator uses VSCode/
# Cursor and prefers a lean, low-noise profile. Add tools only when there's a
# clear cross-host need.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  # VS Code Marketplace mirror — provided by the nix-vscode-extensions overlay,
  # which the darwin host (nixcon) adds to nixpkgs.overlays. Only referenced
  # inside the `mkIf isDarwin` vscode block, so the Linux hosts (which don't
  # apply the overlay) never touch it. CRUCIAL: reading the overlay attr off
  # `pkgs` (rather than the flake input's `.extensions.<sys>` output) means the
  # extensions are built against OUR nixpkgs and so respect the host's
  # `nixpkgs.config.allowUnfree` — the input's `.extensions` output uses its own
  # nixpkgs with default config and ignores our unfree allowance.
  marketplace = pkgs.vscode-marketplace or null;
in
{
  imports = [ ../linux/nix-ld.nix ];

  # Make Home-Manager-installed font packages discoverable by applications.
  # Essential on Linux (registers fonts with fontconfig); harmless no-op on macOS.
  fonts.fontconfig.enable = true;

  # PERSONAL, cross-host packages only. This profile holds tools wanted on
  # EVERY machine regardless of project — NOT project toolchains.
  #
  # Project toolchains (aws-cdk, awscli, node, uv, make, psql, …) now live in
  # each repo's own root `flake.nix` devShell, entered with `nix develop` — the
  # same flake works on these nix machines and inside that repo's devcontainer
  # (the `nix:1` feature). So the earlier "mirror a project devcontainer's
  # features here" set was REMOVED: a tool needed only inside a project belongs
  # to that project's flake, not to the global home profile. (If a project CLI
  # is ever wanted machine-wide outside any repo, add it back here as a
  # deliberate personal choice.)
  #
  # gh / git-lfs stay out of this list on purpose — they come from their
  # dedicated `programs.*` modules below (listing them here too would cause a
  # buildEnv /bin collision).
  #
  # `claude-code` is the one CLI kept here: it is genuinely personal and used in
  # every repo, not bound to any one project. Verified attr (nixpkgs unstable):
  # `claude-code`.
  #
  # Fonts: only the two actually wired to a setting are kept (cross-host: macOS
  # + NixOS + devcontainers). nixpkgs unstable uses the per-font
  # `nerd-fonts.<name>` attrs (the 24.05+ restructure; lowercase-hyphenated
  # names) — NOT the old `(nerdfonts.override { fonts = ...; })`. The other
  # Homebrew font casks (fira-code, hack, ubuntu, roboto) were dropped as unused
  # — add one back here if you select it in an app's font picker.
  home.packages = with pkgs; [
    # personal CLI — used in every repo, not project-bound
    claude-code
    # fonts (each is referenced by a VS Code font setting below)
    nerd-fonts.jetbrains-mono # "JetBrainsMono Nerd Font" — VS Code editor font (pairs with the JetBrains theme)
    nerd-fonts.ubuntu-mono # "UbuntuMono Nerd Font" — VS Code terminal font (matches the devcontainer)
  ];

  # ---- Home Manager program modules --------------------------------------------
  programs = {
    # Let Home Manager manage itself.
    home-manager.enable = true;

    git = {
      enable = true;
      lfs.enable = true; # git-lfs, wired into git config (devcontainer feature)
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

    # GitHub CLI (`gh`) — devcontainer github-cli feature.
    gh.enable = true;

    # A login shell is required for `home-manager switch` to wire session vars.
    bash = {
      enable = true;
    };

    # zsh as the interactive shell — matches the devcontainer default
    # (common-utils configureZshAsDefaultShell). Kept lean: no oh-my-zsh /
    # framework, default prompt. bash stays enabled above for login-shell
    # compatibility.
    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
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
        # resolved from the Marketplace mirror (covers MS-proprietary + the
        # JetBrains theme). Publisher/name are lowercased in Nix per
        # nix-vscode-extensions' convention.
        #
        # Project/stack-specific extensions are intentionally NOT here — they
        # belong to each project's devcontainer / .vscode extensions list, so
        # they install only where that stack is used (matches the settings
        # split). A stack-specific devcontainer might add, e.g.:
        #   charliermarsh.ruff, ms-python.mypy-type-checker,
        #   amazonwebservices.aws-toolkit-vscode, stripe.vscode-stripe,
        #   ric-v.postgres-explorer, lfm.vscode-makefile-term,
        #   github.vscode-github-actions, bruno-api-client.bruno
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
          # Personal "claude" terminal profile — a one-click Claude Code session
          # with permission prompts skipped (mirrors claudeCode.* prefs below).
          # `.osx` (not `.linux`): this whole block is darwin-gated, so it must
          # target the macOS host. `path` points at the exact `claude-code`
          # derivation HM installs (same store-path style as the cloudflared
          # ssh proxyCommand above) — robust against PATH ordering, no reliance
          # on home.packages being on PATH. It's a personal choice, not project
          # config — the devcontainer's bare `claude` path became this.
          "terminal.integrated.profiles.osx" = {
            "claude" = {
              "path" = "${pkgs.claude-code}/bin/claude";
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
}
