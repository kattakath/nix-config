# Unified user profile — loaded on EVERY machine (macOS, Pi, sandbox VM).
# The single home of "user logic"; system-level platform specifics live in
# modules/darwin and modules/nixos.
#
# Personal token VALUES are intentionally NOT managed here. On macOS they live
# in the login Keychain (encrypted at rest) — stored/registered by `set-secret`
# (packages/set-secret.nix) and exported into EVERY shell (not just login ones)
# by the darwin-only secret loader in the let block below (secretsLoaderBody),
# which loads once per process tree and lets descendants inherit. Nothing
# plaintext is written to disk. The Keychain is macOS-only, so the Linux hosts
# get no personal-token mechanism here (use one-time CLI logins: gh/hf/docker/claude).
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
  grok-build-plugin-cc,
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

  # Claude Code plugins to install from their Nix-pinned marketplaces (see the
  # programs.claude-code.marketplaces + settings.enabledPlugins below). SINGLE
  # SOURCE for both the enabledPlugins flags and the idempotent install activation
  # (home.activation.claudeCodePlugins). Each id is "<plugin>@<marketplace>"; adding
  # a plugin = pin its marketplace input + marketplaces entry, then append its id here.
  claudePluginIds = [ "grok-build@xai-grok-build" ];

  # `set-secret <KEY> [VALUE]` — stores a secret in the macOS login Keychain
  # (encrypted at rest) and registers it in an in-Keychain index. macOS-only.
  setSecret = pkgs.callPackage ../../packages/set-secret.nix { };
  # `remove-secret <KEY>` — the inverse: delete + unregister. Thin alias for
  # `set-secret --remove`; the logic lives once in setSecret. macOS-only.
  removeSecret = pkgs.callPackage ../../packages/remove-secret.nix { set-secret = setSecret; };
  # `secret <set|get|rm|ls|load>` — the primary noun-verb interface; set-secret
  # / remove-secret are its aliases. Forwards mutations to setSecret. macOS-only.
  secretCmd = pkgs.callPackage ../../packages/secret.nix { set-secret = setSecret; };

  # `mermaid-ascii` — render Mermaid graphs as ASCII in the terminal. Packaged from
  # upstream (not in nixpkgs); see packages/mermaid-ascii.nix.
  mermaidAscii = pkgs.callPackage ../../packages/mermaid-ascii.nix { };

  # `android-emu [avd-name] [emulator-args…]` — boot an Android emulator,
  # provisioning on first run. If the SDK packages or the AVD are missing it
  # installs them via the Homebrew `sdkmanager`/`avdmanager` (the
  # android-commandlinetools cask + ANDROID_HOME set below), then launches.
  # Uses a native arm64 system image (fast on Apple Silicon). macOS-only.
  #
  # The AVD name selects the system image: a name containing "play" — the DEFAULT
  # `pixel_play`, launched by a bare `android-emu` — gets the Google Play image (has
  # the Play Store, not rootable); any other name (e.g. `android-emu pixel`) gets
  # Google APIs (no Play Store, dev-friendly). Each AVD is created with a 64G data
  # partition (the `pixel` device default of 6G fills up fast).
  #
  # Launch defaults that make the emulator actually usable on Apple Silicon:
  #   -gpu swiftshader_indirect  software rendering; host-GPU emulation renders a
  #                              gray screen here, so we force software.
  #   -no-snapshot               always cold boot; a corrupt saved snapshot is
  #                              what makes the *second* launch hang on gray.
  # Both are also baked into each AVD's config.ini (alongside hw.keyboard=yes so
  # the Mac keyboard types into Android). Extra args after the name override the
  # emulator flags, so `android-emu pixel -gpu host` still works.
  androidEmu = pkgs.writeShellApplication {
    name = "android-emu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      ANDROID_HOME="''${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
      export ANDROID_HOME
      avd="''${1:-pixel_play}"
      sdkmanager="/opt/homebrew/bin/sdkmanager"
      avdmanager="/opt/homebrew/bin/avdmanager"
      emulator="$ANDROID_HOME/emulator/emulator"

      # Google Play image for *play* AVDs, Google APIs otherwise.
      case "$avd" in
        *play*) image="system-images;android-35;google_apis_playstore;arm64-v8a" ;;
        *)      image="system-images;android-35;google_apis;arm64-v8a" ;;
      esac

      if [ ! -x "$sdkmanager" ]; then
        echo "android-emu: sdkmanager not found — run 'darwin-rebuild switch' to install the android-commandlinetools cask" >&2
        exit 1
      fi

      # First run: accept licenses + install the emulator and platform-tools.
      if [ ! -x "$emulator" ]; then
        echo "android-emu: installing SDK packages (first run, a few GB)…" >&2
        yes | "$sdkmanager" --licenses >/dev/null || true
        "$sdkmanager" "platform-tools" "emulator"
      fi

      # Ensure the chosen system image is present (~1.5 GB per image).
      if [ ! -d "$ANDROID_HOME/''${image//;//}" ]; then
        echo "android-emu: downloading system image ($image)…" >&2
        yes | "$sdkmanager" --licenses >/dev/null || true
        "$sdkmanager" "$image"
      fi

      # Create the AVD on first use (decline the custom-hardware prompt), then
      # persist the settings that make it work: software GPU + hardware keyboard,
      # and PlayStore.enabled for play images.
      if ! "$avdmanager" list avd -c | grep -qx "$avd"; then
        echo "android-emu: creating AVD '$avd'…" >&2
        echo "no" | "$avdmanager" create avd -n "$avd" -k "$image" -d pixel

        cfg="$HOME/.android/avd/$avd.avd/config.ini"
        set_key() {
          if grep -q "^$1=" "$cfg"; then
            sed -i "s|^$1=.*|$1=$2|" "$cfg"
          else
            echo "$1=$2" >> "$cfg"
          fi
        }
        set_key hw.gpu.enabled yes
        set_key hw.gpu.mode swiftshader_indirect
        set_key hw.keyboard yes
        # Serious internal-storage bump: the `pixel` device profile defaults to a
        # cramped 6G data partition (fills up fast once the Play Store + a few apps
        # land). 64G is sparse (qcow2), so it costs real disk only as it fills.
        set_key disk.dataPartition.size 64G
        case "$avd" in *play*) set_key PlayStore.enabled yes ;; esac
      fi

      exec "$emulator" -avd "$avd" -no-snapshot -gpu swiftshader_indirect "''${@:2}"
    '';
  };

  # Keychain-backed secret store loader (macOS only).
  #
  # A REAL FILE (not just inline shell) sourced by EVERY shell — zsh via
  # .zshenv/envExtra, bash via profile + .bashrc, and non-interactive bash via
  # $BASH_ENV (its ONLY startup hook, which must name a file). This is the fix
  # for the login-only bug: profileExtra rendered into ~/.zprofile / ~/.bash_profile,
  # which are sourced for LOGIN shells only, so every non-login shell (Claude
  # Code's Bash tool, `zsh -c` from scripts/Makefiles, VS Code tasks, launchd,
  # direnv, docker exec, CI runners…) silently got ZERO secrets.
  #
  # Two jobs:
  #   1. Load every registered secret from the login Keychain into the
  #      environment — but AT MOST ONCE per process tree. Reading the Keychain
  #      costs ~31ms per secret (~470ms for the full set), so the first shell in
  #      a tree reads it and exports each value PLUS a dedicated sentinel
  #      (__SECRETS_KEYCHAIN_LOADED); every descendant inherits both through the
  #      environment and short-circuits on the sentinel. The cost is paid once at
  #      the tree root, never per shell.
  #   2. Define `set-secret` (persist via the binary AND apply to THIS shell — a
  #      bare binary can't touch its parent's env) and a `secret <NAME>` lazy
  #      read-only accessor. Both are defined UNCONDITIONALLY (shell functions
  #      are not inherited across processes) but touch the Keychain only when
  #      actually called, so they add nothing to startup.
  #
  # Diagnostics: SECRETS_DEBUG=1 emits a stderr report of what loaded / what
  # failed — NAMES, lengths and exit codes only, never values. Quiet by default.
  # Unlike the old __HM_ZSH_SESS_VARS_SOURCED (set to 1 and inherited even when
  # zero secrets loaded — the exact misleading signal that made this bug hard to
  # diagnose), the sentinel here is set ONLY after the index was actually read;
  # an unreadable index (locked Keychain) leaves the tree un-cached so a later
  # shell retries instead of inheriting an empty, "already-loaded" environment.
  secretsLoaderRelPath = ".config/secrets/loader.sh";
  secretsLoaderPath = "${config.home.homeDirectory}/${secretsLoaderRelPath}";
  secretsLoaderBody = ''
    # -- one-time-per-tree Keychain load ------------------------------------
    if [ -z "''${__SECRETS_KEYCHAIN_LOADED:-}" ]; then
      __ss_dbg() {
        if [ -n "''${SECRETS_DEBUG:-}" ]; then printf 'secrets: %s\n' "$1" >&2; fi
        return 0
      }
      __ss_account="$(/usr/bin/id -un)"
      # Capture the index read's exit code: rc != 0 means the index item is
      # UNREADABLE (Keychain locked, or nothing registered yet) — distinct from a
      # readable-but-empty index. Only a readable index sets the sentinel.
      __ss_index="$(/usr/bin/security find-generic-password -a "$__ss_account" -s __set_secret_index__ -w 2>/dev/null)"
      __ss_rc=$?
      if [ "$__ss_rc" -ne 0 ]; then
        __ss_dbg "index unreadable (rc=$__ss_rc): Keychain locked or no secrets registered; NOT caching — a later shell will retry"
      else
        __ss_loaded=0
        __ss_failed=0
        # Peel the SPACE-separated index one token at a time with POSIX parameter
        # expansion — identical in zsh and bash (a `for k in $index` would NOT
        # word-split in zsh). No subshell, so exports land in THIS shell.
        __ss_rest="$__ss_index"
        while [ -n "$__ss_rest" ]; do
          __ss_k="''${__ss_rest%% *}" # first token
          __ss_rest="''${__ss_rest#"$__ss_k"}" # drop it
          __ss_rest="''${__ss_rest# }" # trim one leading space
          [ -n "$__ss_k" ] || continue
          if __ss_v="$(/usr/bin/security find-generic-password -a "$__ss_account" -s "$__ss_k" -w 2>/dev/null)"; then
            export "$__ss_k=$__ss_v"
            __ss_loaded=$((__ss_loaded + 1))
            __ss_dbg "loaded $__ss_k (len=''${#__ss_v})"
          else
            __ss_failed=$((__ss_failed + 1))
            __ss_dbg "MISSING $__ss_k (listed in index but not found in Keychain)"
          fi
        done
        # Sentinel = "index consulted, every listed secret attempted". Set on a
        # readable index even if empty (nothing to load is a valid loaded state)
        # and EXPORTED so descendants skip this whole block.
        #
        # CAVEAT (by design): the sentinel is per-secret-set, not per-secret. If a
        # child shell drops a single var (`unset FOO`, or is spawned with
        # `env -u FOO`), this loader will NOT restore it — the inherited sentinel
        # short-circuits the whole block. To get FOO back, either open a shell
        # without the sentinel, or force a reload in place:
        #   unset __SECRETS_KEYCHAIN_LOADED && source ~/.config/secrets/loader.sh
        # (a fresh login shell / new process tree always reloads from scratch).
        export __SECRETS_KEYCHAIN_LOADED=1
        # Non-interactive bash's only startup hook is $BASH_ENV — propagate it so
        # bash descendants of this (possibly zsh) shell also self-load / short-circuit.
        export BASH_ENV="${secretsLoaderPath}"
        __ss_dbg "done: $__ss_loaded loaded, $__ss_failed missing (sentinel set)"
        unset __ss_loaded __ss_failed
      fi
      unset __ss_account __ss_index __ss_rc __ss_rest __ss_k __ss_v
      unset -f __ss_dbg 2>/dev/null || true
    fi

    # -- interactive helpers (defined always; touch the Keychain only if called) --
    # Persist to (or remove from) the Keychain, then apply the change to THIS
    # shell right away (a bare binary can't mutate its parent's env): an add
    # re-exports the value, a --remove unsets it here too.
    set-secret() {
      command set-secret "$@" || return
      case "''${1:-}" in
        --remove | -r)
          case "''${2:-}" in
            [A-Za-z_]*) unset "$2" 2>/dev/null || true ;;
          esac
          ;;
        [A-Za-z_]*)
          export "$1=$(/usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s "$1" -w 2>/dev/null)"
          ;;
      esac
    }
    # Inverse of set-secret: delete + unregister, and unset it from THIS shell.
    # Delegates to the set-secret function so the --remove/unset path is shared.
    remove-secret() {
      set-secret --remove "$@"
    }
    # Primary noun-verb interface: `secret <set|get|rm|ls|load|KEY>`. The
    # mutating verbs update THIS shell (set→export, rm→unset) by delegating to the
    # set-secret/remove-secret functions above; `load` re-reads the whole store
    # into the current shell (the fix for a manually-unset var — see the sentinel
    # caveat above); get/ls/help fall through to the `secret` binary. A bare
    # `secret KEY` is shorthand for `secret get KEY`.
    secret() {
      case "''${1:-}" in
        set)
          shift
          set-secret "$@"
          ;;
        rm | remove | unset)
          shift
          remove-secret "$@"
          ;;
        load)
          unset __SECRETS_KEYCHAIN_LOADED
          [ -r "${secretsLoaderPath}" ] && . "${secretsLoaderPath}" || true
          ;;
        get | ls | list | -h | --help | "")
          command secret "$@"
          ;;
        *)
          command secret get "$1"
          ;;
      esac
    }
  '';
  # Source line wired into each shell's startup file (macOS only; empty elsewhere).
  sourceSecretsLoader = lib.optionalString pkgs.stdenv.isDarwin ''
    [ -r "${secretsLoaderPath}" ] && . "${secretsLoaderPath}" || true
  '';
