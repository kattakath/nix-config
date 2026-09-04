# Unified user profile — loaded on EVERY machine (macOS, Pi, sandbox VM).
# The single home of "user logic"; system-level platform specifics live in
# modules/darwin and modules/nixos.
#
# Personal token VALUES are intentionally NOT managed here. On macOS they live
# in the login Keychain (encrypted at rest) — stored/registered by `secret set`
# and exported into EVERY shell (not just login ones) by the darwin-only loader
# from the keychain-secrets flake (programs.keychainSecrets), which loads once per
# process tree and lets descendants inherit. Nothing plaintext is written to disk.
# The Keychain is macOS-only, so the Linux hosts get no personal-token mechanism
# here (use one-time CLI logins: gh/hf/docker/claude).
#
# SYSTEM/SERVICE secrets are separate from this profile — two agenix ciphertexts on
# two models: nixpi's Cloudflare tunnel token (secrets/cloudflared-token.age) is an
# operator-only vault (encrypted to the operator's key alone, decrypted on the Mac,
# planted on the FAT FIRMWARE partition → /run/cloudflared-token) precisely BECAUSE
# host-decryption would bind it to the SSH host key a fresh SD flash rotates (see
# hosts/nixpi.nix); the macos runner's GitHub App key (gh-app-dontsell-ai-key.age)
# IS host-decrypted into /run/agenix at activation — macos's host key is stable.
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
  # The fleet's DNS zone (identityArgs in flake.nix). Used to build nixpi's
  # tunnelled SSH hostname below, so the domain is never re-typed.
  domainName,
  # Fleet operator ed25519 PUBLIC key (secrets/operator-key.nix) — single source
  # for authorizedKeys + agenix recipient + git SSH allowed_signers principal.
  operatorSshKey,
  # Source-only flake inputs holding Claude Code skills (see programs.claude-code
  # below). flake.nix pins them; nothing is vendored into this repo.
  agent-skills-vercel,
  agent-skills-anthropic,
  agent-skills-cloudflare,
  agent-skills-anthropic-official,
  agent-skills-jeffallan,
  agent-skills-mac-automation,
  agent-skills-excalidraw,
  agent-skills-trailofbits,
  agent-skills-superpowers,
  agent-skills-jsonresume,
  agent-skills-vercel-agent,
  agent-skills-vercel-workflow,
  agent-skills-litellm,
  grok-build-plugin-cc,
  # The extracted local-rag flake (services.ollamaLocal + services.pgvectorLocal);
  # its two home-manager modules replace the vendored ollama/postgres-pgvector.
  local-rag,
  # The extracted keychain-secrets flake (macOS `secret` CLI + every-shell loader);
  # its home-manager module replaces the vendored packages/loader below.
  keychain-secrets,
  # Raw resume.json URL (single-sourced in flake.nix as jsonResumeUrl; null to
  # disable) — baked into the jsonresume package below as its default --url.
  jsonResumeUrl,
  logoUrl,
  tokensUrl,
  # nix-darwin system config when this profile is embedded via
  # home-manager.darwinModules (absent on pure NixOS HM / standalone).
  osConfig ? { },
  ...
}:
let
  # Real client Mac vs Tart sandbox (hosts/*/networking.hostName). Used to keep
  # heavy darwin-only agents (RAG stack, MCP public tunnel extras) off macvm.
  isMacosHost = (osConfig.networking.hostName or "") == "macos";

  # android-commandlinetools Homebrew cask install prefix — single source for
  # every ANDROID_HOME/PATH reference below (also read from modules/shared/mcp.nix
  # via config.home.sessionVariables.ANDROID_HOME, not re-declared there).
  androidSdkRoot = "/opt/homebrew/share/android-commandlinetools";

  # Qwen Code (`qwen`) MCP wiring — reuse the SAME localhost gateway Claude Code
  # uses (services.mcpGateway.endpoints: one Streamable-HTTP /mcp URL per hosted
  # server), so qwen can never drift from the other clients. But CURATE to a
  # coding-focused subset: a local qwen3-coder model degrades when handed too many
  # tools, so the GUI/automation/external-state servers (mobile-mcp,
  # macos-automator, cloudflare*) are left out — add a name here to
  # expose more. macos-only (the gateway runs only there; macvm trims it off), so
  # the mcpServers block is gated on isMacosHost below.
  qwenGatewayServers = [
    "context7"
    "fetch"
    "memory"
    "sequential-thinking"
    "github"
    "nixos"
    "terraform"
    "duckduckgo"
    "json-yaml-toml"
    "mcp-jq"
    "postgres"
  ];
  qwenMcpServers =
    lib.mapAttrs
      (_: url: {
        httpUrl = url;
        timeout = 8000;
      })
      (lib.filterAttrs (n: _: builtins.elem n qwenGatewayServers) config.services.mcpGateway.endpoints);

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
  claudePluginIds = [
    "grok-build@xai-grok-build"
    # Anthropic first-party security-review plugin (hook-driven): PostToolUse secret/injection
    # warnings + a Stop-hook LLM diff review. Its marketplace is claude-plugins-official (below);
    # the plugin's code is in-repo (source "./plugins/security-guidance"), so it is fully pinned.
    "security-guidance@claude-plugins-official"
    # Neon DB: neon-postgres skill + Neon MCP server (from claude-plugins-official →
    # neondatabase/agent-skills plugins/neon-postgres). Needs neonctl on PATH (macos brew).
    "neon@claude-plugins-official"
    # Stripe OFFICIAL plugin (git-subdir of stripe/ai providers/claude/plugin, pinned by the
    # marketplace sha): the full Stripe agent kit in one unit — 7 skills (stripe-best-practices,
    # stripe-docs, upgrade-stripe, connect-recommend, stripe-apps, stripe-directory,
    # stripe-projects), the company-researcher agent, /explain-error + /test-cards commands,
    # AND the hosted mcp.stripe.com MCP server (type=http; one-time in-client OAuth — no API
    # key handled here, and nothing to host in the gateway since the server is Stripe-remote).
    # Pairs with the nixpkgs `stripe-cli` in home.packages below.
    "stripe@claude-plugins-official"
    # Anthropic first-party frontend-design skill/plugin (UI/UX generation guidance).
    "frontend-design@claude-plugins-official"
    # Resend's OFFICIAL plugin (resend.com/mcp / resend.com/docs/mcp-server): bundles the
    # resend-cli skill + the hosted mcp.resend.com MCP server (Streamable HTTP, one-time
    # in-client OAuth via `/mcp` -> select resend — same shape as the stripe entry above; no
    # API key handled by this plugin). Pairs with the `resend` CLI package (home.packages
    # below), which instead authenticates non-interactively via RESEND_API_KEY from the
    # Keychain — the two are independent auth paths to the same Resend account (used by
    # dontsell-ai/app's outbound/inbound email).
    "resend@claude-plugins-official"
    # IN-REPO (plugins/llmstxt, this repo, via the localPluginsMarketplace source path below):
    # authoring skill + /llmstxt command + a stdlib-only linter for llms.txt — the llmstxt.org
    # v2 standard for LLM-friendly content. Nothing upstream AUTHORS these files (the ecosystem
    # is site-build generators + consumers/parsers), and nixpkgs carries only the Sphinx build
    # plugin (python3Packages.sphinx-llms-txt) — see plugins/llmstxt/README.md for the
    # reuse-vs-build reasoning, including why the linter is dependency-free stdlib.
    "llmstxt@${localMarketplaceName}"
    # IN-REPO (plugins/seargraph, this repo): the seargraph-langgraph subagent —
    # LangGraph pipeline design/implementation help for the SEARGraph project
    # (self-evolving agentic image restoration: fidelity metrics, constrained
    # optimization, iterative refinement, character embeddings). Global via this
    # plugin because plain skills vendoring (programs.claude-code.skills) has no
    # agents/ capability — only a plugin does.
    "seargraph@${localMarketplaceName}"
  ];

  # The marketplace this repo serves ITSELF, from the top-level plugins/ directory: a Nix
  # SOURCE PATH (store copy), not a flake input or a third-party marketplace, so an in-repo
  # plugin is pinned by construction and cannot drift. Its store path CHANGES whenever any
  # plugin content changes, which is exactly what home.activation.claudeCodePlugins keys the
  # re-pin off. Adding an in-repo plugin = a plugins/<name>/ tree + an entry in
  # plugins/.claude-plugin/marketplace.json + its id in claudePluginIds above.
  localMarketplaceName = "kattakath-nix-config";
  localPluginsMarketplace = "${../../plugins}";
  localPluginIds = builtins.filter (lib.hasSuffix "@${localMarketplaceName}") claudePluginIds;

  # ---- grok-build: repoint its hardcoded `read-only` sandbox at a profile that can start ----
  # xAI's bridge hardcodes `--sandbox read-only` for every non-write run (delegate/review/
  # critique). grok >=1.0.13's `read-only` AND `strict` profiles kernel-deny the container
  # runtime sockets and REFUSE TO START when a deny path has a symlink component — and Docker
  # Desktop installs /run/docker.sock as a symlink into $HOME/.docker/run/. Net effect: every
  # read-only grok-build run died in ~50ms with "runtime-socket deny resolution failed: could
  # not resolve runtime-socket deny path /run/docker.sock: endpoint is a symlink".
  # Only the `workspace`/`devbox` bases skip that deny, and a custom profile may NOT reuse a
  # built-in name, so the bridge must be pointed at a profile of ours.
  #
  # TRADE-OFF, stated plainly: `workspace` leaves the CWD writable, so the kernel no longer
  # backstops "the agent cannot edit the repo" — only the bridge's own `--permission-mode plan`
  # does. `read_only` cannot claw that back: it does NOT override the base's CWD write grant
  # (verified with a canary `touch`, which succeeded). So the profile leans on a
  # kernel-enforced `deny` list for the paths that actually matter. Retire this patch once xAI
  # resolves symlinked runtime-socket deny paths instead of refusing to start.
  grokSandboxProfile = "nix-agent-workspace";
  grokBuildPluginPatched = pkgs.runCommand "grok-build-plugin-cc-patched" { } ''
    cp -r ${grok-build-plugin-cc} $out
    chmod -R u+w $out
    substituteInPlace $out/plugins/grok-build/scripts/grok-bridge.mjs \
      --replace-fail 'sandbox: "read-only",' \
                     'sandbox: "${grokSandboxProfile}",' \
      --replace-fail 'sandbox: write ? undefined : "read-only",' \
                     'sandbox: write ? undefined : "${grokSandboxProfile}",'
  '';

  # Absolute operator SSH paths under $HOME. Git treats a non-absolute
  # gpg.ssh.allowedSignersFile as worktree-relative (would look in <repo>/.ssh/).
  sshDir = "${config.home.homeDirectory}/.ssh";
  operatorPrivateKey = "${sshDir}/id_ed25519";
  operatorPublicKey = "${sshDir}/id_ed25519.pub";
  allowedSignersFile = "${sshDir}/allowed_signers";

  # Shared by bash/zsh interactive init (GUI apps use launchd.agents.ssh-keychain-load).
  sshKeychainLoadShell = ''
    if command -v ssh-add >/dev/null 2>&1 && ! ssh-add -l >/dev/null 2>&1; then
      ssh-add --apple-load-keychain 2>/dev/null || true
    fi
  '';

  # `mermaid-ascii` — render Mermaid graphs as ASCII in the terminal. Packaged from
  # upstream (not in nixpkgs); see packages/mermaid-ascii.nix.
  mermaidAscii = pkgs.callPackage ../../packages/mermaid-ascii.nix { };
  vpn = pkgs.callPackage ../../packages/vpn.nix { };
  androidPhone = pkgs.callPackage ../../packages/android-phone.nix { };

  # `jsonresume <download|print>` — fetch a JSON Resume and render it to PDF via the
  # npm resume CLI. jsonResumeUrl (from flake.nix) is baked in as its default --url,
  # so there is no ambient env var. See packages/jsonresume.nix.
  jsonresume = pkgs.callPackage ../../packages/jsonresume.nix {
    defaultUrl = jsonResumeUrl;
  };

  # `email-signature` — render a paste-ready HTML email signature from the same JSON Resume
  # (jsonResumeUrl baked as its default --url) plus the logo.svg fetched from the same gist
  # (logoUrl), rasterized via librsvg. Also run on activation (home.activation.emailSignature)
  # and `nix run .#email-signature`. See packages/email-signature/ (default.nix).
  email-signature = pkgs.callPackage ../../packages/email-signature {
    defaultUrl = jsonResumeUrl;
    inherit logoUrl tokensUrl;
  };

  # `design-tokens` — transform the same gist tokens.json (tokensUrl) into SCSS/CSS/JS via
  # Style Dictionary, so the website / component library build from one source of truth.
  # `nix run .#design-tokens`. See packages/design-tokens/ (default.nix).
  design-tokens = pkgs.callPackage ../../packages/design-tokens {
    inherit tokensUrl;
  };

  # `jobspy --search "…" --location "…"` — scrape jobs from multiple boards into
  # CSV/JSON via the off-the-shelf python-jobspy library (run in an ephemeral uv env).
  # See packages/jobspy.nix.
  jobspy = pkgs.callPackage ../../packages/jobspy.nix { };

  # `fidelity-enhance-mcp` / `fidelity-enhance` — referee for an agentic
  # image-editing loop: Grok Imagine generates, this judges each result against
  # the original and says retry / next-step / done plus how to fix the prompt.
  # Run in an ephemeral uv env, same model as jobspy above.
  # See packages/fidelity-enhance.nix.
  fidelityEnhance = pkgs.callPackage ../../packages/fidelity-enhance.nix { };

  # `obs-fb-setup` — write an OBS "Facebook" profile for Facebook Live, injecting
  # FB_PERSISTENT_STREAM_KEY from the login Keychain at run time. See packages/obs-fb-setup.nix.
  obs-fb-setup = pkgs.callPackage ../../packages/obs-fb-setup.nix { };

  # `resend` — the official Resend CLI, injecting RESEND_API_KEY from the login Keychain
  # at run time (non-interactive, no browser OAuth). Pairs with the
  # resend@claude-plugins-official plugin (claudePluginIds below). See packages/resend-cli.nix.
  resendCli = pkgs.callPackage ../../packages/resend-cli.nix { };

  # `fix-google-video <file>...` + `extract-audio [--mp3|--wav|--flac] <file>...`
  # as one unit — re-encode editor-hostile video (Google Photos' VP9-in-MP4) and
  # pull audio tracks out of video. One entry so the set cannot drift out of sync
  # with home.packages as CLIs are added. See packages/media-toolkit.nix.
  mediaToolkit = pkgs.callPackage ../../packages/media-toolkit.nix { };

  # Finder right-click → Quick Actions entries for the CLIs above (Automator
  # .workflow bundles, generated — no Automator.app authoring). Linked into
  # ~/Library/Services below. See packages/media-quick-actions.nix.
  mediaQuickActions = pkgs.callPackage ../../packages/media-quick-actions.nix {
    media-toolkit = mediaToolkit;
  };

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
      ANDROID_HOME="''${ANDROID_HOME:-${androidSdkRoot}}"
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

  # `macvm-tart-start` on PATH (macos host only, below) — needed as a stable
  # command the Spotlight launcher app can invoke without `cd`-ing into the
  # flake. tart is unfree but nixpkgs.config.allowUnfree = true is already set
  # on the macos darwin host (hosts/macos.nix) and shared into this pkgs via
  # useGlobalPkgs, so no separate pkgsUnfree import is needed here (contrast
  # flake.nix's packages.*.macvm-tart-* wiring, built outside useGlobalPkgs).
  macvmTartStart = (pkgs.callPackage ../../packages/macvm-tart.nix { }).macvm-tart-start;

  # "Focus-or-launch" Spotlight .app bundles for the Android emulator + macvm
  # (macos host only, below) — see packages/spotlight-launchers.nix.
  spotlightLaunchers = pkgs.callPackage ../../packages/spotlight-launchers.nix { };