in
{
  imports = [
    ./mcp.nix # darwin-gated MCP server registry for Claude Code
    ./photogimp.nix # darwin-gated Photoshop-like GIMP profile patch
    ./postgres-pgvector.nix # darwin-gated local Postgres + pgvector (backs the `postgres` MCP server)
    ./ollama.nix # darwin-gated local Ollama (embedding runtime for the RAG stack)
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
    # set-secret / remove-secret: Keychain-backed secret writer + its inverse,
    # macOS-only (see the let block). On PATH so the shell functions can call the
    # underlying `command set-secret` / `command remove-secret`.
    ++ lib.optionals stdenv.isDarwin [
      setSecret
      removeSecret
      secretCmd
      androidEmu
      mermaidAscii # render Mermaid graphs as ASCII in the terminal (packages/mermaid-ascii.nix)
      jdk17 # JRE for the Android sdkmanager/avdmanager (JVM tools); emulator itself needs no Java
      runpodctl # RunPod GPU CLI — RunPod as a second ComfyUI-workflow provider alongside Vast (from nixpkgs, not the untrusted brew tap)
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
    # sdkmanager/avdmanager are JVM tools; point them at the nixpkgs JDK 17.
    JAVA_HOME = pkgs.jdk17.home;
    # Point non-interactive bash at the secret loader — $BASH_ENV is the ONLY
    # startup hook such a shell reads. Sourced by login shells (which export it),
    # so bash descendants of a login tree self-load; the loader re-exports it too.
    BASH_ENV = secretsLoaderPath;
  };

  # Install the Keychain secret loader (macOS only). Sourced by every shell via
  # the zsh envExtra / bash profile+bashrc / $BASH_ENV wiring below; loads at
  # most once per process tree. See secretsLoaderBody in the let block.
  home.file = lib.mkIf pkgs.stdenv.isDarwin {
    ${secretsLoaderRelPath}.text = secretsLoaderBody;
  };
  home.sessionPath = lib.optionals pkgs.stdenv.isDarwin [
    "/opt/homebrew/share/android-commandlinetools/emulator"
    "/opt/homebrew/share/android-commandlinetools/platform-tools"
    # xAI Grok CLI: a self-updating prebuilt binary installed to ~/.grok/bin by
    # `curl -fsSL https://x.ai/cli/install.sh | bash` (no nixpkgs/brew package
    # exists, and `grok` updates itself, so pinning it in Nix would fight its
    # updater). It lives outside the Nix store and /opt/homebrew, so Homebrew's
    # cleanup="uninstall" never touches it; this line is the declarative PATH
    # entry (the source of truth over the installer's own ~/.zshrc edit).
    "$HOME/.grok/bin"
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

      # xAI's OFFICIAL Grok Build <-> Claude Code bridge, registered as a pinned
      # MARKETPLACE (the flake-input repo root has .claude-plugin/marketplace.json).
      # NOT the `plugins` option: on this claude-code (>= 2.1.157) that installs a
      # "skills-dir plugin", which loads only the plugin's skills+hooks — NOT its
      # slash commands or agent (verified live: `/grok-build:check` => "Unknown
      # command", `plugin details` => Agents (0), no commands). The marketplace
      # source is the pinned flake input, so `nix flake update` bumps it and the
      # store path stays GC-protected. The plugin is then activated ONCE per machine
      # with `claude plugin install grok-build@xai-grok-build` — persisted user state
      # in ~/.claude (like the gh/hf/docker/claude one-time logins) — which DOES load
      # the full /grok-build:{review,critique,delegate,import,check,runs,show,stop}
      # commands + the grok-delegate agent. Runtime deps: grok on PATH (~/.grok/bin)
      # + Node; grok must be authenticated (`grok models` succeeds).
      marketplaces.xai-grok-build = "${grok-build-plugin-cc}";

      # Claude Code user settings, now Nix-owned (the marketplaces option above
      # takes over ~/.claude/settings.json wholesale, so everything must live here
      # or it is lost on activation). extraKnownMarketplaces is injected by the
      # marketplaces option; the module writes settings.json = these `settings` //
      # { extraKnownMarketplaces }. enabledPlugins keeps the grok-build plugin
      # switched ON once `claude plugin install grok-build@xai-grok-build` has run.
      # NOTE: editing any of these in the Claude UI won't persist — a rebuild
      # reverts them; change them HERE instead.
      settings = {
        theme = "auto";
        tui = "fullscreen";
        skipDangerousModePermissionPrompt = true;
        skipWorkflowUsageWarning = true;
        inputNeededNotifEnabled = true;
        agentPushNotifEnabled = true;
        enabledPlugins = lib.genAttrs claudePluginIds (_: true);
      };

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
        # Personal: a thin GLOBAL pointer to the Brags personal-branding review flow whose
        # authoritative SKILL.md + engine live in the private ~/Documents/brags repo (so it
        # tracks that repo, and the heavy logic isn't vendored here). Makes "run my brags
        # review" invocable by name in any Claude Code / Claude Desktop session.
        brags-review = "${../../skills/brags-review}";
        # Local RAG over the pgvector store: how to ingest + query via the `postgres`
        # MCP server and the in-DB embed() function (modules/shared/{postgres-pgvector,ollama}.nix).
        rag = "${../../skills/rag}";
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

      # Per-directory identity, keyed on the ~/Developer/<host>/<owner>/ layout.
      # Any repo under the Infin8 client org's path uses the work identity instead
      # of the personal default above, so client commits never carry the personal
      # email/key by accident. The work email itself is NOT committed to this public
      # repo — it lives in ~/.config/git/infin8.inc (a plain, git-ignored-by-location
      # file the operator fills). Git silently ignores the include if that file is
      # absent or comment-only, so the fallback is simply the personal default.
      includes = [
        {
          condition = "gitdir:~/Developer/github.com/Infin8-Information-Technologies/";
          path = "~/.config/git/infin8.inc";
        }
      ];
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
      # macOS: source the Keychain secret loader on bash too. Three hooks, since
      # bash has no single .zshenv equivalent — profileExtra (.bash_profile,
      # LOGIN) + bashrcExtra (.bashrc, INTERACTIVE non-login); NON-interactive
      # non-login bash is reached only via $BASH_ENV (set in home.sessionVariables
      # above and re-exported by the loader). The sentinel makes multi-source
      # idempotent. Empty on non-darwin (sourceSecretsLoader in the let block).
      profileExtra = sourceSecretsLoader;
      bashrcExtra = sourceSecretsLoader;
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

      # macOS: source the Keychain secret loader from .zshenv (envExtra), which
      # runs for EVERY zsh — login, non-login, interactive or not — so scripts
      # and `zsh -c` subshells get the secrets too (the old profileExtra →
      # .zprofile path fired for LOGIN shells only). The loader is sentinel-
      # guarded, so only the first shell in a process tree pays the Keychain read;
      # descendants inherit and short-circuit. Empty on non-darwin.
      envExtra = sourceSecretsLoader;
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
    # Materialise the DECLARED Claude Code plugins (claudePluginIds) from their
    # Nix-pinned marketplaces. We deliberately do NOT put ~/.claude/plugins/
    # installed_plugins.json under Nix — it is Claude's own MUTABLE state file whose
    # schema + cache layout are an internal impl detail (making it read-only would break
    # `claude plugin install/uninstall/update`). Instead we DELEGATE the install to
    # `claude plugin install`, idempotently — the same "let the tool author its own
    # state" pattern as home.activation.grokMcp / claudeDesktopMcp (modules/shared/mcp.nix).
    # Runs AFTER linkGeneration so the Nix-managed known_marketplaces.json + settings.json
    # (which already carries enabledPlugins = true) are in place; best-effort so it never
    # aborts a switch and self-heals on the next one. This is the one manual
    # `claude plugin install` step, automated (verified: install succeeds even though
    # settings.json is a read-only Nix symlink, since enabledPlugins is already set).
    claudeCodePlugins = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      claude="${claudeCode}/bin/claude"
      if [ -x "$claude" ]; then
        for id in ${lib.escapeShellArgs claudePluginIds}; do
          if "$claude" plugin list 2>/dev/null | grep -qF "$id"; then
            : # already installed — idempotent skip
          else
            echo "claude-code: installing plugin $id from its pinned marketplace…" >&2
            "$claude" plugin install "$id" >/dev/null 2>&1 || true
          fi
        done
      fi
    '';

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