in
{
  # Replace HM's stock launchd module so agents use nix-* BTM basenames
  # (modules/shared/hm-launchd — wait4path kept inside the named wrapper).
  disabledModules = [ "launchd/default.nix" ];

  imports = [
    # Finder right-click → Services for the media-toolkit CLIs. An INLINE
    # MODULE because one attrset cannot define both `home.file` and
    # `home.file."x"`, and this file does the latter elsewhere; as its own module
    # the generated set merges instead of colliding. Entries come from the
    # package's own action list, so adding an action needs no edit here. macOS
    # registers a .workflow reached through a SYMLINK, so the store path works
    # as-is; `recursive` matches the .app launchers so macOS sees a real
    # directory. NEW OR CHANGED ITEMS NEED `killall Finder` — activation links
    # them and pbs registers them, but a running Finder keeps serving its old
    # menu, which looks exactly like the service having failed to install.
    {
      home.file = lib.mkIf isMacosHost (
        lib.listToAttrs (
          map (n: {
            name = "Library/Services/${n}.workflow";
            value = {
              source = "${mediaQuickActions}/${n}.workflow";
              recursive = true;
            };
          }) mediaQuickActions.actionNames
        )
      );
    }
    ./hm-launchd # patched home-manager launchd (nix-* ProgramArguments)
    ./mcp.nix # darwin-gated MCP server registry for Claude Code
    ./desktop-aesthetics.nix # Terminal.app 16pt (all darwin) + wallpaper (opt-out; macvm opts out)
    ./wireguard-configs.nix # operator-managed WG confs → ~/.config/wireguard (no autostart)
    ./claude-otel.nix # local OTel Collector for Claude Code's routing-decision telemetry (macos only)
    ./chromium.nix # ungoogled-chromium (Homebrew cask) config: sideloaded iCloud Passwords + its native host
    ./git-allowed-signers.nix # extra allowed_signers principals (option only; nix-personal fills)
    # Local-first RAG stack (loopback launchd Postgres+pgvector + Ollama + in-DB
    # embed()), from the extracted flake (github:kattakath/nix-local-rag).
    # Both modules are internally gated on (enable && isDarwin) — a clean no-op on
    # the NixOS hosts. Enabled only on the real Mac host below (not macvm).
    local-rag.homeManagerModules.default
    # macOS login-Keychain `secret` CLI + every-shell loader — the extracted flake
    # (github:kattakath/nix-keychain-secrets), installed via its HM module below.
    # Internally darwin-gated, so it's a clean no-op on the NixOS hosts.
    keychain-secrets.homeManagerModules.default
    # Gate CLAUDE_CODE_USE_BEDROCK (Keychain, survives every activation) on the
    # AWS identity that only the PRIVATE layer supplies — so activating the public
    # #macos degrades Claude Code to its default provider instead of leaving it
    # unable to reach any model at all. Must live here, not in nix-personal: a gate
    # in the private layer would be dropped by the activation it defends against.
    ./claude-bedrock-gate.nix
  ];

  # Enable the extracted keychain-secrets module (installs the secret/set-secret/
  # remove-secret CLIs + the ~/.config/secrets/loader.sh every-shell loader).
  programs.keychainSecrets.enable = true;

  # WireGuard confs: sync ~/.local/share/wireguard-configs → ~/.config/wireguard
  # on macos + macvm. Confs stay outside git (private keys). Copy-only — it NEVER
  # runs wg-quick / starts a tunnel. On macos (GUI-only, no CLI) these are there
  # to IMPORT into WireGuard.app; on macvm the CLI `vpn` operator uses them.
  local.wireguardConfigs.enable = pkgs.stdenv.isDarwin;

  # RAG stack (Ollama + pgvector) backs the postgres MCP server — real Mac only.
  # macvm is a lean sandbox; no need for embed/DB launchd agents there.
  services.ollamaLocal.enable = isMacosHost;
  services.pgvectorLocal.enable = isMacosHost;

  # Claude Code routing telemetry collector — real Mac only (keeps macvm lean,
  # same gate as the RAG stack above). See modules/shared/claude-otel.nix and
  # the programs.claude-code.settings.env block below that points Claude Code
  # at it.
  services.claudeOtel.enable = isMacosHost;

  # ungoogled-chromium's declarative surface — real Mac only, since only
  # hosts/macos.nix declares the cask (macvm keeps a lean Homebrew list). Writes
  # the External Extensions + NativeMessagingHosts files that make the sideloaded
  # iCloud Passwords extension talk to macOS Passwords.app; see chromium.nix.
  programs.ungoogledChromium.enable = isMacosHost;

  # The PUBLIC half of the userscript set. Private ones are added to this same
  # attrset by the nix-personal flake through `extraHomeModules`, which is the
  # whole point of keying it — keys must stay distinct across the two repos.
  # `../../userscripts/…` is a Nix SOURCE literal: repo-relative by definition,
  # copied into the store at eval. See modules/shared/chromium.nix for the option.
  programs.ungoogledChromium.userScripts.scripts = {
    google-photos-icon-nav = ../../userscripts/google-photos-icon-nav.user.js;
  };

  # Spotlight-launchable "Android Emulator" + "Mac VM" — click (or re-click)
  # like any normal app: launches if not running, brings the existing window
  # frontmost if it is. Real Mac only — pointless on macvm itself (no Android
  # emulator, and it can't control its own Tart host). Symlinked into
  # ~/Applications, which Spotlight indexes; see packages/spotlight-launchers.nix.
  # First launch of each will prompt a one-time Automation permission ("wants
  # to control System Events") — approve it in System Settings > Privacy &
  # Security > Automation.
  home.file."Applications/Android Emulator.app" = lib.mkIf isMacosHost {
    source = spotlightLaunchers.androidEmulatorApp;
    recursive = true;
  };
  home.file."Applications/Mac VM.app" = lib.mkIf isMacosHost {
    source = spotlightLaunchers.macvmApp;
    recursive = true;
  };

  services.mcpGateway = lib.mkIf isMacosHost {
    # Telegram USER-account server (read/triage + draft-only send). Real Mac only.
    # Inert until the one-time auth is done (TG_APP_ID/TG_API_HASH in the Keychain +
    # ~/.telegram-mcp/session.json) — see modules/shared/mcp.nix `telegramMcp`.
    telegram.enable = true;
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
  # Fonts: the two Nerd Fonts wired to VS Code settings, plus Inter as a general
  # proportional UI face. nixpkgs unstable uses the per-font `nerd-fonts.<name>`
  # attrs (24.05+ restructure), not the old `(nerdfonts.override { ... })`.
  home.packages =
    with pkgs;
    [
      fh # FlakeHub CLI — flake input publishing/management, wanted on every host
      # fonts
      nerd-fonts.jetbrains-mono # "JetBrainsMono Nerd Font" — VS Code editor font (pairs with the JetBrains theme)
      nerd-fonts.ubuntu-mono # "UbuntuMono Nerd Font" — VS Code terminal font (matches the devcontainer)
      inter # "Inter" — proportional UI font; no Nerd Font variant exists (NF only patches monospace fonts), so this is the plain upstream package
      # Postgres client/server tools WITH pgvector. `services.pgvectorLocal` (the local-rag flake)
      # already puts a PLAIN postgresql_16 in this profile, whose `share/postgresql` has no
      # `vector.control` — so `initdb`-ing a fresh cluster from it cannot `CREATE EXTENSION vector`.
      # That broke the dontsell-ai/app CI `integration` job whenever it landed on the REPO-level
      # runner (`macos-throwaway`), which runs from this profile; the org runners get theirs from
      # modules/darwin/github-runner.nix. `hiPrio` because both derivations provide `bin/psql` and a
      # profile collision is otherwise a build error — this one is a superset, so it should win.
      (lib.hiPrio (postgresql_16.withPackages (p: [ p.pgvector ])))
    ]
    # claude-code: on darwin it is installed by the programs.claude-code module
    # below (so the mcp-servers-nix integration can inject the shared MCP
    # registry — see ./mcp.nix). On the Linux hosts we don't enable that module,
    # so install the bare CLI here instead. Avoids a buildEnv /bin collision.
    ++ lib.optionals (!stdenv.isDarwin) [ claudeCode ]
    # secret/set-secret/remove-secret now come from programs.keychainSecrets
    # (the keychain-secrets flake's HM module), not this list.
    ++ lib.optionals stdenv.isDarwin [
      androidEmu
      awscli2 # AWS CLI v2 — SSO login into the Infin8 accounts; profiles live in ~/.aws/config (uncommitted, has account IDs/SSO URL — not this public repo)
      # buku — the bookmark manager of record (SQLite + CLI), chosen over rolling anything
      # custom: `buku --ai` reads Chrome/Brave/Chromium/Firefox profiles DIRECTLY off disk
      # (it does NOT need the browser installed), collapses duplicates on URL, and maps each
      # browser folder to a tag. It then exports Netscape HTML, which is exactly what
      # Chromium's importer eats — so it round-trips a cleanup without a single line of glue.
      # Measured 2026-08-31 merging the dead Chrome + Brave profiles: 1372 raw → 765 unique.
      # GOTCHA: `buku -i <file>.json` does NOT understand Chrome's own `Bookmarks` JSON (it
      # wants buku/Firefox JSON) and silently imports 0 records — always use `--ai`.
      # DB location is pinned by $BUKU_DEFAULT_DBDIR (home.sessionVariables below).
      buku
      codecov-cli # Codecov CLI (`codecovcli`) — upload coverage reports / local upload from CI; reads the CODECOV_TOKEN env var (a Keychain secret, never in this repo)
      fnm # Fast Node Manager — per-project Node version switching honoring .nvmrc/.node-version; the `fnm env --use-on-cd` shell hook is wired into zsh/bash below. No `programs.fnm` HM module in this pinned home-manager, so it's a bare package + hand-wired init.
      jsonresume # `jsonresume download|print|validate|markdown|text` — fetch a JSON Resume (default URL from jsonResumeUrl, or --url) + render PDF via resumed (fallback resume-cli); md/text via resume-cli (packages/jsonresume.nix)
      email-signature # `email-signature [--url URL] [--logo-url URL] [--out DIR]` — render a self-contained HTML email signature (JSON Resume + gist logo, base64-embedded) to ~/.local/share/email-signature/signature.html; also regenerated on activation (packages/email-signature/)
      design-tokens # `design-tokens [--tokens-url URL] [--out DIR]` — transform the gist DTCG tokens.json into SCSS/CSS/JS via Style Dictionary, to ~/.local/share/design-tokens/ (packages/design-tokens/)
      jobspy # `jobspy --search … --location …` — scrape jobs (LinkedIn/Indeed/…) into CSV/JSON via python-jobspy in an ephemeral uv env (packages/jobspy.nix)
      obs-fb-setup # `obs-fb-setup` — write an OBS "Facebook" profile for Facebook Live, injecting FB_PERSISTENT_STREAM_KEY from the login Keychain (packages/obs-fb-setup.nix)
      fidelityEnhance # `fidelity-enhance-mcp` (stdio MCP server) + `fidelity-enhance` (CLI) — fidelity referee for agentic image editing: Grok Imagine generates, this judges drift against the original (SSIM/LPIPS/ArcFace identity) and returns retry/next-step/done plus prompt guidance. Ephemeral uv env; FIRST RUN pulls ~1GB of torch/insightface — warm it with `fidelity-enhance capabilities` (packages/fidelity-enhance.nix)
      mediaToolkit # `fix-google-video <file>...` (re-encode VP9-in-MP4 and other editor-incompatible codecs into H.264+AAC) + `extract-audio [--mp3|--wav|--flac] <file>...` (pull the audio track out of a video) (packages/media-toolkit.nix)
      mermaidAscii # render Mermaid graphs as ASCII in the terminal (packages/mermaid-ascii.nix)
      jdk17 # JRE for the Android sdkmanager/avdmanager (JVM tools); emulator itself needs no Java
      runpodctl # RunPod GPU CLI — RunPod as a second ComfyUI-workflow provider alongside Vast (from nixpkgs, not the untrusted brew tap)
      qwen-code # `qwen` — Alibaba's Gemini-CLI-fork coding agent, pointed at a LOCAL Qwen model served by Ollama's OpenAI-compatible endpoint (config in ~/.qwen/.env below, NOT the global OpenAI env — those generic var names would hijack other tools). Pull the model with `ollama pull qwen3-coder:30b`.
      inngest # `inngest` — CLI + local dev server for Inngest durable workflows (not in Homebrew; nixpkgs has it)
      stripe-cli # Stripe CLI (`stripe`) — API calls, webhook forwarding (`stripe listen`), event triggers; auth is a one-time `stripe login` browser OAuth (config in ~/.config/stripe, never in git/store — same one-time-CLI-login convention as gh/hf/docker). Pairs with the stripe@claude-plugins-official plugin (claudePluginIds above)
      resendCli # `resend` — the official Resend CLI (npx-wrapped, not yet in nixpkgs), authenticated non-interactively via RESEND_API_KEY from the login Keychain (packages/resend-cli.nix). Pairs with the resend@claude-plugins-official plugin (claudePluginIds above)
      wp-cli # WordPress CLI (`wp`) — manage WordPress installs/plugins/themes/db from the shell; nixpkgs-native (bundles its own PHP), so no Homebrew `wp-cli` formula or `curl … wp-cli.phar` install (single source per the reuse/declarative convention)
      pandoc # Universal doc converter — nixpkgs-native on aarch64-darwin (no Homebrew needed); backs the docx/pptx/xlsx skills' `pandoc` dependency (see programs.claude-code.skills NOTE below)
      poppler-utils # pdftoppm/pdftotext/pdfimages CLI — NOT `poppler` (that's the glib-bindings library, no binaries); moved here from the macos Homebrew `poppler` formula (nixpkgs is the single source per modules/darwin/homebrew.nix's dedup comment); backs the pdf/docx/pptx skills
    ]
    # WireGuard `vpn` operator — macvm ONLY (it has no App Store, so the CLI is
    # its only option). macos is GUI-only and ships no VPN CLI on purpose — see
    # the rationale on the dropped wireguard-tools brew in hosts/macos.nix.
    ++ lib.optionals (stdenv.isDarwin && !isMacosHost) [
      vpn # `vpn list|status|up|down|switch` — WireGuard operator for ~/.config/wireguard (packages/vpn.nix)
    ]
    # macvm-tart-start on PATH — real Mac (Tart host) only. The Spotlight
    # "macvm" launcher above calls this by bare name; also handy directly
    # (nix run .#macvm-tart-* still covers the rest of the kit).
    ++ lib.optionals isMacosHost [
      macvmTartStart
      androidPhone # `android-phone list|pair|connect|disconnect|unpair|tcpip|wireless|mirror|doctor` — deterministic ADB wired/wireless operator + scrcpy mirroring for a PHYSICAL device (packages/android-phone.nix); unrelated to `android-emu` (virtual emulator, below)
    ];

  # ---- Android SDK (macOS only) ------------------------------------------------
  # The `android-commandlinetools` Homebrew cask installs sdkmanager/avdmanager
  # under the Homebrew prefix. Point ANDROID_HOME there so `sdkmanager` downloads
  # the emulator + system images into it, and put the emulator/platform-tools
  # bins on PATH (adb itself also comes from the `android-platform-tools` cask).
  # After switching, just run `android-emu` (the helper in the let block) — it
  # installs the SDK packages + creates the AVD on first run, then boots it.
  home.sessionVariables = lib.mkIf pkgs.stdenv.isDarwin {
    ANDROID_HOME = androidSdkRoot;
    # sdkmanager/avdmanager are JVM tools; point them at the nixpkgs JDK 17.
    JAVA_HOME = pkgs.jdk17.home;

    # SINGLE SOURCE OF TRUTH for where the brag pipeline reads/writes its data (the
    # kattakath/brags checkout). The `/brag` + `brags-review` skills read $BRAG_DATA_DIR
    # and error if it is unset — no hardcoded path scattered across the skills. Kept
    # $HOME-relative (username-portable); change the checkout location here, in ONE place.
    BRAG_DATA_DIR = "$HOME/Developer/local/brags";

    # Where buku keeps `bookmarks.db`. Pinned because buku otherwise scatters it into a
    # platform-guessed data dir, and this DB is the single surviving copy of the merged
    # Chrome+Brave bookmark set — it must live somewhere backed up and obvious, next to
    # the other $HOME/Developer/local data dirs. $HOME-relative for the same reason
    # BRAG_DATA_DIR is (username-portable; never a literal /Users/<name>).
    BUKU_DEFAULT_DBDIR = "$HOME/Developer/local/bookmarks";
    # BASH_ENV (the secret loader) + the loader file itself are now set by
    # programs.keychainSecrets (the keychain-secrets flake's HM module).

    # The JSON Resume CLIs (jsonresume.org, npm globals: `resumed` — the maintained
    # tool this repo prefers — and legacy `resume-cli`) render PDFs via puppeteer,
    # whose bundled Chromium auto-download is flaky (its chrome-headless-shell fetch
    # corrupts, failing the `npm i`). These two vars form one coherent policy —
    # NEVER download puppeteer's own browser, ALWAYS use the browser cask the host
    # already declares:
    #   SKIP_DOWNLOAD    — any `npm i` that pulls puppeteer skips the browser fetch
    #                      (so `npm i -g resumed puppeteer` / a theme install never breaks).
    #   EXECUTABLE_PATH  — puppeteer launches that system browser at runtime instead.
    # Points at the `ungoogled-chromium` cask, NOT google-chrome: Chrome was dropped
    # from every host, and rendering was the only thing it was still load-bearing for.
    # Verified 2026-08-31 — puppeteer launched this binary (reports Chrome/152.0.7977.64)
    # and `page.pdf()` returned a valid `%PDF-` document. That cask is macos-only
    # (`isMacosHost` below), so on macvm this path does not exist and the var is inert
    # until a browser is declared there; the JSON Resume npm globals live on macos.
    # Harmless for other puppeteer tools (they get the same browser); Remotion is
    # unaffected — it resolves its own browser, not these vars. The resume THEME
    # still installs per-project (local node_modules), e.g. `npm i jsonresume-theme-macchiato`.
    PUPPETEER_SKIP_DOWNLOAD = "true";
    PUPPETEER_EXECUTABLE_PATH = "/Applications/Chromium.app/Contents/MacOS/Chromium";
  };

  home.sessionPath = lib.optionals pkgs.stdenv.isDarwin [
    "${androidSdkRoot}/emulator"
    "${androidSdkRoot}/platform-tools"
    # xAI Grok CLI: a self-updating prebuilt binary installed to ~/.grok/bin by
    # `curl -fsSL https://x.ai/cli/install.sh | bash` (no nixpkgs/brew package
    # exists, and `grok` updates itself, so pinning it in Nix would fight its
    # updater). It lives outside the Nix store and /opt/homebrew, so Homebrew's
    # cleanup="uninstall" never touches it; this line is the declarative PATH
    # entry (the source of truth over the installer's own ~/.zshrc edit).
    "$HOME/.grok/bin"
  ];

  # No activation shorthand is defined here on purpose. This public engine is the
  # fleet-only BASELINE: any alias it could ship would point at its own `#macos`,
  # i.e. exactly the switch that silently drops the private layer (see
  # claude-bedrock-gate.nix for what that costs). The real day-to-day command is
  # the freshness-gated `activate` CLI, which only the private nix-personal flake
  # can build because only it composes the full host. See
  # docs/private-home-modules.md.

  # GLOBAL Claude Code instructions — user-level rules loaded in every project/session
  # on this Mac (the sole Claude Code client host). Declarative equivalent of hand-writing
  # ~/.claude/CLAUDE.md; the strict "decisions/confirmations = AskUserQuestion options"
  # rule + reuse-over-rebuild preference live here so they apply everywhere, not just in
  # this repo. Darwin-only (claude-code runs on both darwin hosts, macos + macvm).
  home.file.".claude/CLAUDE.md" = lib.mkIf pkgs.stdenv.isDarwin {
    source = ../../claude/CLAUDE.md;
  };

  # The custom grok sandbox profile the patched grok-build bridge asks for (see
  # grokBuildPluginPatched in the let block above for WHY the built-in `read-only` is
  # unusable here). Unlike ~/.grok/config.toml — which grok itself rewrites, so mcp.nix
  # merges into it via `grok mcp add` — sandbox.toml is pure user input that grok only ever
  # READS, so it is safe to own declaratively. A store symlink here is accepted (verified);
  # grok only refuses symlinks for $GROK_HOME and hooks-paths entries. `force` because grok
  # drops a 0-byte placeholder at this path that HM would otherwise refuse to clobber.
  #
  # `deny` is kernel-enforced (Seatbelt) for BOTH read and write, and closes the
  # `mv secret x && cat x` bypass — it is what actually protects credentials now that the
  # base profile is `workspace`. Every entry must be a real path (a symlink component makes
  # grok refuse to start, which is the whole bug being worked around) and must NOT cover
  # ~/.grok/auth.json: denying that leaves grok unable to read its own token and it exits
  # "Not signed in" (verified). Darwin-only — grok is only on the Mac.
  home.file.".grok/sandbox.toml" = lib.mkIf pkgs.stdenv.isDarwin {
    force = true;
    text = ''
      # Managed by nix-config (modules/shared/home.nix) — do not hand-edit.
      [profiles.${grokSandboxProfile}]
      extends = "workspace"
      deny = [
        "${config.home.homeDirectory}/.ssh",
        "${config.home.homeDirectory}/.aws",
        "${config.home.homeDirectory}/.docker",
        "${config.home.homeDirectory}/.config/gh",
        "**/*.pem",
        "**/*.age",
        "**/.env",
      ]
    '';
  };

  # qwen-code local-model wiring. `qwen` (Alibaba's coding-agent CLI, in
  # home.packages above) auto-loads ~/.qwen/.env — a qwen-SCOPED env file, so we
  # point it at the LOCAL Ollama OpenAI-compatible endpoint WITHOUT exporting the
  # generic OPENAI_* names into every shell (which would hijack any other
  # OpenAI-compatible tool). OPENAI_API_KEY is a required-but-ignored dummy for a
  # local server. Change the model here (must match an `ollama pull`ed tag);
  # nothing here starts Ollama — it's the always-on launch agent on macos.
  # Darwin-only (Ollama + this personal tooling live on the Mac).
  home.file.".qwen/.env" = lib.mkIf pkgs.stdenv.isDarwin {
    text = ''
      OPENAI_BASE_URL=http://localhost:11434/v1
      OPENAI_API_KEY=ollama
      OPENAI_MODEL=qwen3-coder:30b
    '';
  };

  # `qwen` settings.json — validated against the installed 0.16.0 build (keys it
  # accepted with no warning: general.checkpointing, telemetry, tools.toolSearch,
  # tools.approvalMode, mcpServers via httpUrl). Model auth stays in ~/.qwen/.env
  # (env beats settings.json), so no secret ever lands here. checkpointing on =
  # file-edit snapshots (safe autonomous edits, `/restore`); toolSearch on =
  # retrieval over the tool surface (tames tool count for the local model);
  # approvalMode "default" = ask before each edit/shell. mcpServers reuses the
  # gateway (curated `qwenMcpServers`), macos-only. Darwin-wide otherwise so macvm
  # still gets a sane config (minus MCP, since its gateway is off).
  home.file.".qwen/settings.json" = lib.mkIf pkgs.stdenv.isDarwin {
    text = builtins.toJSON (
      {
        general.checkpointing.enabled = true;
        telemetry.enabled = false;
        tools = {
          toolSearch.enabled = true;
          approvalMode = "default";
        };
      }
      // lib.optionalAttrs isMacosHost { mcpServers = qwenMcpServers; }
    );
  };

  # Global `qwen` context (all projects) — the qwen counterpart of ~/.claude/CLAUDE.md.
  # Read-only store symlink like that file; qwen's own save_memory targets this path,
  # so memory-to-file is intentionally inert here (persistence, if wanted, is managed
  # auto-memory in a separate dir). Darwin-only (qwen is installed on darwin only).
  home.file.".qwen/QWEN.md" = lib.mkIf pkgs.stdenv.isDarwin {
    source = ../../qwen/QWEN.md;
  };

  # Git SSH allowed_signers (principal = userEmail, key = operatorSshKey).
  # Extra principals: options.kattakath.git.extraAllowedSignersPrincipals
  # (git-allowed-signers.nix), filled from nix-personal.
  # HM target is home-relative; programs.git uses absolute allowedSignersFile.
  home.file.".ssh/allowed_signers".text = lib.concatMapStrings (principal: ''
    ${principal} namespaces="git" ${operatorSshKey}
  '') (lib.unique ([ userEmail ] ++ config.kattakath.git.extraAllowedSignersPrincipals));

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

      # Marketplaces are NOT declared via `marketplaces.*` here. That option writes a
      # Nix-managed known_marketplaces.json symlink; `claude plugin marketplace add`
      # and installs need a mutable file, and the reserved name
      # `claude-plugins-official` must be a GitHub/HTTPS source (directory pins are
      # rejected as untrusted). All three marketplaces are registered by
      # home.activation.claudeCodePlugins from:
      #   - xai-grok-build ← pinned flake input path (grok-build-plugin-cc)
      #   - claude-plugins-official ← https://github.com/anthropics/claude-plugins-official
      #   - kattakath-nix-config ← this repo's own plugins/ tree (localPluginsMarketplace)
      # Plugin install state lives in mutable ~/.claude (like gh/hf one-time logins).
      # Runtime for grok-build: grok on PATH (~/.grok/bin) + Node; `grok models` must work.

      # Claude Code user settings, now Nix-owned. enabledPlugins keeps declared
      # plugins switched ON once `claude plugin install` has run (activation below).
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

        # Routing telemetry: export tool_decision/tool_result events (only —
        # no metrics/traces, no prompt/response content) to the local OTel
        # Collector defined in modules/shared/claude-otel.nix, read by
        # /routing-review to find deterministic-vs-model-judgment hardening
        # candidates. isMacosHost-gated (services.claudeOtel.enable above) —
        # unset on macvm, so this block is empty there and Claude Code's
        # telemetry stays off by default.
        env = lib.mkIf isMacosHost {
          CLAUDE_CODE_ENABLE_TELEMETRY = "1";
          OTEL_LOGS_EXPORTER = "otlp";
          OTEL_EXPORTER_OTLP_PROTOCOL = "grpc";
          OTEL_EXPORTER_OTLP_ENDPOINT = config.services.claudeOtel.otlpEndpoint;
          OTEL_LOG_TOOL_DETAILS = "1";
        };
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

        # ---- Tool-driver skills: each pairs with an MCP server / connector this
        # fleet already runs (see flake.nix `agent-skills-*` inputs). Additive,
        # git-pinned, bumped via `nix flake update`. ----
        # OFFICIAL Cloudflare (Apache-2.0): drive the cloudflare/cloudflare-docs MCP
        # servers + the live Cloudflare Tunnel/terranix stack. `cloudflare-one` covers Access/Tunnel.
        cloudflare = "${agent-skills-cloudflare}/skills/cloudflare";
        cloudflare-one = "${agent-skills-cloudflare}/skills/cloudflare-one";
        # Anthropic official (source-available): mcp-builder tool-design guidance for the
        # whole MCP gateway; webapp-testing is self-contained (writes native Python
        # Playwright scripts that launch their own headless chromium) — no MCP server
        # of ours backs it, in particular NOT the gateway `playwright` entry, since
        # that was removed with browservm (2026-08-20).
        mcp-builder = "${agent-skills-anthropic-official}/skills/mcp-builder";
        webapp-testing = "${agent-skills-anthropic-official}/skills/webapp-testing";
        # Anthropic document skills: pair with the Google Drive connector (fetch → edit → store).
        # NOTE heavy runtime deps: pandoc + poppler now come from nixpkgs (home.packages
        # above); LibreOffice/soffice comes from the macos-only Homebrew cask
        # (hosts/macos.nix) since nixpkgs libreoffice-bin cannot reliably block on
        # headless --convert-to. qpdf and the skills' own pip/npm deps (pypdf,
        # openpyxl, docx, pptxgenjs, …) remain undeclared/ambient — a separate,
        # larger follow-up. macvm inherits this same skills block (gated on
        # stdenv.isDarwin, not hostName == "macos") but does NOT get the libreoffice
        # cask — soffice is absent there; a known, accepted asymmetry for now.
        pdf = "${agent-skills-anthropic-official}/skills/pdf";
        docx = "${agent-skills-anthropic-official}/skills/docx";
        pptx = "${agent-skills-anthropic-official}/skills/pptx";
        xlsx = "${agent-skills-anthropic-official}/skills/xlsx";
        # Community (MIT, 10.9k★): senior-Postgres skill — pairs with the `postgres` MCP + pgvector RAG.
        postgres-pro = "${agent-skills-jeffallan}/skills/postgres-pro";
        # Community (MIT): AppleScript/JXA foundation — pairs with the `macos-automator` MCP server.
        # Foundation skill only (the 15 per-app skills can be added later) to keep the global set lean.
        automating-mac-apps = "${agent-skills-mac-automation}/plugins/automating-mac-apps-plugin/skills/automating-mac-apps";
        # Community: generate .excalidraw diagrams — pairs with the Excalidraw connector.
        # Root-level SKILL.md, so the whole repo is the skill dir.
        excalidraw-diagram = "${agent-skills-excalidraw}";
        # OFFICIAL Vercel Labs (vercel-labs/agent-skills): drives the `vercel` CLI
        # (hosts/macos.nix Homebrew `vercel-cli`) for non-interactive / token auth —
        # the deploy/manage counterpart to the CLI itself. Cherry-picked (one skill).
        vercel-cli-with-tokens = "${agent-skills-vercel-agent}/skills/vercel-cli-with-tokens";
        # OFFICIAL Vercel Workflow SDK (vercel/workflow, Apache-2.0): the three USER-facing
        # skills for building/adopting durable, resumable TypeScript workflows. We DROP the
        # repo's `internal-dev-workbench` skill (tmux/portless session for hacking on the SDK
        # repo itself — not applicable here). Pairs with the `inngest` CLI already on PATH.
        workflow = "${agent-skills-vercel-workflow}/skills/workflow";
        workflow-init = "${agent-skills-vercel-workflow}/skills/workflow-init";
        migrating-to-workflow-sdk = "${agent-skills-vercel-workflow}/skills/migrating-to-workflow-sdk";
        # OFFICIAL BerriAI (MIT): litellm-skills — drive a live LiteLLM proxy (this fleet's
        # TakeoffAiGate deployment) via curl against its admin API. Root-level SKILL.md per verb,
        # so each entry IS the skill dir (same shape as excalidraw-diagram above). Pulled whole —
        # one coherent admin toolkit (users/teams/keys/models/orgs/MCP servers/agents/usage).
        add-user = "${agent-skills-litellm}/add-user";
        update-user = "${agent-skills-litellm}/update-user";
        delete-user = "${agent-skills-litellm}/delete-user";
        add-team = "${agent-skills-litellm}/add-team";
        update-team = "${agent-skills-litellm}/update-team";
        delete-team = "${agent-skills-litellm}/delete-team";
        add-key = "${agent-skills-litellm}/add-key";
        update-key = "${agent-skills-litellm}/update-key";
        delete-key = "${agent-skills-litellm}/delete-key";
        add-org = "${agent-skills-litellm}/add-org";
        delete-org = "${agent-skills-litellm}/delete-org";
        add-model = "${agent-skills-litellm}/add-model";
        update-model = "${agent-skills-litellm}/update-model";
        delete-model = "${agent-skills-litellm}/delete-model";
        add-mcp = "${agent-skills-litellm}/add-mcp";
        update-mcp = "${agent-skills-litellm}/update-mcp";
        delete-mcp = "${agent-skills-litellm}/delete-mcp";
        add-agent = "${agent-skills-litellm}/add-agent";
        update-agent = "${agent-skills-litellm}/update-agent";
        delete-agent = "${agent-skills-litellm}/delete-agent";
        view-usage = "${agent-skills-litellm}/view-usage";
        # ---- Security / methodology skills (from the audit) ----
        # Trail of Bits (CC-BY-SA-4.0): prefer authenticated `gh` over raw GitHub curl/WebFetch —
        # fits the heavy gh/PR flow (PR open/review, brag PR mining).
        gh-cli = "${agent-skills-trailofbits}/plugins/gh-cli/skills/gh-cli";
        # Trail of Bits: score dependencies for takeover/typosquat/bus-factor risk — matches the
        # flake-pin provenance discipline (every input is pinned + provenance-checked).
        supply-chain-risk-auditor = "${agent-skills-trailofbits}/plugins/supply-chain-risk-auditor/skills/supply-chain-risk-auditor";
        # obra/superpowers (MIT): the SINGLE systematic-debugging skill (cherry-picked subpath, NOT
        # the whole 14-skill plugin) — a hypothesis-driven debugging methodology.
        systematic-debugging = "${agent-skills-superpowers}/skills/systematic-debugging";
        # ---- Job-search skills (Paramchoudhary/ResumeSkills, MIT) ----
        # A LEAN, complementary slice of the 21-skill pack — the text-based job-search steps that
        # AREN'T resume.json-specific. resume-tailor is deliberately OMITTED: the json-native
        # .claude/skills/jsonresume-tailor (this repo) supersedes it, reading/writing real resume.json
        # and rendering via the `jsonresume` wrapper. These pair with the jobspy + Indeed connectors.
        job-description-analyzer = "${agent-skills-jsonresume}/skills/job-description-analyzer";
        resume-ats-optimizer = "${agent-skills-jsonresume}/skills/resume-ats-optimizer";
        cover-letter-generator = "${agent-skills-jsonresume}/skills/cover-letter-generator";
        interview-prep-generator = "${agent-skills-jsonresume}/skills/interview-prep-generator";
        salary-negotiation-prep = "${agent-skills-jsonresume}/skills/salary-negotiation-prep";
        # Personal: a thin GLOBAL pointer to the Brags personal-branding review flow whose
        # authoritative SKILL.md + engine live in the private ~/Documents/brags repo (so it
        # tracks that repo, and the heavy logic isn't vendored here). Makes "run my brags
        # review" invocable by name in any Claude Code / Claude Desktop session.
        brags-review = "${../../skills/brags-review}";
        # Local RAG over the pgvector store: how to ingest + query via the `postgres`
        # MCP server and the in-DB embed() function (modules/shared/{postgres-pgvector,ollama}.nix).
        rag = "${../../skills/rag}";
        # `/brag` — the MINE→LEDGER stage of the rebuilt brag-doc pipeline: mines GitHub
        # PRs/commits + Claude Code sessions (+ optional MCP) into impact.md/developer-value.md.
        # Vendored from kammradt/brag-skill (MIT), data paths redirected to the private
        # kattakath/brags repo checkout so it works under the read-only Nix skill install —
        # see skills/brag/FORK-NOTES.md. Replaces the retired bespoke ~/Developer/local/brags engine.
        brag = "${../../skills/brag}";
        # Original (not a fork): operator knowledge for the packages/android-phone.nix
        # ADB/scrcpy CLI — global so ANY session (including ~/-rooted ones) knows the
        # wrapper's command surface and the adb footguns it absorbs, not just sessions
        # rooted in this repo. Lives next to the package it documents so they can't
        # drift apart silently.
        android-phone = "${../../skills/android-phone}";

        # Making a repo self-sufficient with Nix: dev shell, env catalogue, project-local
        # Postgres+pgvector stack, self-hosted runner, and `nix run .#<verb>` lifecycle apps.
        # Global rather than repo-scoped precisely because the point is to apply it to a repo
        # that does NOT have it yet. Carries the Nix/Postgres/Prisma traps that cost real
        # debugging time (withPackages union prefix, socket port, macOS socket length cap).
        nix-dev-toolkit = "${../../skills/nix-dev-toolkit}";
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
        # SSH commit/tag signing (GitHub/GitLab Verified). Absolute $HOME paths —
        # non-absolute allowedSignersFile is worktree-relative. Forge still needs
        # the pubkey as a *Signing* key (docs/mac-key-recovery-runbook.md).
        commit.gpgsign = true;
        tag.gpgsign = true;
        gpg.format = "ssh";
        user.signingkey = operatorPublicKey;
        gpg.ssh.allowedSignersFile = allowedSignersFile;
      };

      # Per-directory identity under ~/Developer/<host>/<owner>/. Work email lives
      # in ~/.config/git/infin8.inc (not in this public repo); missing include is a
      # silent no-op. Paths absolute under $HOME.
      includes = [
        {
          condition = "gitdir:${config.home.homeDirectory}/Developer/github.com/Infin8-Information-Technologies/";
          path = "${config.home.homeDirectory}/.config/git/infin8.inc";
        }
        # Both orgs author as the same SilverCreek identity: dontsell-ai is the agency,
        # silvercreek-ai is the client whose site it builds. One include file serves both —
        # splitting it would duplicate the same address into two places.
        #
        # Matched by REMOTE url (hasconfig), not gitdir, so it applies regardless of clone
        # path — including throwaway agent clones. Two patterns per org cover https + ssh://
        # (**/org/**) and scp-style ssh git@github.com:org/… (**:org/**).
        #
        # The address itself lives in ~/.config/git/silvercreek.inc, deployed by the private
        # nix-personal flake — never this public repo, same convention as infin8.inc above.
        # A missing include is a silent no-op, so a host without the private layer simply
        # falls back to the default identity rather than failing.
        {
          condition = "hasconfig:remote.*.url:**/dontsell-ai/**";
          path = "${config.home.homeDirectory}/.config/git/silvercreek.inc";
        }
        {
          condition = "hasconfig:remote.*.url:**:dontsell-ai/**";
          path = "${config.home.homeDirectory}/.config/git/silvercreek.inc";
        }
        {
          condition = "hasconfig:remote.*.url:**/silvercreek-ai/**";
          path = "${config.home.homeDirectory}/.config/git/silvercreek.inc";
        }
        {
          condition = "hasconfig:remote.*.url:**:silvercreek-ai/**";
          path = "${config.home.homeDirectory}/.config/git/silvercreek.inc";
        }
        # GitLab personal namespace (ismailkattakath). gitlab.com-specific so
        # github.com/ismailkattakath keeps the GitHub noreply. Address lives in
        # ~/.config/git/gitlab.inc (nix-personal); missing include is a silent no-op.
        {
          condition = "hasconfig:remote.*.url:**/gitlab.com/ismailkattakath/**";
          path = "${config.home.homeDirectory}/.config/git/gitlab.inc";
        }
        {
          condition = "hasconfig:remote.*.url:**:gitlab.com:ismailkattakath/**";
          path = "${config.home.homeDirectory}/.config/git/gitlab.inc";
        }
        {
          condition = "gitdir:${config.home.homeDirectory}/Developer/gitlab.com/ismailkattakath/";
          path = "${config.home.homeDirectory}/.config/git/gitlab.inc";
        }
      ];
    };

    ssh = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;

      # Forward-compat with the home-manager `programs.ssh` deprecation: the module
      # is dropping its implicit `settings."*"` defaults (and warns while they remain
      # on by default), and `matchBlocks` is now a deprecated alias for `settings`.
      # We opt out with `enableDefaultConfig = false`, re-declare the former defaults
      # under `settings."*"` (with fleet overrides for agent/Keychain — see below),
      # and move the per-host blocks to `settings` so both deprecation warnings stay
      # silenced.
      enableDefaultConfig = false;

      settings = {
        # Defaults + Keychain-backed agent for git SSH signing / non-interactive SSH.
        # Paths absolute under $HOME.
        "*" = {
          ForwardAgent = false;
          AddKeysToAgent = "yes";
          UseKeychain = "yes";
          IdentityFile = operatorPrivateKey;
          Compression = false;
          ServerAliveInterval = 0;
          ServerAliveCountMax = 3;
          HashKnownHosts = false;
          UserKnownHostsFile = "${sshDir}/known_hosts";
          ControlMaster = "no";
          ControlPath = "${sshDir}/master-%r@%n:%p";
          ControlPersist = "no";
        };

        # Local NixOS hosts (mDNS .local) — agent forwarding on for interactive
        # admin work over SSH from the Mac.
        "*.local" = {
          User = config.home.username;
          IdentityFile = operatorPrivateKey;
          ForwardAgent = true;
        };

        # Tart macvm guest. Prefer `nix run .#macvm-tart-ssh` (IP discovery).
        # This Host is for a fixed HostName / macvm.local; user is always ismail.
        "macvm" = {
          User = "ismail";
          IdentityFile = operatorPrivateKey;
          ForwardAgent = true;
          StrictHostKeyChecking = "accept-new";
        };

        # nixpi over the Cloudflare Tunnel — the ONLY way to reach the Pi when the
        # Mac is not on its LAN (it has no public IP and no port-forward; the
        # `*.local` block above covers the mDNS path).
        #
        # This block is why it lives in Nix rather than in a hand-edit: the
        # runbooks have long said "add a `ProxyCommand cloudflared access ssh
        # --hostname %h` to ~/.ssh/config", but that file is a READ-ONLY
        # /nix/store symlink owned by this module — the instruction was
        # unfollowable. Declaring it here makes it real, and makes it apply to
        # BOTH deploy-rs legs at once: `deploy` shells out to the system `ssh` for
        # activation AND `nix copy --to ssh://…` for the closure, and both read
        # ~/.ssh/config. (deploy-rs joins its own `sshOpts` with spaces into
        # NIX_SSHOPTS, which nix re-splits on whitespace, so a spaced
        # `-o ProxyCommand=…` there would be mangled for the copy leg. ~/.ssh/config
        # is the one place a spaced ProxyCommand survives both.)
        #
        # cloudflared comes from the store, NOT `/opt/homebrew/bin` and not bare
        # PATH: ssh runs the ProxyCommand via `/bin/sh -c` with whatever
        # environment the caller had, so a PATH assumption turns into an opaque
        # "Connection closed" at the worst possible moment. The Homebrew cask
        # (hosts/macos.nix) stays for interactive `cloudflared tunnel` / `access
        # login` work; a duplicated Go binary is cheaper than a nondeterministic
        # deploy path.
        #
        # This path ALSO needs a Cloudflare Zero Trust *Access Application* for the
        # hostname — hand-created, not modelled in terranix, and it silently
        # vanished once (2026-08-20). Symptom + fix: docs/private-home-modules.md.
        "nixpi.${domainName}" = {
          User = config.home.username;
          IdentityFile = operatorPrivateKey;
          ProxyCommand = "${lib.getExe pkgs.cloudflared} access ssh --hostname %h";
          # A fresh SD flash reuses the hostname with a BRAND-NEW host key, so a
          # pinned entry would abort every post-reflash connection. accept-new
          # still refuses a CHANGED key (unlike `no`) — run
          # `ssh-keygen -R nixpi.${domainName}` after a reflash.
          StrictHostKeyChecking = "accept-new";
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
      # macOS Keychain secret loader is wired into bash's profileExtra/bashrcExtra
      # by programs.keychainSecrets (the keychain-secrets flake's HM module).

      # fnm (Fast Node Manager) shell hook — darwin-only (node dev is Mac-only; the
      # servers stay lean). `--use-on-cd` auto-switches Node on `cd` into a dir with
      # a .nvmrc/.node-version. Absolute store path so it resolves before the nix
      # profile is on PATH. When no project version is active/installed, PATH falls
      # through to the Homebrew node (an inert dependency of bruno-cli/devcontainer).
      initExtra = lib.mkIf pkgs.stdenv.isDarwin ''
        eval "$(${pkgs.fnm}/bin/fnm env --use-on-cd --shell bash)"
        ${sshKeychainLoadShell}
      '';
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

      # macOS Keychain secret loader is wired into zsh's envExtra (.zshenv) by
      # programs.keychainSecrets (the keychain-secrets flake's HM module).

      # fnm (Fast Node Manager) shell hook — darwin-only. Lives in initContent
      # (.zshrc, interactive) not envExtra, because `--use-on-cd` installs a chpwd
      # hook that only makes sense in an interactive shell. Honors .nvmrc and
      # .node-version; falls through to the Homebrew node when no version is active.
      initContent = lib.mkIf pkgs.stdenv.isDarwin ''
        eval "$(${pkgs.fnm}/bin/fnm env --use-on-cd --shell zsh)"
        ${sshKeychainLoadShell}
      '';
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

  # Login oneshot: load Keychain SSH identities into the agent for GUI git signing
  # (shells use sshKeychainLoadShell). First-time: ssh-add --apple-use-keychain
  # on the operator private key (key-recover does this). hm-launchd → nix-ssh-keychain-load.
  launchd.agents.ssh-keychain-load = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    config = {
      # ProgramArguments entries must be strings (not raw derivations).
      ProgramArguments = [
        "${pkgs.writeShellScript "ssh-keychain-load" ''
          set -eu
          /usr/bin/ssh-add --apple-load-keychain 2>/dev/null || true
          key="${operatorPrivateKey}"
          if [ -f "$key" ] && ! /usr/bin/ssh-add -l >/dev/null 2>&1; then
            /usr/bin/ssh-add --apple-use-keychain "$key" 2>/dev/null || true
          fi
        ''}"
      ];
      RunAtLoad = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ssh-keychain-load.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ssh-keychain-load.log";
    };
  };

  home.activation = lib.mkIf pkgs.stdenv.isDarwin {
    # Materialise DECLARED Claude Code plugins (claudePluginIds) + their marketplaces.
    # installed_plugins.json / known_marketplaces.json stay Claude-owned mutable state
    # (same "let the tool author its own state" pattern as grokMcp). settings.json is
    # Nix-managed: temporarily materialise a writable copy for install, then restore
    # the store symlink so the next switch does not hit "file is in the way".
    claudeCodePlugins = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # home-manager activation scripts run with a bare PATH (no ~/.nix-profile,
      # no /etc/profiles/per-user/<user>/bin) — `claude` itself is invoked by
      # absolute store path below so that's fine, but ITS OWN subprocesses are
      # not: a "git-subdir" plugin source (e.g. neon@claude-plugins-official)
      # shells out to a bare `git` lookup and fails with "git ... not on PATH"
      # even though programs.git (same pkgs.git) is on every interactive PATH.
      export PATH="${pkgs.git}/bin:$PATH"
      claude="${claudeCode}/bin/claude"
      if [ -x "$claude" ]; then
        settings="${config.home.homeDirectory}/.claude/settings.json"
        settings_target=""
        if [ -L "$settings" ]; then
          settings_target=$(readlink "$settings")
          tmp=$(mktemp)
          cp -L "$settings" "$tmp"
          rm -f "$settings"
          mv "$tmp" "$settings"
          chmod u+w "$settings"
        fi

        known_mps="${config.home.homeDirectory}/.claude/plugins/known_marketplaces.json"

        # xAI grok-build marketplace — pinned to a PATCHED store copy of the flake input
        # (grokBuildPluginPatched), so its path moves whenever the patch OR the upstream pin
        # changes. `plugin install` COPIES into ~/.claude/plugins/cache, so the old
        # "already registered?" guard would keep serving the stale, UNPATCHED bridge forever
        # (exactly the trap documented for the local marketplace below). Key off the store
        # path recorded in known_marketplaces.json instead, and tear the old pin down first.
        grok_mp="${grokBuildPluginPatched}"
        if ! grep -qF "$grok_mp" "$known_mps" 2>/dev/null; then
          echo "claude-code: (re)pinning xai-grok-build marketplace -> $grok_mp" >&2
          if "$claude" plugin marketplace list 2>/dev/null | grep -qF 'xai-grok-build'; then
            "$claude" plugin uninstall --yes 'grok-build@xai-grok-build' >/dev/null 2>&1 || true
            "$claude" plugin marketplace remove xai-grok-build >/dev/null 2>&1 || true
          fi
          "$claude" plugin marketplace add "$grok_mp" 2>&1 || true
        fi

        # Official marketplace via HTTPS (SSH clone fails non-interactively; reserved
        # name rejects directory pins — see programs.claude-code comment above).
        official_mp_src="https://github.com/anthropics/claude-plugins-official.git"
        if ! "$claude" plugin marketplace list 2>/dev/null | grep -qF 'claude-plugins-official'; then
          echo "claude-code: adding claude-plugins-official marketplace (HTTPS)..." >&2
          "$claude" plugin marketplace add "$official_mp_src" 2>&1 || true
        elif "$claude" plugin marketplace list 2>/dev/null | grep -A2 'claude-plugins-official' | grep -qF 'Directory'; then
          echo "claude-code: replacing directory pin of claude-plugins-official with HTTPS..." >&2
          "$claude" plugin marketplace remove claude-plugins-official 2>&1 || true
          "$claude" plugin marketplace add "$official_mp_src" 2>&1 || true
        fi

        # This repo's OWN marketplace (plugins/), pinned to a Nix source path. Unlike the two
        # above it is not a fixed remote: the store path changes whenever any in-repo plugin
        # changes, and `plugin install` COPIES into ~/.claude/plugins/cache — so a plain
        # "already registered?" guard would keep serving a previous generation's content
        # forever. Key off the store path actually recorded in known_marketplaces.json and,
        # when it has moved, re-pin + drop the stale copies so the loop below reinstalls them.
        local_mp="${localPluginsMarketplace}"
        if ! grep -qF "$local_mp" "$known_mps" 2>/dev/null; then
          echo "claude-code: (re)pinning ${localMarketplaceName} marketplace -> $local_mp" >&2
          # Tear down the previous pin FIRST (uninstall while the marketplace still resolves),
          # silently — on a first switch there is nothing to remove and the CLI says so.
          if "$claude" plugin marketplace list 2>/dev/null | grep -qF '${localMarketplaceName}'; then
            for id in ${lib.escapeShellArgs localPluginIds}; do
              "$claude" plugin uninstall --yes "$id" >/dev/null 2>&1 || true
            done
            "$claude" plugin marketplace remove ${localMarketplaceName} >/dev/null 2>&1 || true
          fi
          "$claude" plugin marketplace add "$local_mp" 2>&1 || true
        fi

        for id in ${lib.escapeShellArgs claudePluginIds}; do
          if "$claude" plugin list 2>/dev/null | grep -qF "$id"; then
            : # already installed — idempotent skip
          else
            # Brace ''${id} — a bare `$id…` (unicode ellipsis) is one identifier under
            # bash nounset and aborts activation with "id…: unbound variable".
            echo "claude-code: installing plugin ''${id}..." >&2
            "$claude" plugin install "$id" 2>&1 || true
          fi
        done

        # Restore Nix-managed settings symlink for a clean next switch.
        if [ -n "$settings_target" ]; then
          rm -f "$settings"
          ln -s "$settings_target" "$settings"
        fi
      fi
    '';

    # Regenerate the HTML email signature (JSON Resume + bundled logo) into
    # ~/.local/share/email-signature/signature.html. Best-effort: the generator fetches
    # resume.json over the network and self-skips (keeping any existing artifact) when
    # offline, and `|| true` ensures a failed fetch never aborts a switch — it self-heals on
    # the next activation. Same "let the tool own its fetched, mutable state" pattern as
    # claudeCodePlugins / grokMcp.
    emailSignature = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${email-signature}/bin/email-signature || true
    '';
  };

}
