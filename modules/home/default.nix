# Unified user profile — loaded on EVERY machine (macOS, Pi, sandbox VM).
# The single home of "user logic"; system-level platform specifics live in
# modules/darwin and modules/nixos.
#
# Personal token VALUES are intentionally NOT managed here. On macOS they live
# in the login Keychain (encrypted at rest) — stored/registered by `secret set`
# and exported into EVERY shell (not just login ones) by the darwin-only loader
# from the keychain-secrets capsule (local.keychainSecrets), which loads once per
# process tree and lets descendants inherit. Nothing plaintext is written to disk.
# The Keychain is macOS-only, so the Linux hosts get no personal-token mechanism
# here (use one-time CLI logins: gh/hf/docker, and claude/claude-work).
#
# SYSTEM/SERVICE secrets are separate from this profile — FOUR agenix ciphertexts on
# two models (secrets/secrets.nix is the count of record): nixpi's Cloudflare tunnel
# token (secrets/cloudflared-token.age) is an
# operator-only vault (encrypted to the operator's key alone, decrypted on the Mac,
# planted on the FAT FIRMWARE partition → /run/cloudflared-token) precisely BECAUSE
# host-decryption would bind it to the SSH host key a fresh SD flash rotates (see
# hosts/nixpi.nix); the three runner secrets (gh-app-dontsell-ai-key.age,
# gh-app-fleet-key.age, gitlab-runner-token.age) ARE host-decrypted into /run/agenix
# at activation — macos's host key is stable.
#
# Deliberately MINIMAL: no nixvim — the operator uses VSCode/Cursor and
# prefers a lean profile with starship for the shell prompt. Add tools only for
# a clear cross-host need. (tmux added 2026-09-24 for persistent SSH sessions
# on nixpi.)
{
  pkgs,
  lib,
  config,
  fullName,
  userEmail,
  # The fleet's DNS zone (identityArgs in modules/parts/identity.nix). Used to build nixpi's
  # tunnelled SSH hostname below, so the domain is never re-typed.
  domainName,
  # Source-only flake inputs holding Claude Code skills (see programs.claude-code
  # below). flake.nix pins them; nothing is vendored into this repo.
  agent-skills-excalidraw,
  agent-skills-mac-automation,
  agent-skills-vercel-agent,
  grok-build-plugin-cc,
  # Source-only nixpkgs checkout read for ONE package recipe (claudeCode below).
  nixpkgs-claude-code,
  # The ABSORBED local-rag capsule (local.rag.ollama +
  # local.rag.pgvector — the loopback RAG stack) — a MODULE, not a flake,
  # since ADR-002 wave 6 brought it in-tree as modules/features/local-rag/.
  # Threaded in by modules/parts/compose.nix.
  localRagModule,
  cloudCliModule,
  # The ABSORBED keychain-secrets capsule (macOS `secret` CLI + every-shell
  # loader) — a MODULE, not a flake, since ADR-002 wave 4 brought it in-tree as
  # modules/features/keychain-secrets/. Threaded in by modules/parts/compose.nix.
  keychainSecretsModule,
  # The ABSORBED media-cli capsule (local.mediaCli — the CLIs, the launchd
  # work queue and the Finder Services) — a MODULE, not a flake, since ADR-002
  # wave 5 brought it in-tree as modules/features/media-cli/. Threaded in by
  # modules/parts/compose.nix.
  mediaCliModule,
  # Raw resume.json URL (single-sourced in modules/parts/identity.nix as jsonResumeUrl; null to
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
  # The credential-path inventory grok's sandbox deny list renders from. Shared
  # with the Claude Read() floor (./claude-guardrails.nix) so the mechanisms cannot hold
  # quietly different views of one fact — which is exactly what they did
  # until 2026-10-07. That file carries the per-layer price table.
  secretReadPaths = import ../_lib/secret-read-paths.nix;

  # The operator's Mac vs every other profile — the Linux hosts, a Tart darwin
  # guest, the template consumer. Keeps macos-only agents (RAG stack, OTel
  # collector, Claude Desktop servers) off all of them.
  isMacosHost = import ../_lib/is-macos-host.nix osConfig;
  derivedNames = import ../_lib/derived-names.nix;

  # Fonts are rendered by the machine with the SCREEN, never by an SSH target:
  # tmux/starship glyphs on nixpi are drawn by the client's terminal. So fonts go
  # where something can display them — any Mac, and no Linux host. Measured
  # 2026-10-17: the three below were ~269 MiB of nixpi's SD-card closure, with
  # fontconfig indexing 164 faces and no display service on the host to use one.
  wantsFonts = pkgs.stdenv.hostPlatform.isDarwin;

  # android-commandlinetools Homebrew cask install prefix — single source for
  # every ANDROID_HOME/PATH reference below (exported once as
  # config.home.sessionVariables.ANDROID_HOME, which the android-phone plugin's
  # mobile-mcp inherits from the session env rather than re-declaring).
  androidSdkRoot = "${brewPrefix}/share/android-commandlinetools";
  brewPrefix = import ../_lib/brew-prefix.nix osConfig;

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
  #
  # Base package: on darwin, nixpkgs-unstable's OWN recipe (the `nixpkgs-claude-code` input),
  # callPackage'd against our pkgs, while it is newer than the weekly pin's — the weekly lags
  # upstream's near-daily bumps (2026-11-07: weekly 2.1.308 vs unstable 2.1.318). Calling the
  # whole package.nix, not overriding version+src, keeps upstream's wrapper changes too
  # (makeShellWrapper + CLAUDE_CODE_CERT_STORE, absent at the weekly pin). Self-retiring: once
  # the weekly catches up, `versionOlder` picks pkgs.claude-code again — then drop the input.
  # Linux keeps pkgs.claude-code, so nixpi's closure is untouched.
  claudeCodeUnstable =
    pkgs.callPackage "${nixpkgs-claude-code}/pkgs/by-name/cl/claude-code/package.nix"
      { };
  claudeCodeBase =
    if
      pkgs.stdenv.hostPlatform.isDarwin
      && lib.versionOlder pkgs.claude-code.version claudeCodeUnstable.version
    then
      claudeCodeUnstable
    else
      pkgs.claude-code;
  claudeCode = claudeCodeBase.overrideAttrs (_: {
    doInstallCheck = false;
    __noChroot = false;
  });

  # ---- grok-build: repoint its hardcoded `read-only` sandbox at `read-only` + a credential deny ----
  # xAI's bridge hardcodes `--sandbox read-only` for every non-write run (delegate/review/
  # critique). The built-in `read-only` blocks writes to the CWD but does NOT cover
  # credentials: under it `~/.ssh`, `~/.aws`, `~/.config/gh` and `~/.docker` all list fine
  # (measured 2026-11-02, grok 1.0.45 and 1.0.50). So the bridge runs our profile instead: `read-only`
  # plus the kernel-enforced `deny` list below. A custom profile may not reuse a built-in name,
  # hence the repoint. Same probes on this profile: CWD `touch` → "Operation not permitted",
  # all four dirs DENIED, a plain read works. Retire this patch only if the built-in profile
  # ever denies those paths itself; the deny list is the whole reason it exists.
  #
  # It extended `workspace` until Docker Desktop's symlinked /run/docker.sock (gone 2026-09-16) stopped blocking `read-only`.
  #
  # NAME: a GROK sandbox profile (`[profiles.<name>]` in ~/.grok/sandbox.toml), not a macOS
  # Seatbelt profile. Its deny list renders from modules/_lib/secret-read-paths.nix.
  grokSandboxProfile = "nix-agent-read-only";

  # The sandbox profile's CONTENT, as a store file. It is copied to
  # ~/.grok/sandbox.toml at activation rather than symlinked, because grok
  # rejects a symlink there — see home.activation.grokSandboxProfile below for
  # the failure it causes. Kept next to the profile NAME so the two cannot drift apart.
  grokSandboxToml = pkgs.writeText "grok-sandbox.toml" ''
    # Managed by nix-config (modules/home/default.nix) — do not hand-edit.
    [profiles.${grokSandboxProfile}]
    extends = "read-only"
    deny = [
    ${
      # Whole dirs: grok's sandbox has no file-level granularity (secret-read-paths.nix).
      lib.concatMapStringsSep "\n" (
        d: "      \"${config.home.homeDirectory}/${d}\","
      ) secretReadPaths.agentCredentialDirs
    }
    ${lib.concatMapStringsSep "\n" (g: "      \"**/${g}\",") secretReadPaths.agentCredentialGlobs}
    ]
  '';
  grokBuildPluginPatched = pkgs.runCommand "grok-build-plugin-cc-patched" { } ''
    cp -r ${grok-build-plugin-cc} $out
    chmod -R u+w $out
    substituteInPlace $out/plugins/grok-build/scripts/grok-bridge.mjs \
      --replace-fail 'sandbox: "read-only",' \
                     'sandbox: "${grokSandboxProfile}",' \
      --replace-fail 'sandbox: write ? undefined : "read-only",' \
                     'sandbox: write ? undefined : "${grokSandboxProfile}",'
  '';

  sshDir = "${config.home.homeDirectory}/.ssh";
  operatorPrivateKey = "${sshDir}/id_ed25519";
  operatorPublicKey = "${sshDir}/id_ed25519.pub";

  # Shared by bash/zsh interactive init (GUI apps use launchd.agents.ssh-keychain-load).
  sshKeychainLoadShell = ''
    if command -v ssh-add >/dev/null 2>&1 && ! ssh-add -l >/dev/null 2>&1; then
      ssh-add --apple-load-keychain 2>/dev/null || true
    fi
  '';

  # Shells spawned by launchd agents (any `launchd.agents` unit, and whatever it
  # runs) start WITHOUT SSH_AUTH_SOCK: launchd hands the per-boot agent socket
  # (/private/tmp/com.apple.launchd.*/Listeners) to Terminal-launched shells, not to
  # a user agent's children, and a plist cannot name a path that changes every boot.
  # Without it, `git commit` with signByDefault runs `ssh-keygen -Y sign`, which
  # finds no agent and blocks forever on a passphrase prompt with no TTY (measured
  # 2026-09-24: a hung commit; the macOS agent already held the key, and
  # `launchctl getenv SSH_AUTH_SOCK` returned it). launchctl getenv is launchd's own
  # lookup; nothing is hand-rolled. Guarded so an existing socket (a Terminal shell,
  # or a forwarded agent over SSH) is never overridden. Runs for EVERY shell:
  # zsh envExtra (.zshenv) and bash profileExtra (login), not just interactive ones.
  # upstream-first: home-manager/modules/misc/ssh-auth-sock.nix (`sshAuthSock`) does
  # not fit — `systemd.socketProviderUnit` has no default (a required systemd option
  # on darwin), and its `-z "$SSH_AUTH_SOCK" -o -z "$SSH_CONNECTION"` guard re-runs
  # in every LOCAL shell (overriding a live socket), while this fills only an empty one.
  sshAuthSockFromLaunchd = ''
    if [ -z "''${SSH_AUTH_SOCK:-}" ] && [ -x /bin/launchctl ]; then
      __sock="$(/bin/launchctl getenv SSH_AUTH_SOCK 2>/dev/null)"
      [ -n "$__sock" ] && export SSH_AUTH_SOCK="$__sock"
      unset __sock
    fi
  '';

  # The ONE interactive-shell init both shells get, parameterised on the shell
  # name fnm needs. fnm: `--use-on-cd` installs a chpwd hook (interactive only),
  # honours .nvmrc/.node-version, absolute store path so it resolves before the
  # nix profile is on PATH, and falls through to the Homebrew node when no
  # project version is active. Kept in one string so bash and zsh cannot drift.
  interactiveShellInit = shell: ''
    eval "$(${pkgs.fnm}/bin/fnm env --use-on-cd --shell ${shell})"
    ${sshKeychainLoadShell}
  '';

  # `mermaid-ascii` — render Mermaid graphs as ASCII in the terminal. Packaged from
  # upstream (not in nixpkgs); see packages/mermaid-ascii.nix.
  mermaidAscii = pkgs.callPackage ../../packages/mermaid-ascii.nix { };
  # `git-tidy` — default branch, fast-forwarded, merged-PR branches deleted via gh-poi;
  # see packages/git-tidy.nix.
  gitTidy = pkgs.callPackage ../../packages/git-tidy.nix { };
  androidPhone = pkgs.callPackage ../../packages/android-phone.nix { inherit brewPrefix; };
  nixosVm = pkgs.callPackage ../../packages/nixos-vm.nix { };
  # `activate` — self-elevating `darwin-rebuild switch`. nix-darwin dropped sudo
  # self-elevation in its 2025-01-30 root migration and ships no option to
  # restore it (grepped the pinned modules/ for sudo|elevate|rebuild|activate);
  # see packages/activate.nix for why this is a wrapper and not a sudoers rule.
  darwinActivate = pkgs.callPackage ../../packages/activate.nix { };

  # `jsonresume <download|print>` — fetch a JSON Resume and render it to PDF via the
  # npm resume CLI. jsonResumeUrl (from modules/parts/identity.nix) is baked in as its default --url,
  # so there is no ambient env var. See packages/jsonresume.nix.
  # OPERATOR-ONLY — gated on isMacosHost (local.operatorHost, set only in hosts/macos.nix), so a template consumer gets none of it.
  jsonresume = pkgs.callPackage ../../packages/jsonresume.nix {
    defaultUrl = jsonResumeUrl;
  };

  # `email-signature` — render a paste-ready HTML email signature from the same JSON Resume
  # (jsonResumeUrl baked as its default --url) plus the logo.svg fetched from the same gist
  # (logoUrl), rasterized via librsvg. Also run on activation (home.activation.emailSignature)
  # and `nix run .#email-signature`. See packages/email-signature/ (default.nix).
  # OPERATOR-ONLY — gated on isMacosHost (local.operatorHost, set only in hosts/macos.nix), so a template consumer gets none of it.
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

  # `gmail-filters` — gmailctl over a Drive-held filter file (packages/gmail-filters.nix).
  gmail-filters = pkgs.callPackage ../../packages/gmail-filters.nix { };

  # `jobspy --search "…" --location "…"` — scrape jobs from multiple boards into
  # CSV/JSON via the off-the-shelf python-jobspy library (run in an ephemeral uv env).
  # See packages/jobspy.nix.
  jobspy = pkgs.callPackage ../../packages/jobspy.nix { };

  # `resend` — the official Resend CLI, injecting RESEND_API_KEY from the login Keychain
  # at run time (non-interactive, no browser OAuth). See packages/resend-cli.nix.
  resendCli = pkgs.callPackage ../../packages/resend-cli.nix { };

  # rclip, with its runtime-dependency CHECK disabled — not its dependencies changed.
  # rclip 3.3.0's wheel declares `coremltools` as a runtime dep on macOS (the Apple
  # Silicon fast path for indexing), but the nixpkgs package does not provide it, so
  # `pythonRuntimeDepsCheckHook` fails the build outright on aarch64-darwin:
  #     Checking runtime dependencies for rclip-3.3.0-py3-none-any.whl
  #       - coremltools not installed
  # The dependency is genuinely OPTIONAL — rclip falls back to CPU ONNX, which is
  # fine for ViT-B/32 — so the check is reporting a metadata mismatch, not a broken
  # program. Verified with the override: it builds, and `rclip --version` runs.
  #
  # STAYS HERE, not in the media-cli capsule: rclip is a third-party search tool
  # this repo merely installs, and it is the VECTOR half of the retrieval story —
  # deliberately independent of the XMP half. It reaches the media stack through
  # that capsule's `extraSearchPackages` seam, which exists for exactly this.
  #
  # NO GATE BUILDS THE DARWIN CLOSURE (flake check and CI only evaluate it), so
  # a package override that cannot build first fails at `activate` — this one
  # did. Build it yourself: nix build .#darwinConfigurations.macos.system
  # (docs/map/entry-points.md, "No gate BUILDS the darwin closure").
  rclipCli = pkgs.rclip.overridePythonAttrs (_: {
    dontCheckRuntimeDeps = true;
  });

  androidEmu = pkgs.callPackage ../../packages/android-emu.nix { inherit androidSdkRoot brewPrefix; };

  # "Focus-or-launch" Spotlight .app bundle for the Android emulator
  # (macos host only, below) — see packages/spotlight-launchers.nix.
  spotlightLaunchers = pkgs.callPackage ../../packages/spotlight-launchers.nix {
    inherit brewPrefix;
  };

in
{
  imports = [
    # Every launchd agent gets a `nix-<name>` arg0 whose interpreter is
    # store-resident. This was a 560-line vendored fork of home-manager's launchd
    # module until 87c391f made it expressible upstream; see the file for why the
    # arg0 is load-bearing (TCC attribution) rather than cosmetic.
    ./launchd-launcher.nix
    # The media stack — CLIs, the launchd work queue, and the Finder right-click
    # Services — is ONE option. Everything this block used to spell out (the
    # .workflow copy loop, the bundle-id cleanup, the two launchd agents, the
    # macos-only gate on a closure too big for a Tart guest) lives in the
    # media-cli CAPSULE's own module, which owns the reasoning along with the
    # code. See `local.mediaCli` below. Imported UNCONDITIONALLY — it is
    # internally gated on (enable && isDarwin), and `checks.media-cli-inert`
    # asserts that an unset `enable` contributes nothing at all, which is the
    # state the NixOS hosts are in.
    mediaCliModule
    # Keeps the Tor Browser profile out of Time Machine (the cask lives in
    # hosts/macos.nix). Internally gated on isMacosHost (local.operatorHost) — tmutil
    # exists on no Linux host. PRE-EMPTIVE: there is no TM destination configured today;
    # see the file's header for what it does and does NOT cover.
    ./tor-browser-backup-exclusion.nix
    # THIS MODULE BUILDS MCP LAUNCHERS (other plugin-named MCP binaries sit in
    # home.packages below). The gateway (modules/shared/mcp.nix) was deleted in #734;
    # these launchers are how the servers that had no plugin owner survived it. Each
    # puts a binary on PATH that a plugin's `.mcp.json` names as its `command` (in
    # github:kattakath/skills), because that file can
    # set `env` only to literals or passthroughs and cannot run a Keychain read or a
    # `sandbox-exec` fence (desktop-commander's, until 2026-11-01). See each module's header.
    ./plugin-mcp.nix # PATH launcher shapes; see its header
    # NOTE for anything added to modules/home/ later: THIS LIST is the only entry
    # point for that directory. A module dropped in there and not named here is
    # silently inert.
    # No Claude Desktop writer: modules/home/claude-desktop.nix was RETIRED 2026-11-02
    # (operator decision D4). Desktop CHAT runs no plugin stdio server and its MCP now
    # comes only from claude.ai connectors (docs/claude-desktop-mcp.md).
    ./terminal-theme.nix # the fleet terminal palette + type, held once (read by Ghostty and VS Code below)
    ./terminal-app.nix # Terminal.app type + colours (all darwin)
    ./fleet-gauges.nix # hourly credential-expiry / security-alert / backup gauges (macos only)
    ./terranix-drift.nix # daily drift check over every terranix stack (macos only)
    ./page-lab.nix # page-lab's pinned dedicated-mode browser + profiles overlay (macos only)
    ./claude-otel.nix # local OTel Collector for Claude Code's routing-decision telemetry (macos only)
    # Makes ~/.claude/settings.json LAYERED — a real writable file the app and
    # the operator can edit, with Nix's own keys (the permissions.deny floor,
    # attribution, env) merged back in on every rebuild. Upstream renders it
    # `install -Dm444` into the store, which is why the model picker could not
    # be changed. Must be imported AFTER nothing in particular, but it disables
    # upstream's home.file entry, so it has to be loaded at all — which this
    # explicit list, not auto-discovery, is what guarantees.
    ./claude-code-settings.nix
    ./chromium.nix # ungoogled-chromium (Homebrew cask) config: sideloaded iCloud Passwords + its native host
    ./default-browser.nix # local.defaultBrowser — the macOS LaunchServices http/https claim
    ./kdeconnect.nix # local.kdeConnect — merges declared keys into the kde-connect cask's INI files
    ./containers.nix # local.containers — per-user Colima (services.colima) replacing the Docker Desktop cask
    ./beancount.nix # local.beancount — Beancount CLIs + Fava (on demand) + LSP, one interpreter
    # The two loopback download servers. They were nix-darwin `launchd.user.agents`
    # until 2026-09-22; moved here because Home Manager re-bootstraps an agent that
    # has left its launchd domain and the system tier does not (see either header).
    ./metube.nix # local.meTube — MeTube on 127.0.0.1:8081 for the Chrome extension
    ./yt-dlp-web-ui.nix # local.ytDlpWebUi — yt-dlp-web-ui on 127.0.0.1:3033
    # The two inbox Trash sweeps — the SAME move, 2026-10-02, for the same
    # self-heal (the Maccy login opener moved with them and was retired
    # 2026-10-27 for Maccy's own launch-at-login). Their Labels are pinned to
    # the live ones (BTM toggle state is keyed to the Label), which is the one
    # thing the two servers above did not need. macos-gated internally, on osConfig.
    ./macos-user-agents.nix
    # Local-first RAG stack (loopback launchd Postgres+pgvector + Ollama + in-DB
    # embed()) — the ABSORBED capsule (modules/features/local-rag/). Both of its
    # modules are internally gated on (enable && isDarwin) — a clean no-op on
    # the NixOS hosts, which `checks.local-rag-inert` asserts — and they are
    # enabled only on the real Mac host below.
    localRagModule
    # The AWS CLI + ~/.aws/config.example capsule (ADR-004 phase 3). Enabled per
    # user (hosts/macos.nix); a no-op here until then.
    cloudCliModule
    # macOS login-Keychain `secret` CLI + every-shell loader — the ABSORBED
    # capsule (modules/features/keychain-secrets/), enabled below.
    # Internally darwin-gated, so it's a clean no-op on the NixOS hosts.
    keychainSecretsModule
    # Gate CLAUDE_CODE_USE_BEDROCK (Keychain, survives every activation) on an
    # AWS identity NO repo declares — ~/.aws/config is runtime state owned by the
    # `aws` CLI — so a Mac carrying the flag without a usable identity degrades
    # Claude Code to its default provider instead of leaving it unable to reach
    # any model at all. Must live in this public repo: a gate shipped from a
    # hand-placed overlay would be dropped by the activation it defends against.
    ./claude-bedrock-gate.nix
    # "Brain Signals" — the answer-shape kit for Claude Code (output style +
    # calibration rule + /explain-family skills + cartographer + /task). Public
    # because claude/CLAUDE.md already carries the same accessibility rule in
    # prose; this is the mechanism that satisfies it. Every content class it
    # touches is attrsOf-merging, so a private layer or a fork ADDS to it.
    ./claude-brain.nix
    # Claude Code plugin marketplaces, N of them: the register-and-install
    # mechanism, driven by the `local.claudePlugins.marketplaces` attrset this
    # file fills below. attrsOf, so a layer composed in through `extraHomeModules`
    # ADDS its own marketplace instead of copying the activation script — which is
    # exactly what the private [redacted] flake did before it was retired
    # 2026-09-15.
    ./claude-plugins.nix
    # The GLOBAL guardrail floor: user-scope permissions.deny for every repo on
    # this Mac. Project hooks in .claude/ only ever covered this repo.
    ./claude-guardrails.nix
    # `claude` (personal) + `claude-work`: one CLAUDE_CONFIG_DIR per account on darwin —
    # separate logins, transcripts and org policy, shared content.
    ./claude-profiles.nix
  ];

  # Enable the keychain-secrets capsule's module (installs the secret/set-secret/
  # remove-secret CLIs + the ~/.config/secrets/loader.sh every-shell loader).
  local.keychainSecrets.enable = true;

  # The ONE claude-code derivation: the profile wrappers (./claude-profiles.nix) exec it
  # by store path, and claude-plugins.nix runs `plugin marketplace add` with it.
  local.claudeProfiles.package = claudeCode;

  # The whole media stack, from the media-cli capsule: the CLIs, the durable
  # launchd work queue, and the Finder right-click Services. macos ONLY —
  # MEASURED, the closure (ffmpeg, exiftool, auge, rclip's OpenCLIP model) is too
  # much for a Tart guest's disk, so a sandbox gets neither the CLIs nor the menu.
  # This one gate is now the entire "which hosts get the media stack" decision.
  # OPERATOR-ONLY — gated on isMacosHost (local.operatorHost, set only in hosts/macos.nix), so a template consumer gets none of it.
  local.mediaCli = {
    enable = isMacosHost;
    # `auge` is Apple's Vision framework from the shell — media-describe already
    # has it hermetically, this puts it on PATH for direct use ("is this shot any
    # good", "is anyone blinking"). `rclipCli` is the VECTOR half of retrieval,
    # deliberately kept out of the capsule (see its override above).
    extraSearchPackages = [
      pkgs.exiftool
      pkgs.auge
      rclipCli
    ];
  };

  # Ghostty's tab bar, kept visible even at one tab. NOT settable from
  # programs.ghostty: `window-show-tab-bar` is documented "currently only
  # supported on Linux (GTK)", there is no `toggle_tab_bar` action to bind, and
  # the View > Hide Tab Bar item carries no key equivalent — on macOS the bar is
  # AppKit's, not Ghostty's. So the only handle is the visibility AppKit itself
  # persists when you pick View > Show Tab Bar.
  #
  # The key is a COMPOSITE of window class and state, valid ONLY for this exact
  # combination: `macos-titlebar-style = "tabs"` (hence `TitlebarTabs`) on macOS
  # 26 (hence `Tahoe`). A macOS major bump, or dropping the `tabs` titlebar,
  # renames the class and this silently stops matching — re-read
  # `defaults read com.mitchellh.ghostty` and update it. "Shoud" is Apple's typo
  # in the key name, not ours; correcting it breaks the match.
  targets.darwin.defaults = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    "com.mitchellh.ghostty"."NSWindowTabbingShoudShowTabBarKey-Ghostty.TitlebarTabsTahoeTerminalWindow-Ghostty.TerminalWindow" =
      true;
  };

  # RAG stack (Ollama + pgvector) backs the postgres MCP server — real Mac only.

  local.rag.ollama.enable = isMacosHost;
  # The SERVER moved to a machine-wide daemon (`local.ollamaDaemon`,
  # modules/darwin/ollama-daemon.nix) so every account shares one process and
  # one 31 GB model store. The capsule keeps everything else — the embed model,
  # its dimension, and the one-shot pull agent, which now targets a server it
  # does not own.
  local.rag.ollama.manageServer = false;
  # ONE endpoint: both capsules default to 127.0.0.1:11434 independently and may
  # not reach out, so the daemon's coordinates are threaded in here. No `or`
  # fallback — isMacosHost implies hosts/macos.nix, which imports the daemon.
  services.ollama = lib.mkIf isMacosHost { inherit (osConfig.local.ollamaDaemon) host port; };
  local.mediaCli.ollamaHost = lib.mkIf isMacosHost "${osConfig.local.ollamaDaemon.host}:${toString osConfig.local.ollamaDaemon.port}";

  # Server tuning lives in `local.ollamaDaemon.environmentVariables`; `services.ollama`'s would reach no server.

  local.rag.pgvector.enable = isMacosHost;

  # dontsell-ai/app's LOCAL dev database, in the same loopback cluster as the
  # RAG store but a separate db + scoped role (blast radius = one database).
  # Declared here because the run-wrapper rewrites pg_hba.conf with a
  # truncating redirect on every launch: a hand-added entry — which is what
  # the app repo's CLAUDE.md used to instruct — silently disappears at the
  # next restart and the app then fails with `no pg_hba.conf entry for host
  # "127.0.0.1"`. Diagnosed 2026-09-21 after exactly that.
  local.rag.pgvector.extraDatabases = lib.mkIf isMacosHost [
    {
      db = "dontsell_dev";
      role = "dontsell";
    }
  ];

  # Claude Code routing telemetry collector — real Mac only (same gate
  # as the RAG stack above). See modules/home/claude-otel.nix and
  # the programs.claude-code.settings.env block below that points Claude Code
  # at it.
  local.claudeOtel.enable = isMacosHost;
  # ADR-011: metrics (never logs) also go to Grafana Cloud, identity stripped.
  local.claudeOtel.grafana.enable = isMacosHost;
  local.fleetGauges = {
    enable = isMacosHost;
    cloudflareItems = with (import ../_lib/keychain-items.nix).cloudflare; [
      api
      nixpiTunnel
      dontsellDns
    ];
    # githubOrgs, githubUsers, gcomRegions and sdReleaseRepo are operator values, set from
    # config.fleet in modules/parts/hosts.nix.
  };
  # ADR-012 § 5 step 1. `package` comes from modules/parts/hosts.nix (engine-built).
  local.terranixDrift.enable = isMacosHost;

  # ungoogled-chromium's declarative surface — real Mac only, since only
  # hosts/macos.nix declares the cask. Writes
  # the External Extensions + NativeMessagingHosts files that make the sideloaded
  # iCloud Passwords extension talk to macOS Passwords.app; see chromium.nix.
  local.ungoogledChromium.enable = isMacosHost;

  # page-lab's DEDICATED browser (Chrome for Testing from nixpkgs), never the daily
  # Chromium above. Operator Mac only: the closure is ~370 MiB. See page-lab.nix.
  local.pageLab.enable = isMacosHost;

  # Google Chrome owns http/https; Chromium stays the DEBUGGING browser, not the daily
  # one. The claim itself is browser-agnostic and lives in ./default-browser.nix — the
  # short handler name is what `defaultbrowser` takes, never the bundle id (it is the
  # last dot-component of the bundle id, lowercased: `com.google.Chrome` → `chrome`,
  # `org.chromium.Chromium` → `chromium`). Only the real Mac declares any browser cask,
  # so this is a no-op elsewhere.
  #
  # WHY NOT CHROMIUM, which is what this Mac had drifted to live: PASSKEYS. Reaching a
  # macOS Passwords.app passkey needs `com.apple.developer.web-browser.public-key-credential`,
  # a RESTRICTED entitlement Apple grants per-Team-ID to registered browser vendors on
  # request. Measured 2026-09-15 with `codesign -d --entitlements`: the ungoogled-chromium
  # cask carries SEVEN entitlements, all hardware/sandbox (camera, bluetooth, usb, …), no
  # passkey grant and no `keychain-access-groups` at ALL — so neither the iCloud Keychain
  # nor the profile Touch ID authenticator can work. Opera/Opera Air both carry the grant
  # plus `…webauthn`, `…webauthn-uvk` and Google's own `com.google.common.folsom` group;
  # Chrome carries it too, and Safari has the WebKit equivalent.
  #
  # So this is NOT fixable by swapping Chromium builds, and the obvious swap is worse: the
  # plain (googled) `chromium` cask is DISABLED in Homebrew since 2026-09-01 for failing
  # the Gatekeeper check, i.e. not Developer-ID notarized — and a restricted entitlement
  # needs an Apple-authorized Team ID to carry it. A community rebuild
  # can never obtain the grant — do not re-attempt this with a different Chromium.
  #
  # The sideloaded iCloud Passwords extension does not rescue it either: that extension
  # does PASSWORDS (and verification codes). On macOS a passkey comes from the OS
  # AuthenticationServices API the browser itself calls, never through an extension.
  local.defaultBrowser = lib.mkIf isMacosHost "chrome";

  # KDE Connect (the `kde-connect` cask in hosts/macos.nix). These values pin what the
  # Mac already runs, so an upstream default change cannot silently flip them:
  # only loopback is on the disabled-provider list (upstream also lists bluetooth), and clipboard
  # auto-share stays on, including password-manager copies (`sendPassword`). The
  # device name is left to the app, which derives it from the hostname.
  local.kdeConnect = lib.mkIf isMacosHost {
    enable = true;
    settings.General.disabled_providers_v2 = [ "loopback" ];
    # OFF until the cask bundles Qt >= 6.11.2. On macOS 27.2 its Qt 6.11.1 hits
    # QTBUG-147602: the first phone notification with an icon traps kdeconnectd in
    # QImage::toCGImage -> CGImageCreate, which takes the whole link (clipboard too) down.
    # Crash captured 2026-10-31. Re-enable after checking the bundled QtGui version.
    # 26.08.2 and the master nightly (build 6836) still bundle Qt 6.11.1, measured 2026-10-31.
    # AirSync (the obvious alternative) was REJECTED the same day: its Android app falls back to
    # plaintext when decryption fails, takes an unauthenticated "connect to this Mac" POST on
    # :8888, and the Mac writes received files under an unsanitised name.
    plugins.kdeconnect_notifications = false;
    pluginSettings.kdeconnect_clipboard = {
      autoShare = true;
      sendPassword = true;
    };
  };

  # The Claude Code plugin set — DATA only; the registration + install mechanism
  # is ./claude-plugins.nix. It is a keyed attrset so that a layer composed in
  # through `extraHomeModules` adds its own marketplace and the ones declared
  # below survive untouched. `plugins` is a listOf, so such a layer
  # can even append a plugin to a marketplace declared here.
  #
  # `source` is mkDefault throughout so a downstream layer can repoint one (a
  # fork of the official marketplace, say) with a plain assignment.
  local.claudePlugins.marketplaces = {
    # xAI's grok-build bridge, from a PATCHED store copy of the pinned flake
    # input (grokBuildPluginPatched in the let block above — read it for WHY the
    # built-in `read-only` sandbox had to be repointed). Store path ⇒ the ONE
    # marketplace claude-plugins.nix still touches imperatively, and only to
    # spare the first session after a bump — a directory-source plugin loads
    # LIVE from the marketplace dir (measured 2026-09-30), so the patch reaches
    # Claude Code with no cache copy to go stale.
    # Runtime: the `grok` binary (nixpkgs' grok-build, shared via environment.systemPackages)
    # + Node — the bridge shells out to `grok models`. Remove that package only together
    # with this plugin and its flake input.
    xai-grok-build = {
      source = lib.mkDefault "${grokBuildPluginPatched}";
    };

    # Anthropic's official marketplace (`claude-plugins-official`) is NOT declared here
    # since 2026-11-07: its plugins are installed from claude.ai and arrive as `<name>@synced`
    # (account sync), one source instead of a second Nix-declared copy that shadows them.
    # Decisions that outlive the move, re-check them when adding a plugin there:
    #   - neon/slack/aws-core/aws-serverless servers stay denied (deniedMcpServers, matched by
    #     `plugin:<name>:<server>`, so the synced copy is covered); the connectors win.
    #   - NOT installed: code-simplifier (strict subset of pr-review-toolkit), code-review
    #     (shadows the more capable built-in /code-review), databases-on-aws (ships servers
    #     marked `disabled` that start anyway), the context7 copy (server only; see below).
    #   - commit-commands bakes in no AI-attribution trailer (grepped 2026-09-29); re-grep on
    #     an upstream bump. hookify runs Python hooks on every tool call and prompt.
    #   - plugin-dev/hookify skills are NOT in the `skills` attrset below, to avoid a second
    #     copy from a different pin.

    # Upstash's OWN marketplace (github:upstash/context7), HTTPS — the KEY must be the name upstream declares
    # in its .claude-plugin/marketplace.json ("context7-marketplace"), because
    # The plugin id is "<plugin>@<key>".
    #
    # WHY NOT the `context7` entry in claude-plugins-official: Anthropic's copy
    # is `external_plugins/context7`, which carries a .mcp.json and NOTHING else
    # — no skill, no agent, no command. It would add a second MCP server and
    # zero behaviour. The value here is the SKILL: skills/context7-mcp's
    # description auto-triggers on "setup/config questions, code involving
    # libraries, API references, framework names", so Context7 gets consulted
    # without the operator naming the tool. It also brings a docs-researcher
    # subagent (sonnet — keeps fetched docs out of the main context) and
    # /context7:docs.
    #
    # THE DUPLICATE IS GONE: the plugin's own .mcp.json registers context7 at
    # mcp.context7.com (headers from a node headersHelper reading
    # CONTEXT7_API_KEY). That was a SECOND path to one service while the
    # gateway's mcp__plugin_hm_context7__* existed, keyed from the login
    # Keychain; it died with the gateway 2026-10-02, so
    # mcp__plugin_context7_context7__* is the only path now — anonymous unless
    # CONTEXT7_API_KEY is exported into Claude Code's env. There is nothing left
    # to de-duplicate: the plugin's `.mcp.json` is the ONLY path to Context7, so
    # it is taken unmodified, which also keeps it a plain upstream pin.
    #
    # NOTE for the upstream-first rule (.claude/rules/upstream-first.md):
    # Context7 serves a CRAWLED snapshot, not this flake's pinned inputs. It is
    # a lead; the citable grep still has to run against flake.lock.
    context7-marketplace = {
      source = lib.mkDefault "https://github.com/upstash/context7.git";
      autoUpdate = true;
    };

    # This operator's OWN published marketplace, github:kattakath/skills, as a
    # GIT source with auto-update, not a pinned store path. Content ships from that repo alone: its
    # plugins carry no `version`, so every commit on its `main` is a new version,
    # and Claude Code's background refresh delivers it with the "updated" notice.
    # The gate is that repo's own CI (`claude plugin validate`, script checks).
    #
    # WHY NOT THE flake.lock PIN it used until 2026-09-23. A store path is a
    # `directory` marketplace, which Claude Code never refreshes, so every plugin
    # edit needed a pin bump here plus an activation. Plugins are runtime-owned
    # content (ADR-003 §1.4); this repo declares WHICH marketplace;
    # the remote decides what it contains. ADR-003 §10 records that
    # this moves the version decision out of flake.lock for plugins.
    #
    # The `kattakath-skills` flake input still exists, for ONE PATH package built
    # from a plugin script (`page-lab-pick`), and `checks.<system>.mcp-launcher-parity`,
    # which checks that each `nix-mcp-*` launcher this fleet builds is run by its pinned
    # plugin. No plugin or skill is read from the
    # input, and no home-manager module takes it at all: every consumer lives
    # in the flake engine and reads `inputs.kattakath-skills` directly.
    #
    # Adding or changing a plugin = a merge IN THAT REPO; nothing to list here.
    kattakath = {
      source = lib.mkDefault "https://github.com/kattakath/skills.git";
      autoUpdate = true;
    };

    # ---- UPSTREAM marketplaces
    # (added 2026-09-30, kattakath/nix-config#650) -----------------------------
    #
    # These upstream repos publish their
    # OWN .claude-plugin/marketplace.json. Declaring those marketplaces is the
    # off-the-shelf route to the same content: the upstream owns the packaging, the
    # skill set, and the release discipline, and this repo stops cherry-picking
    # subdirectories out of a tarball.
    #
    # Registering a marketplace INSTALLS NOTHING — it only makes `<plugin>@<marketplace>`
    # resolvable. Enabling is the operator's `/plugin` toggle (runtime state, not Nix). Remove a
    # skills-only input only after its plugin is enabled AND seen in a session.
    #
    # `autoUpdate = true` on every https marketplace (operator decision 2026-11-12: "the
    # plugins are curated by me; even if they're from other marketplaces, everyone should
    # get them auto-updated"). The curation is the gate: which marketplaces are declared
    # here, and which plugins get enabled. Accepted cost: whatever lands on an upstream
    # `main` reaches this Mac on a background refresh without a per-commit review.
    # Measured 2026-11-12: with it unset, a marketplace silently stayed 4 releases behind.
    # A /nix/store marketplace (xai-grok-build) can't auto-update; Nix updates it.
    #
    # LICENCE, and why marketplace-not-vendor is the RIGHT shape here:
    # `trailofbits/skills` is CC-BY-SA-4.0 — a share-alike licence. Consuming it as
    # a marketplace leaves the bytes upstream, under their licence, with their
    # attribution intact; republishing those skills into `kattakath/skills` (the
    # alternative, since that is where this fleet's own plugins live) would put
    # CC-BY-SA content into a repo that is not CC-BY-SA, plus 44 forked copies to
    # keep in step with upstream.
    #
    # Every KEY below is the `name` field of that repo's own
    # .claude-plugin/marketplace.json, fetched and read 2026-09-30 — NOT the repo or
    # org name. The plugin id is
    # "<plugin>@<key>", so a guessed key silently resolves nothing.
    #   trailofbits/skills    -> "trailofbits"                (44 plugins)
    #   Jeffallan/claude-skills -> "fullstack-dev-skills"     (1 plugin, 2026-11-07)

    # Trail of Bits (CC-BY-SA-4.0), no flake input. 44 plugins. See the licence note above — share-alike is a
    # positive reason to consume this as a marketplace rather than vendor it.
    trailofbits = {
      source = lib.mkDefault "https://github.com/trailofbits/skills.git";
      autoUpdate = true;
    };

    # Upstream marketplace that replaces a cherry-picked `agent-skills-*` skill (2026-11-07,
    # operator: Nix registers, the plugin is enabled at runtime). MIT. Accepted cost:
    # the plugin is the WHOLE bundle — fullstack-dev-skills ships 67 skills (we used
    # postgres-pro).
    fullstack-dev-skills = {
      source = lib.mkDefault "https://github.com/Jeffallan/claude-skills.git";
      autoUpdate = true;
    };
  };

  # Spotlight-launchable "Android Emulator" — click (or re-click) like any
  # normal app: launches if not running, brings the existing window frontmost
  # if it is. Real Mac only. Planted (recursive) into ~/Applications, which Spotlight
  # indexes; see packages/spotlight-launchers.nix. First launch prompts a
  # one-time Automation permission ("wants to control System Events") —
  # approve it in System Settings > Privacy & Security > Automation.
  home.file."Applications/Android Emulator.app" = lib.mkIf isMacosHost {
    source = spotlightLaunchers.androidEmulatorApp;
    recursive = true;
  };

  # qBittorrent — FOSS torrent client, picked over Transmission for its
  # network-interface binding (VPN kill-switch), built-in search and RSS rules.
  # From nixpkgs, NOT the cask: Homebrew DISABLED `qbittorrent` on 2026-09-01
  # (fails Gatekeeper), so `brew bundle` errors on it. Planted like the bundle
  # above rather than via home.packages, because linkApps' "Home Manager Apps"
  # is a symlink into /nix/store that Spotlight does not index. Not
  # `targets.darwin.copyApps` either: its default needs stateVersion >= 25.11
  # (this profile is 24.05), it nests bundles in a subfolder, and it needs an
  # App Management TCC grant — a click per Mac.
  home.file."Applications/qBittorrent.app" = lib.mkIf isMacosHost {
    source = "${pkgs.qbittorrent}/Applications/qbittorrent.app";
    recursive = true;
  };

  # HM fontconfig is OFF on every host. Linux hosts get no HM fonts at all
  # (`wantsFonts` is darwin-only), and an explicit `false` is needed there:
  # home-manager's default follows NixOS' `fonts.fontconfig.enable` (true) when
  # `useUserPackages` is on. On macOS this is NOT what makes fonts visible:
  # pinned home-manager targets/darwin/fonts.nix already rsyncs every package's
  # share/fonts into ~/Library/Fonts/HomeManager unconditionally. And it is not
  # a no-op there either: fontconfig.nix:315-350 is not platform-gated, so it
  # was adding two dummy packages and running `fc-cache -f` on every darwin
  # profile build for nothing. A future Linux desktop that wants HM fonts turns
  # BOTH this and `wantsFonts` on for its host.
  fonts.fontconfig.enable = false;

  # PERSONAL, cross-host packages only — tools wanted on EVERY machine, not
  # project toolchains (those live in each repo's own devShell). claude-code is
  # the one CLI kept here: genuinely personal, used in every repo.
  #
  # gh / git-lfs stay OUT of this list — they come from their `programs.*`
  # modules below (listing them here too would be a buildEnv /bin collision).
  #
  # Fonts: the two Nerd Fonts wired to VS Code settings, plus Inter as a general
  # proportional UI face — appended below behind `wantsFonts`, not in this shared
  # list. nixpkgs unstable uses the per-font `nerd-fonts.<name>` attrs (24.05+
  # restructure), not the old `(nerdfonts.override { ... })`.
  home.packages =
    with pkgs;
    [
      fh # FlakeHub CLI — flake input publishing/management, wanted on every host
      tmux # persistent terminal multiplexing — mainly for long-running sessions over SSH on nixpi
      # Terminal background switcher, backing the red/green/blue aliases in
      # programs.zsh below. Off-the-shelf rather than three hand-rolled printfs:
      # it emits the same OSC 10/11/12 but also wraps them for tmux passthrough
      # and swaps to iTerm2's \033]Ph form, neither of which a bare printf does.
      theme-sh
      # Postgres lives in the local-rag capsule, NOT here. See pgvector-local.nix's
      # `pgPkg` — it is what puts a pgvector-capable postgresql_16 in this profile.
      # No second `hiPrio` postgres here: it made the capsule's superset lose and bloated nixpi.
    ]
    # claude-code: on darwin it is installed by the programs.claude-code module
    # below (which also owns the plugin/marketplace state and the global
    # CLAUDE.md). On the Linux hosts we don't enable that module, so install
    # the bare CLI here instead.
    # Avoids a buildEnv /bin collision.
    ++ lib.optionals (!stdenv.hostPlatform.isDarwin) [ claudeCode ]
    # Fonts only where they can be rendered (`wantsFonts`, above).
    ++ lib.optionals wantsFonts [
      nerd-fonts.jetbrains-mono # "JetBrainsMono Nerd Font" — VS Code editor font (pairs with the JetBrains theme)
      nerd-fonts.ubuntu-mono # "UbuntuMono Nerd Font" — VS Code terminal font (matches the devcontainer)
      inter # "Inter" — proportional UI font; no Nerd Font variant exists (NF only patches monospace fonts), so this is the plain upstream package
    ]
    # secret/set-secret/remove-secret now come from local.keychainSecrets
    # (the keychain-secrets capsule's HM module), not this list.
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      darwinActivate # `activate [extra darwin-rebuild args]` — `darwin-rebuild switch` that re-execs under sudo, so a forgotten `sudo` becomes the Touch ID sheet instead of exit 1; names the flake + branch/rev it is about to activate first (packages/activate.nix)
    ]
    # androidEmu needs the android-commandlinetools cask, which only hosts/macos.nix installs.
    # Kept at this position so the package order (and the macos closure) is unchanged.
    ++ lib.optional isMacosHost androidEmu
    # OPERATOR-ONLY (codecov-cli, and inngest/stripe-cli/wp-cli below): split in place so the
    # package order, and so the macos closure, is unchanged.
    ++ lib.optionals isMacosHost [
      codecov-cli # Codecov CLI (`codecovcli`) — upload coverage reports / local upload from CI; reads the CODECOV_TOKEN env var (a Keychain secret, never in this repo)
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      # awscli2 is NOT here: the cloud-cli capsule's programs.awscli owns it (local.cloudCli.aws).
      fnm # Fast Node Manager — no `programs.fnm` HM module in this pinned home-manager; hook: interactiveShellInit
    ]
    # OPERATOR-ONLY: the three gist-fed tools (jsonResumeUrl / logoUrl / tokensUrl)
    # are installed only on the macos host, never on a template consumer's Mac.
    ++ lib.optionals isMacosHost [
      jsonresume # `jsonresume download|print|validate|markdown|text` — fetch a JSON Resume (default URL from jsonResumeUrl, or --url) + render PDF via resumed (fallback resume-cli); md/text via resume-cli (packages/jsonresume.nix)
      email-signature # `email-signature` (flags: `email-signature --help`) — render a self-contained HTML email signature (JSON Resume + gist logo, base64-embedded) to ~/.local/share/email-signature/signature.html; also regenerated on activation (packages/email-signature/)
      design-tokens # `design-tokens [--tokens-url URL] [--out DIR]` — transform the gist DTCG tokens.json into SCSS/CSS/JS via Style Dictionary, to ~/.local/share/design-tokens/ (packages/design-tokens/)
    ]
    # OPERATOR-ONLY: the filter file is the operator's data (a Drive folder) and the OAuth
    # client is his Keychain item, so a template consumer gets nothing from this.
    ++ lib.optionals isMacosHost [
      gmail-filters # `gmail-filters <login|download|diff|test|apply>` — Gmail filters + labels as gmailctl Jsonnet in Drive, client from the Keychain, token 0600 under XDG state (packages/gmail-filters.nix, ADR-012 § 5 step 4)
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      # PREREQUISITE for the MCP ownership split (#657): the `nixos` server moves
      # out of the gateway into the nix-flake-kit plugin, and a plugin's
      # `.mcp.json` can only name a bare command on PATH — it cannot carry a
      # `/nix/store/...` path, which rotates on every rebuild, and the plugin file
      # lives in another repo besides. Measured 2026-09-30: `npx` resolves,
      # `uvx`/`uv`/`mcp-nixos` do NOT, so without this the plugin spawns nothing.
      #
      # WHY THE NIXPKGS BINARY RATHER THAN `pkgs.uv` + `uvx mcp-nixos`: a pinned
      # build beats a runtime PyPI fetch — same content every time, one source of
      # truth, and no network at spawn.
      #
      # Plain `pkgs.mcp-nixos` builds clean; do not add `doCheck = false`.
      mcp-nixos # `mcp-nixos` — grounded, READ-ONLY NixOS/nixpkgs option+package lookup; no token
      #
      # uv: the same PREREQUISITE shape, for an enabled plugin whose `.mcp.json`
      # names bare `uvx`.
      uv # `uv`/`uvx` — ephemeral Python tool runner; on PATH for an enabled plugin whose `.mcp.json` names bare `uvx`
      #
      # Language servers: the same PREREQUISITE shape, for LSP plugins whose `.lsp.json`
      # names a bare command (pyright-lsp / typescript-lsp from the official marketplace,
      # nixd from kattakath/skills). Enabling those plugins is runtime state, not Nix.
      # nixd was devShell-only before (modules/parts/devshell.nix), so no LSP outside it.
      pyright # `pyright-langserver --stdio` — Python LSP
      typescript-language-server # `typescript-language-server --stdio`; nixpkgs' wrapper pins typescript_5's tsserver, so no project-local `typescript` is needed
      nixd # `nixd` — eval-aware Nix LSP (stdio by default, no flag)
      bash-language-server # `bash-language-server start` — Bash/sh LSP (stdio); shells out to the two below
      shellcheck # bash-language-server's diagnostics backend (found on PATH); was a Homebrew formula (hosts/macos.nix)
      shfmt # bash-language-server's formatter backend (found on PATH)
      mermaidAscii # render Mermaid graphs as ASCII in the terminal (packages/mermaid-ascii.nix)
      gitTidy # `git-tidy` — switch to the default branch, fast-forward, delete branches whose GitHub PR merged (gh-poi, so squash merges count) (packages/git-tidy.nix)
    ]
    ++ lib.optionals isMacosHost [
      inngest # `inngest` — CLI + local dev server for Inngest durable workflows (not in Homebrew; nixpkgs has it)
      stripe-cli # Stripe CLI (`stripe`) — API calls, webhook forwarding (`stripe listen`), event triggers; auth is a one-time `stripe login` browser OAuth (config in ~/.config/stripe, never in git/store — same one-time-CLI-login convention as gh/hf/docker).
      wp-cli # WordPress CLI (`wp`) — manage WordPress installs/plugins/themes/db from the shell; nixpkgs-native (bundles its own PHP), so no Homebrew `wp-cli` formula or `curl … wp-cli.phar` install (single source per the reuse/declarative convention)
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      pandoc # Universal doc converter — nixpkgs-native on aarch64-darwin (no Homebrew needed); backs the docx/pptx/xlsx skills' `pandoc` dependency (see programs.claude-code.skills NOTE below)
      poppler-utils # pdftoppm/pdftotext/pdfimages CLI — NOT `poppler` (that's the glib-bindings library, no binaries); moved here from the macos Homebrew `poppler` formula (nixpkgs is the single source per modules/darwin/homebrew.nix's dedup comment); backs the pdf/docx/pptx skills
    ]
    ++ lib.optionals isMacosHost [
      androidPhone # `android-phone list|pair|connect|disconnect|unpair|tcpip|wireless|mirror|doctor` — deterministic ADB wired/wireless operator + scrcpy mirroring for a PHYSICAL device (packages/android-phone.nix); unrelated to `android-emu` (virtual emulator, below)
      nixosVm # `nixos-vm <verb>` (verbs: the case in packages/nixos-vm.nix) — the long-lived nixos UTM guest (packages/nixos-vm.nix)
      pkgs.gcx # `gcx` — Grafana's official Cloud CLI (public preview; supersedes grafanactl, archived 2026-06-01), for the operator's Grafana Cloud stack; ships agent skills Claude Code auto-detects
      pkgs.scrcpy # mirror/control a PHYSICAL Android phone. Was the `scrcpy` BREW until 2026-09-29 (hosts/macos.nix records the move). Its nixpkgs wrapper prepends its OWN android-tools adb to PATH for its own process only — so it drives adb 37.0.0 while mobile-mcp/android-phone use the cask's 37.0.1. Harmless: both speak protocol 1.0.41, so they share one adb server instead of killing each other's. `adb` itself stays on the cask
      # Operator-personal: his bookmark DB, his job search, his Resend Keychain key.
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
      jobspy # `jobspy --search … --location …` — scrape jobs (LinkedIn/Indeed/…) into CSV/JSON via python-jobspy in an ephemeral uv env (packages/jobspy.nix)
      resendCli # `resend` — the official Resend CLI (npx-wrapped, not yet in nixpkgs), authenticated non-interactively via RESEND_API_KEY from the login Keychain (packages/resend-cli.nix).
    ]
  # The media stack itself is NOT listed here any more — `local.mediaCli`
  # above installs it, along with exiftool/auge/rclipCli via that module's
  # extraSearchPackages seam.
  #
  # NOT anywhere: osxphotos, which reads Apple Photos' own library DB (every
  # picture already scored across 27 aesthetic dimensions — pleasant_composition,
  # well_timed_shot, sharply_focused_subject — at zero compute, far richer than the
  # single float Vision's --aesthetics returns). `python3Packages.osxphotos` is
  # marked `broken = true` in nixpkgs (checked at 0.76.1), so adding it fails the
  # flake check outright. Reach for it ad hoc via `uvx osxphotos` until that lifts.
  ;

  # ---- Android SDK (macOS only) ------------------------------------------------
  # The `android-commandlinetools` Homebrew cask installs sdkmanager/avdmanager
  # under the Homebrew prefix. Point ANDROID_HOME there so `sdkmanager` downloads
  # the emulator + system images into it, and put the emulator/platform-tools
  # bins on PATH (adb itself also comes from the `android-platform-tools` cask).
  # After switching, just run `android-emu` (the helper in the let block) — it
  # installs the SDK packages + creates the AVD on first run, then boots it.
  home.sessionVariables = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    {
      # rclip's default macOS path compiles a Core ML model, which needs
      # `coremltools` — a dep the nixpkgs package does not ship. Without this every
      # real invocation dies on `ModuleNotFoundError: No module named 'coremltools'`.
      # `dontCheckRuntimeDeps` (see rclipCli above) only silenced the BUILD-time
      # complaint about the same missing dep; it could not fix the runtime import,
      # so rclip built cleanly and had never successfully indexed anything.
      # This selects the ONNX path, which needs no coremltools. Verified: with it
      # set, indexing and search both work.
      RCLIP_USE_ONNX_ON_MACOS = "1";

      # BASH_ENV (the secret loader) + the loader file itself are now set by
      # local.keychainSecrets (the keychain-secrets capsule's HM module).

      # The JSON Resume CLIs (jsonresume.org, npm globals: `resumed` — the maintained
      # tool this repo prefers — and legacy `resume-cli`) render PDFs via puppeteer,
      # whose bundled Chromium auto-download is flaky (its chrome-headless-shell fetch
      # corrupts, failing the `npm i`). These two vars form one coherent policy —
      # NEVER download puppeteer's own browser, ALWAYS use the browser cask the host
      # already declares:
      #   SKIP_DOWNLOAD    — any `npm i` that pulls puppeteer skips the browser fetch
      #                      (so `npm i -g resumed puppeteer` / a theme install never breaks).
      #   EXECUTABLE_PATH  — puppeteer launches that system browser at runtime instead.
      # Points at the `ungoogled-chromium` cask, NOT google-chrome, even though Chrome is
      # declared again (it holds http/https for passkeys — see hosts/macos.nix). A pinned,
      # ad-free engine must not follow an `auto_updates` cask mid-render.
      # Verified 2026-08-31 — puppeteer launched this binary (reports Chrome/152.0.7977.64)
      # and `page.pdf()` returned a valid `%PDF-` document. That cask is macos-only
      # (`isMacosHost` below), so off the real Mac this path does not exist and the var is inert
      # until a browser is declared there; the JSON Resume npm globals live on macos.
      # Harmless for other puppeteer tools (they get the same browser); Remotion is
      # unaffected — it resolves its own browser, not these vars. The resume THEME
      # still installs per-project (local node_modules), e.g. `npm i jsonresume-theme-macchiato`.
      PUPPETEER_SKIP_DOWNLOAD = "true";
    }
    # macos-only: two point into casks only hosts/macos.nix installs (ungoogled-chromium,
    # android-commandlinetools), and buku's DB is the operator's own data.
    // lib.optionalAttrs isMacosHost {
      PUPPETEER_EXECUTABLE_PATH = "/Applications/Chromium.app/Contents/MacOS/Chromium";
      ANDROID_HOME = androidSdkRoot;

      # Where buku keeps `bookmarks.db`. Pinned because buku otherwise scatters it into a
      # platform-guessed data dir, and this DB is the single surviving copy of the merged
      # Chrome+Brave bookmark set — it must live somewhere backed up and obvious, next to
      # the other $HOME/Developer/local data dirs. $HOME-relative so it is
      # username-portable; never a literal /Users/<name>.
      BUKU_DEFAULT_DBDIR = "$HOME/Developer/local/bookmarks";
    }
  );

  home.sessionPath = lib.optionals isMacosHost [
    "${androidSdkRoot}/emulator"
    "${androidSdkRoot}/platform-tools"
    # No `$HOME/.grok/bin`: a self-updated per-user grok must not shadow the store grok-build.
  ];

  # ---- Git identity include files -----------------------------------------------
  # Every per-namespace identity (work, client, per-context) and allowed_signers left
  # Nix (ADR-004 §7, inventory #3; client routing too, 2026-10-20): they name
  # mailboxes, orgs and folders that are the operator's alone, in a public repo.
  # They are HAND-PLACED under ~/.config/git/, reached through ONE include,
  # `local.inc` (programs.git.includes below), which holds the operator's own
  # includeIf blocks. A missing include file is a silent git no-op — so after a
  # fresh bootstrap, write it before authoring (docs/new-mac-runbook.md).

  # ---- Home Manager program modules --------------------------------------------
  programs = {
    home-manager.enable = true;

    # JDK 17 for the Android sdkmanager/avdmanager (JVM tools; the emulator
    # itself needs no Java), so darwin-only like the rest of the Android block.
    # upstream option home-manager.programs.java exists → using it (pinned
    # programs/java.nix:19-37: the package + JAVA_HOME = "${package.home}" in
    # sessionVariables, which is exactly what a bare home.packages entry plus a
    # hand-set JAVA_HOME used to spell out — and it kept a JDK on the Linux hosts
    # that have no Android tooling).
    java = {
      enable = pkgs.stdenv.hostPlatform.isDarwin;
      package = pkgs.jdk17;
    };

    # Claude Code CLI. On darwin we manage it via the module (not just as a bare
    # package) for the settings/plugin/marketplace surface below — the global
    # CLAUDE.md, `settings`, `plugins` and `extraKnownMarketplaces`. It attaches
    # NO `mcpServers`: the module that did (`modules/shared/mcp.nix`, the localhost
    # gateway's SSE endpoints + desktop-commander stdio) was deleted 2026-10-02, and
    # servers now arrive only from an enabled plugin's own `.mcp.json`, which this
    # repo does not write. `package = null`: the module then puts NO bare `claude` on
    # PATH (upstream default.nix `home.packages = mkIf (cfg.package != null) …`) while
    # still writing settings, CLAUDE.md, skills and marketplaces. The binary reaches
    # PATH only through the named wrappers (./claude-profiles.nix), which exec
    # `local.claudeProfiles.package` — our darwin strict-sandbox override, claudeCode
    # above. On the Linux hosts claude-code stays a plain home.packages entry.
    claude-code = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      enable = true;
      package = null;

      # GLOBAL Claude Code instructions — user-level rules loaded in every
      # project/session on this Mac (the sole Claude Code client host): the
      # strict "decisions/confirmations = AskUserQuestion options" rule and the
      # reuse-over-rebuild preference, so they apply everywhere and not just in
      # this repo.
      #
      # upstream option home-manager.programs.claude-code.context exists → using it
      # (modules/programs/claude-code/options.nix `context`, `either lines path`;
      # impl home-manager/modules/programs/claude-code/default.nix writes `"''${cfg.configDir}/CLAUDE.md".source`
      # for a path value, and `configDir` defaults to ~/.claude in options.nix).
      # This replaced a hand-written `home.file.".claude/CLAUDE.md"` shim under
      # the identical darwin gate — same target, one fewer duplicate-home.file
      # collision risk.
      context = ../../claude/CLAUDE.md;

      # Marketplaces and `settings.enabledPlugins` are NOT declared here — the
      # marketplace set is DATA (`local.claudePlugins.marketplaces` above) and its
      # registration + install mechanism lives in ./claude-plugins.nix, which also
      # records why upstream's `marketplaces.*` option cannot be used.

      # Claude Code user settings, now Nix-owned.
      # NOTE: editing any of these in the Claude UI won't persist — a rebuild
      # reverts them; change them HERE instead.
      settings = {
        # ONE owner per stdio MCP server (2026-11-01). Claude Code never dedups stdio servers,
        # so two plugins naming the same server both spawn it. A NAME deny drops just that
        # server: the plugin's skills and hooks still load, and the name survives the plugin's
        # own updates. Measured on CLI 2.1.296 with a scratch plugin: `serverName =
        # "plugin:<plugin>:<server>"` removed exactly that server and nothing else.
        #   aws-core        its `aws-mcp` runs `--skip-auth` (UNSIGNED). The one AWS path is the
        #                   official claude.ai AWS MCP connector, signed in with Identity Center
        #                   SSO (operator, 2026-11-01); before the deny the model picked the
        #                   unsigned twin 1,644 times across all transcripts.
        #   aws-serverless  `@latest --allow-write` from PyPI at every spawn, no AWS identity,
        #                   0 calls ever. Its 7 skills + SAM-validate hook stay.
        # The guard against a silent upstream server rename is fleet-doctor's MCP-owner step.
        deniedMcpServers = [
          { serverName = "plugin:aws-core:aws-mcp"; }
          { serverName = "plugin:aws-serverless:aws-serverless-mcp"; }
          # Same URL as the claude.ai connector, and Claude Code loads only one, so the
          # plugin copy hid the connector. Cloud routines can only reach the connector, so
          # denying the plugin copy gives local and cloud runs one sign-in. The plugins'
          # skills still load.
          { serverName = "plugin:cloudflare:cloudflare"; }
          { serverName = "plugin:slack:slack"; }
          { serverName = "plugin:neon:neon"; }
        ]
        # The operator's claude.ai Microsoft 365 connector: his tenant blocks consent, so it
        # only ever showed "Needs authentication"; removed 2026-11-01. The URL deny drops it
        # from `claude mcp list`.
        ++ lib.optionals isMacosHost [
          { serverUrl = "https://microsoft365.mcp.claude.com/mcp"; }
        ];

        theme = "auto";
        # DECLARED AND VALID, BUT NOT ALWAYS IN EFFECT — do not "fix" it by
        # deleting it. Verified 2026-09-22 against the published schema
        # (json.schemastore.org/claude-code-settings.json): `tui` is a real key,
        # enum fullscreen|default, and it corresponds to the /tui command.
        # Measured the same day: with this set, `/tui default` still answered
        # "Already using the default renderer" — so the session had fallen back.
        # The fullscreen path carries `requires: { ink: true }` in the binary, so
        # a terminal or session shape that cannot give it the alt-screen renderer
        # silently gets the classic one instead. `~/.claude.json` holds no `tui`
        # key either, so this file is the only declaration; the fallback is a
        # RUNTIME decision, not lost config.
        tui = "fullscreen";
        skipDangerousModePermissionPrompt = true;
        skipWorkflowUsageWarning = true;
        inputNeededNotifEnabled = true;
        agentPushNotifEnabled = true;

        # AGENT TEAMS backend. `teammateMode` is a real top-level settings key in
        # claude-code 2.1.278 — the binary declares it as
        # `teammateMode: z(reo).optional().describe("How spawned teammates execute
        # (tmux, iterm2, in-process, auto)")`, enum tmux|iterm2|in-process|auto.
        # "tmux" is chosen over the three alternatives on measured grounds:
        #   - iterm2  — IMPOSSIBLE here. The backend requires both an iTerm2 host
        #     and the `it2` CLI; this host is Ghostty (TERM_PROGRAM=ghostty) and
        #     `it2` is not on PATH, so the binary's own error path fires.
        #   - auto    — resolves to in-process on this host. The selection log is
        #     "[BackendRegistry] Selected: tmux (running inside tmux session)", i.e.
        #     auto takes the pane backend only when ALREADY inside tmux. Claude is
        #     launched from a bare Ghostty window, so auto never picks panes.
        #   - in-process — works (a client-repo team on 2026-10-06 ran this way,
        #     ~/.claude/teams/session-9aa658ae/config.json, backendType
        #     "in-process") but the binary refuses background agents from an
        #     in-process teammate: "In-process teammates cannot spawn background
        #     agents", and a pane teammate also cannot run a plugin's run-time
        #     registered agent type. Panes give each teammate a real attachable
        #     terminal; tmux 3.7c is already on PATH from this flake.
        # Explicit, not auto: the fallback is a RUNTIME decision, and an implicit
        # downgrade to in-process is exactly the silent drift this file avoids
        # elsewhere (see the `tui` note above for the same failure shape).
        teammateMode = "tmux";

        # Routing telemetry: export tool_decision/tool_result events (only —
        # no metrics/traces, no prompt/response content) to the local OTel
        # Collector defined in modules/home/claude-otel.nix, read by
        # /routing-review to find deterministic-vs-model-judgment hardening
        # candidates. Gated on the SAME predicate as the collector itself
        # (claude-otel.nix's `local.claudeOtel.enable`) — not on isMacosHost,
        # which is a DIFFERENT predicate: an account with the collector off but
        # isMacosHost true would keep exporting into a collector that is not
        # running, and its own /routing-review would read nothing.
        env = {
          # Keeps the input box's suggested-next-prompt alive under a usage
          # WARNING. Not a plain on/off switch — the feature is already on by
          # default (`promptSuggestionEnabled`, absent = enabled). This value
          # is read a second time, as the only override in the gate that
          # otherwise silently suppresses suggestions when the account is
          # near a usage limit (claude-code 2.1.260):
          #
          #   let r = status === "allowed_warning"
          #           && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION === true;
          #   if (status !== "allowed" && !r) return "rate_limit";
          #
          # So on a heavy account — which this one is — the suggestions vanish
          # with no message the moment usage reaches `allowed_warning`, and
          # come back only with this set. It does NOT override a hard limit.
          #
          # The other five gates are NOT settable and are worth knowing before
          # concluding the feature is broken: `cache_cold` (last turn's
          # input + cache_creation + output over 10,000 tokens — measured here
          # at only 2.3% of turns), `unfocused` (terminal blurred when the turn
          # ENDS, which a long agent run makes likely), `elicitation_active`
          # (any connected MCP client with a pending elicitation),
          # `pending_permission`, `plan_mode`, and `early_conversation`
          # (first turn). Every one of them returns silently.
          CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = "true";

          # AGENT TEAMS (named, persistent, mutually-messaging teammates — the
          # Agent tool gains a `name` param and SendMessage addresses them) are
          # gated behind THIS env var and nothing else. Read at the source,
          # claude-code 2.1.278:
          #
          #   function t(){return process.argv.includes("--agent-teams")}
          #   function Qr(){if(!a.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS&&!t())
          #     return!1;if(!P("tengu_amber_flint",!0))return!1;return!0}
          #
          # So there are two switches on paper and ONE that works: the
          # `--agent-teams` argv form is unreachable, because commander rejects
          # the unknown option before that check runs — measured 2026-10-06,
          # `claude --agent-teams -p …` exits with
          # "error: unknown option '--agent-teams'". The env var is the only
          # usable door; `tengu_amber_flint` is a server-side gate that defaults
          # to true and is not settable here.
          # Precedent that settings.env DOES feed this gate (it is not read
          # before settings load): a client repo sets the same var
          # in its project .claude/settings.json, and that session wrote
          # ~/.claude/teams/session-9aa658ae/config.json at 13:21 on 2026-10-06.
          # Declared user-level rather than per-repo so there is ONE copy — a
          # second project-local copy would drift from this one.
          CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          # A PRIVATE marketplace (none on `macos` since 2026-11-01) refreshes over git with the
          # Mac's own credentials. If a background check cannot reach or authenticate to
          # the remote, keep the last checkout instead of attempting a re-clone, so
          # plugins keep working from the last synced state. Documented behaviour:
          # code.claude.com/docs/en/plugins/host-marketplace § "What background
          # auto-update does with credentials" (read 2026-10-20).
          CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE = "1";
        }
        // lib.optionalAttrs config.local.claudeOtel.enable {
          CLAUDE_CODE_ENABLE_TELEMETRY = "1";
          OTEL_LOGS_EXPORTER = "otlp";
          OTEL_EXPORTER_OTLP_PROTOCOL = "grpc";
          OTEL_EXPORTER_OTLP_ENDPOINT = config.local.claudeOtel.otlpEndpoint;
          OTEL_LOG_TOOL_DETAILS = "1";
        }
        // lib.optionalAttrs config.local.claudeOtel.grafana.enable {
          # Same local collector; it alone holds the Grafana credential.
          OTEL_METRICS_EXPORTER = "otlp";
          # session.id would make ~41k series (ADR-011 § 5); account ids are identity.
          OTEL_METRICS_INCLUDE_SESSION_ID = "false";
          OTEL_METRICS_INCLUDE_ACCOUNT_UUID = "false";
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
        # ONLY skills no plugin can serve: unlicensed, so neither a marketplace nor
        # kattakath/skills can carry them (2026-11-07), or whose plugin fails to load (each
        # entry says which). Every other skill comes from a plugin:
        # superpowers@synced (systematic-debugging, verification-before-completion),
        # fullstack-dev-skills (postgres-pro), and kattakath's job-search
        # and vercel-workflow. find-skills was dropped: capability-broker covers discovery.
        # NO plugin-dev / hookify entries either: those ship as claude.ai-synced plugins.
        #
        # Community: generate .excalidraw diagrams — pairs with the Excalidraw connector.
        # Root-level SKILL.md, so the whole repo is the skill dir.
        excalidraw-diagram = "${agent-skills-excalidraw}";
        # OFFICIAL Vercel Labs (vercel-labs/agent-skills): drives the `vercel` CLI
        # (hosts/macos.nix Homebrew cask `vercel`) for non-interactive / token auth.
        vercel-cli-with-tokens = "${agent-skills-vercel-agent}/skills/vercel-cli-with-tokens";
        # Community (MIT): AppleScript/JXA foundation — pairs with the `macos-automator` MCP server.
        # Back in Nix 2026-11-07: upstream's marketplace plugin FAILS TO LOAD ("conflicting
        # manifests: both plugin.json and marketplace entry specify components" — its entry is
        # strict:false AND plugin.json lists components). Retry the plugin when upstream fixes that.
        automating-mac-apps = "${agent-skills-mac-automation}/plugins/automating-mac-apps-plugin/skills/automating-mac-apps";
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
      };

      # Global excludes — upstream option programs.git.ignores (pinned
      # home-manager/modules/programs/git.nix:182, written to $XDG_CONFIG_HOME/git/ignore, git's default
      # core.excludesFile). Measured 2026-10-30: 21 of 22 checkouts under
      # ~/Developer read as dirty ONLY because of an untracked .DS_Store, so every
      # clean-tree guard (`git-tidy`) refused them. The settings.local.json line was
      # the file's whole content before this took it over (unmanaged, most likely
      # written by Claude Code) and is kept so nothing needs to re-append it.
      ignores = [
        ".DS_Store"
        ".claude/worktrees/"
        "**/.claude/settings.local.json"
      ];

      # SSH commit/tag signing (GitHub/GitLab Verified). The forge still needs
      # the pubkey as a *Signing* key (docs/new-mac-runbook.md).
      # upstream option home-manager.programs.git.signing exists → using it
      # (pinned programs/git.nix:63-116). It replaced five raw INI keys and a
      # custom option (kattakath.git.extraAllowedSignersPrincipals) that the
      # private [redacted] flake filled, retired with that flake 2026-09-15.
      # `format` is explicit because home.stateVersion 24.05 predates the "ssh"
      # default (git.nix:20-31). `signer` is left to upstream (nixpkgs' ssh-keygen).
      # The principals file (allowed_signers) is HAND-PLACED since 2026-09-20 — it
      # lists every mailbox the operator authors as, several of which are
      # operator-private and do not belong in a public repo (ADR-004 §7, inventory #3).
      # Upstream's `signing.allowedSigners` would write it from Nix, so it is left
      # empty and `gpg.ssh.allowedSignersFile` points at the runtime path instead. Signing
      # itself needs no principals file — only VERIFYING does — so a fresh machine
      # signs correctly before the file exists. Shape of a line:
      #   <mailbox> namespaces="git" <the operator ssh public key>
      signing = {
        key = operatorPublicKey;
        format = "ssh";
        signByDefault = true;
      };
      settings.gpg.ssh.allowedSignersFile = "${config.home.homeDirectory}/.config/git/allowed_signers";

      # Per-namespace identity: see § Git identity include files above.
      # Unconditional, so local.inc's own nested `[includeIf …]` blocks decide.
      # Paths absolute under $HOME.
      # Route by remote URL AND gitdir in local.inc: hasconfig cannot fire between
      # `git init` and `git remote add`.
      includes = [ { path = "${config.xdg.configHome}/git/local.inc"; } ];
    };

    ssh = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
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
        # Keychain-backed agent for git SSH signing / non-interactive SSH. IdentityFile
        # lives ONLY here: ssh_config(5) accumulates it across matching blocks, so a
        # per-host repeat offers the same key twice. Only the
        # three values that carry a DECISION are set; the rest of home-manager's
        # retired default block (ForwardAgent/Compression/ServerAlive*/HashKnownHosts/
        # Control*/UserKnownHostsFile) were OpenSSH's own compiled defaults restated,
        # so they are left to ssh_config(5). `enableDefaultConfig = false` stays.
        "*" = {
          AddKeysToAgent = "yes";
          UseKeychain = "yes";
          IdentityFile = operatorPrivateKey;
        };

        # Local NixOS hosts (mDNS .local) — agent forwarding on for interactive
        # admin work over SSH from the Mac.
        "*.local" = {
          User = config.home.username;
          ForwardAgent = true;
        };

        # nixpi over the Cloudflare Tunnel — the ONLY way to reach the Pi when the
        # Mac is not on its LAN (it has no public IP and no port-forward; the
        # `*.local` block above covers the mDNS path).
        #
        # Declared here, not hand-edited: ~/.ssh/config is a read-only store
        # symlink this module owns, and this is the one place a spaced
        # ProxyCommand survives BOTH deploy-rs legs (ssh + `nix copy`) — the
        # why, incl. the NIX_SSHOPTS re-splitting, is
        # docs/map/entry-points.md § deploy.nodes. cloudflared is the STORE binary, never
        # PATH/`/opt/homebrew`: ssh runs ProxyCommand via `/bin/sh -c` with the
        # caller's environment, and a PATH miss is an opaque "Connection closed".
        #
        # This path ALSO needs a Cloudflare Zero Trust *Access Application* for the
        # hostname — declared in infra/cloudflare/nixpi-tunnel.nix (`nixpi_ssh`) since
        # it silently vanished once (2026-08-20). Symptom + fix: docs/private-home-modules.md.
        # OPERATOR-ONLY — the nixpi tunnel exists only in the operator's fleet, so a template
        # consumer's Mac gets the generic "*" defaults above and no entry (or cloudflared) for it.
        ${derivedNames.nixpiSshHostname domainName} = lib.mkIf isMacosHost {
          User = config.home.username;
          ProxyCommand = "${lib.getExe pkgs.cloudflared} access ssh --hostname %h";
          # A fresh SD flash reuses the hostname with a BRAND-NEW host key, so a
          # pinned entry would abort every post-reflash connection. accept-new
          # still refuses a CHANGED key (unlike `no`) — run
          # `ssh-keygen -R nixpi.${domainName}` after a reflash.
          StrictHostKeyChecking = "accept-new";
        };

      };
    };

    gh.enable = true;

    direnv = {
      enable = true; # shell integrations default on (home-manager misc/shell.nix)
      nix-direnv.enable = true;
    };

    # nh — the switch-time feedback layer: nom's live dependency tree while
    # building, a dix closure diff after ("PATHS 999 -> 999, DIFF 0 bytes"), and
    # `--ask`/`--dry`. Its real win here is that since 4.3.0 it HIDES activation
    # output by default: it runs `darwin-rebuild activate` with show_output=false,
    # which is the only thing that suppresses home-manager's ~30 `Activating <x>`
    # lines and nix-darwin's `setting up ...` banners. Both are printed
    # unconditionally by their own modules (home-environment.nix's `_iNote
    # "Activating %s"`, and a hard-coded `printf >&2` per nix-darwin module), so
    # no option in either project can quiet them. `--show-activation-logs` /
    # NH_SHOW_ACTIVATION_LOGS puts them back for a run.
    #
    # ONLY the package + env here — deliberately NO `flake`/`darwinFlake`
    # pointer. Whatever that names is what a bare `nh darwin switch` activates. Leaving
    # it unset means `nh darwin switch` needs an explicit path, and `activate`
    # (the only sanctioned entry point) already passes one. It does not use nh:
    # nh's own progress ticker repaints ~15x/s with NO off switch (measured:
    # NH_NOM=0 and NO_COLOR=1 both change nothing), so under a pipe it is far
    # worse than plain darwin-rebuild.
    #
    # clean stays off: GC is the fleet's own story (nix.gc on nixpi; Determinate
    # owns it on darwin), and the module warns when both are enabled.
    nh = lib.mkIf isMacosHost {
      enable = true;
      clean.enable = false;
    };

    # A login shell is required for Home Manager to wire session vars into bash.
    bash = {
      enable = true;
      # macOS Keychain secret loader is wired into bash's profileExtra/bashrcExtra
      # by local.keychainSecrets (the keychain-secrets capsule's HM module).

      # fnm hook + ssh-agent load (interactiveShellInit); darwin-only.
      initExtra = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (interactiveShellInit "bash");
      profileExtra = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin sshAuthSockFromLaunchd;
    };

    # Ghostty — GPU-accelerated terminal, macos only. `package = null` is the
    # escape hatch home-manager documents for exactly this: nixpkgs' `ghostty` is
    # LINUX-ONLY and refuses to evaluate on aarch64-darwin, so the Homebrew cask
    # in hosts/macos.nix ships the app and this owns nothing but the config — the
    # same split already used for the ungoogled-chromium cask.
    #
    # The type comes from terminal-theme.nix's `font` (sizes: its `font.sizes`).
    #
    # Shell integration is left to Ghostty's OWN auto-injection and deliberately
    # NOT enabled here: `enableZshIntegration` sources the integration script out
    # of the Nix `package`, which is null on this platform, so switching it on
    # would point at nothing. The cask's app bundle already does this itself.
    ghostty = lib.mkIf isMacosHost {
      enable = true;
      package = null;
      # NOTHING HERE IS VALIDATED UNTIL THE CASK IS INSTALLED —
      # `ghostty +validate-config` needs the binary. Run it after the first
      # activation and correct anything it rejects; that step is the gate, not
      # this comment. Note `package = null` also makes home-manager's own
      # onChange validation inert (pinned home-manager modules/programs/
      # ghostty.nix:160-163 wraps it in `mkIf (cfg.package != null)`), so the
      # cask being absent can never break an activation here.

      # ---- The palette, as a THEME FILE --------------------------------------
      # upstream option home-manager.programs.ghostty.themes exists → using it
      # (pinned modules/programs/ghostty.nix:67, written to
      # $XDG_CONFIG_HOME/ghostty/themes/<name> at :172-179). Colours live in
      # their own file rather than inline in `settings`, which is what lets
      # modules/home/terminal-theme.nix be the one place they are stated —
      # every value below is DERIVED, none is typed twice.
      themes.fleet = {
        inherit (config.lib.terminalTheme) background foreground;
        cursor-color = config.lib.terminalTheme.cursor;
        palette = config.lib.terminalTheme.ghosttyPalette;
      };

      settings = {
        # ---- Type ---------------------------------------------------------------
        # Both from the provider. The face is one fleet-wide value; the SIZE is
        # per-surface on purpose (18 here against 16 in VS Code and Terminal.app)
        # and terminal-theme.nix's `font.sizes` option says why.
        font-family = config.lib.terminalTheme.font.face;
        font-size = config.lib.terminalTheme.font.sizes.ghostty;
        # Ghostty rasterizes thinner than Terminal.app at the same nominal size —
        # that difference, not the size, is why 16pt UbuntuMono looked lighter
        # here than in the old Ubuntu profile. This is the knob Ghostty added for
        # it; bold stays meaningfully bolder, unlike setting font-style = Bold.
        font-thicken = true;

        # ---- Ground ------------------------------------------------------------
        # A THEME NAME, not inline colours. `theme` is resolved against
        # $XDG_CONFIG_HOME/ghostty/themes, which is exactly where `themes.fleet`
        # above is written — so this is one indirection, not a second source.
        #
        # SAFE ONLY BECAUSE THE INLINE COLOURS ARE GONE. An explicit
        # `background`/`foreground`/`palette` in `settings` OVERRIDES the
        # theme's, so leaving both would silently make the theme file dead
        # weight and reintroduce the drift this whole change removes.
        #
        # STILL NOT SYSTEM-FOLLOWING, and still deliberately. Ghostty's
        # `light:NAME,dark:NAME` syntax applies to `theme`, so it is now
        # REACHABLE — a second `themes.<name>` plus `theme = "light:x,dark:fleet"`
        # is all it would take — but the ground is a specific aubergine, not a
        # mode-dependent one, so one theme is the honest answer.
        theme = "fleet";

        # ---- Window ----------------------------------------------------------
        # `tabs` puts the tab strip IN the titlebar, reclaiming a full row of
        # vertical space against a separate bar.
        macos-titlebar-style = "tabs";
        window-padding-x = 8;
        window-padding-y = 8;
        # OPAQUE, deliberately. Translucency was chosen while the ground was a
        # theme colour, where it was decoration. It stopped being decoration the
        # moment the ground became a specific value: at 0.95 the window does not
        # show the ground (`config.lib.terminalTheme.background`), it shows 95% of
        # it composited over whatever is behind, so the ground is the one thing
        # translucency dilutes.
        background-opacity = 1.0;
        background-blur = false;

        # ---- Input -----------------------------------------------------------
        # Option must send Alt, or every readline word-motion in zsh is dead.
        # This one is not cosmetic.
        macos-option-as-alt = true;
        cursor-style = "block";
        cursor-style-blink = true;
        copy-on-select = "clipboard";

        # ---- Shell integration ------------------------------------------------
        # `ssh-env` and `ssh-terminfo` are the load-bearing pair for this fleet:
        # without them a remote host meets an unknown `xterm-ghostty` and garbles
        # every full-screen program, which matters because nixpi is
        # reached over ssh.
        shell-integration-features = "cursor,title,sudo,ssh-env,ssh-terminfo";

        # Only when Ghostty is not focused — useful for a long build, silent
        # while you are watching it.
        notify-on-command-finish = "unfocused";

        # ---- Quick Terminal ---------------------------------------------------
        # A shell that drops over whatever is on screen. The global binding needs
        # a one-time Accessibility grant, the same wall documented for
        # macos-automator in docs/osascript-accessibility-tcc.md.
        quick-terminal-position = "top";

        # ---- Splits: the UNFOCUSED pane's text dims, the ground stays put -------
        # Ghostty only ever modifies the UNFOCUSED split — there is no
        # "focused-background" key.
        # 0.5: a lighter dim than the 0.35 previously set here. The floor is
        # 0.15, which Ghostty itself calls weird-looking.
        unfocused-split-opacity = 0.5;
        # NO FILL, deliberately. Unset, it defaults to `background`, so the
        # unfocused GROUND is unchanged and only the text dims -- 17.58:1 down to
        # 6.80:1. Ground stays identical across panes and titlebar, which is what
        # "leave the unfocused one alone" actually means. A coloured fill was
        # tried and rejected: lifting the unfocused ground made the panes you are
        # NOT in the loudest thing on screen.
        # dE00 11.29 from the ground -- visible without competing with it.
        split-divider-color = "#5C2A4C";

        # A LIST, because `keybind` is a repeatable key — home-manager's settings
        # type takes a list for exactly that case.
        #
        # Only what is NOT already a default. `ghostty +show-config --default`
        # reports super+d / super+shift+d (split creation) and super+[ /
        # super+] (split navigation) as defaults — re-declaring them would be
        # noise that implies a decision where none exists.
        keybind = [
          # `backquote`, NOT `grave` — measured: `ghostty +validate-config`
          # rejects the latter with `keybind: unknown error error.InvalidFormat`,
          # and the error names only "keybind", never which one, so a whole
          # config is invalidated by a single wrong key name.
          "global:cmd+backquote=toggle_quick_terminal"

          # Tab switching by the Terminal.app muscle memory. Ghostty's own tab
          # binds are super+shift+[ / ] (kept, additive), which collide in the
          # hand with super+[ / ] for SPLITS — one shift apart, two different
          # objects. Arrows are unambiguous. `arrow_left`, not `left`: the bare
          # name is rejected the same way `grave` is above. Free by default —
          # only super+shift+arrow_up/_down are taken (jump_to_prompt).
          "super+shift+arrow_left=previous_tab"
          "super+shift+arrow_right=next_tab"
        ];
      };
    };

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

    # zsh as the interactive shell — matches the devcontainer default
    # (common-utils configureZshAsDefaultShell). Kept lean: no oh-my-zsh /
    # framework. bash stays enabled above for login-shell
    # compatibility.
    zsh = {
      enable = true; # enableCompletion defaults true (zsh/default.nix)
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      # Session-only terminal background, one word each. These change the RUNNING
      # terminal via OSC 11 and persist nothing — a new tab is back to the
      # `local.terminalTheme.background` ground (terminal-theme.nix), so `red` doubles as the reset.
      #
      # The three grounds are the SAME COLOUR at three hues, not three guesses:
      # #300A24 converted to OKLCh, then hue rotated with L=0.2228 and C=0.0710
      # held fixed. So all three read as equally dark and the Tango ring in terminal-theme.nix —
      # which was lifted to 4.5:1 against #300A24 specifically — stays as
      # readable on green and blue as it is on red. Contrast against #FFFFFF is
      # 17.58 / 16.91 / 17.27 respectively.
      #
      # No PATH collision: `command -v red green blue` is empty on this fleet.
      shellAliases = {
        red = "echo 'background: ${config.lib.terminalTheme.background}' | theme.sh";
        green = "echo 'background: #002303' | theme.sh";
        blue = "echo 'background: #09193C' | theme.sh";
      };

      # interactiveShellInit in initContent (.zshrc): fnm's chpwd hook is interactive-only.
      initContent = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (interactiveShellInit "zsh");
      envExtra = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin sshAuthSockFromLaunchd;
    };

    # ---- VS Code (macOS only) --------------------------------------------------
    # GUI app; the shared profile also loads on headless NixOS hosts, so the
    # whole block is gated to darwin (like the ssh block above). Replicates the
    # devcontainer's editor: extensions via the nix-vscode-extensions Marketplace
    # mirror, plus the PORTABLE settings (container/workspace-specific paths are
    # omitted — see notes below).
    vscode = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      enable = true;

      # NO nix VS Code — the CASK is the real one. `visual-studio-code` is in
      # hosts/macos.nix's cask list, and `code` on PATH resolves to
      # /opt/homebrew/bin/code -> /Applications/Visual Studio Code.app. The nix
      # package was a fully shadowed second copy: 925.9 MiB of closure plus a
      # duplicate app in ~/Applications/Home Manager Apps, on every darwin
      # profile (measured 2026-09-16, vscode-1.136.1).
      #
      # upstream option home-manager.programs.vscode.package is `nullable = true`
      # (pinned modules/programs/vscode/mkVscodeModule.nix, its `mkPackageOption`) → using it.
      # Null removes ONLY the package (`home.packages = mkIf (cfg.package != null)`).
      # Everything this module is actually here for survives, because none
      # of it is derived from the package:
      #   * settings/keybindings/tasks land in `userDir`, which is built from
      #     `nameShort` ("Code"), NOT from the package — so they land in
      #     the directory the CASK app reads.
      #   * extensions are still symlinked into the extensions dir (`toPaths`),
      #     unconditionally.
      # The one thing dropped is the `.extensions-immutable.json` onChange hook
      # (explicitly gated on `cfg.package != null`), which force-
      # regenerates extensions.json by running `code --list-extensions`. VS Code
      # regenerates that file itself on next launch; with `mutableExtensionsDir`
      # already true this profile was never relying on a locked extensions dir.
      package = null;

      # Allow hand-installed / Settings-Sync extensions alongside the declared
      # ones — lower-maintenance than a fully locked extensions dir.
      mutableExtensionsDir = true;

      profiles.default = {
        # settings.json is a REAL file, not a store symlink, so VS Code's own
        # Settings UI can save into it (a store symlink is read-only and the UI
        # refuses). Upstream home-manager option — see its
        # modules/programs/vscode/mkVscodeModule.nix. Each activation merges
        # `dynamic * static` via jq: keys you set by hand survive, keys declared
        # below always win. Same trade as mutableExtensionsDir above — the live
        # settings are Nix PLUS whatever you clicked, not reproducible from the
        # flake alone.
        mutableUserSettings = true;

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
          # -- Terminal: the fleet palette --------------------------------------
          # DERIVED, not restated. Until this was wired to
          # modules/home/terminal-theme.nix, seven of these sixteen slots held
          # PRE-LIFT Tango while Ghostty held the WCAG-corrected values — the two
          # terminals on the same machine disagreed on red, blue, magenta and
          # four of the brights. `drawBoldTextInBrightColors` below routes every
          # bold token through the bright half, so the drift showed up twice.
          #
          # statusBarItem.* stays literal on purpose: it is Remote-window chrome,
          # not the ANSI ring, and shares nothing with the palette.
          "workbench.colorCustomizations" = with config.lib.terminalTheme.byName; {
            "terminal.background" = config.lib.terminalTheme.background;
            "terminal.foreground" = config.lib.terminalTheme.foreground;
            # UNSET until now, so the cursor fell through to whatever the editor
            # theme extension happened to pick.
            "terminalCursor.foreground" = config.lib.terminalTheme.cursor;
            "terminal.ansiBlack" = black;
            "terminal.ansiRed" = red;
            "terminal.ansiGreen" = green;
            "terminal.ansiYellow" = yellow;
            "terminal.ansiBlue" = blue;
            "terminal.ansiMagenta" = magenta;
            "terminal.ansiCyan" = cyan;
            "terminal.ansiWhite" = white;
            "terminal.ansiBrightBlack" = brightBlack;
            "terminal.ansiBrightRed" = brightRed;
            "terminal.ansiBrightGreen" = brightGreen;
            "terminal.ansiBrightYellow" = brightYellow;
            "terminal.ansiBrightBlue" = brightBlue;
            "terminal.ansiBrightMagenta" = brightMagenta;
            "terminal.ansiBrightCyan" = brightCyan;
            "terminal.ansiBrightWhite" = brightWhite;
            "statusBarItem.remoteForeground" = "#0c0a14";
            "statusBarItem.remoteBackground" = "#3e3657";
            "statusBarItem.remoteHoverBackground" = "#a98cf0";
          };
          # The fallback chain stays hand-written — 'Ubuntu Mono' then monospace
          # is a VS Code-only concern the provider has no opinion about.
          "terminal.integrated.fontFamily" =
            "'${config.lib.terminalTheme.font.face}', 'Ubuntu Mono', monospace";
          "terminal.integrated.fontSize" = config.lib.terminalTheme.font.sizes.vscodeTerminal;
          "terminal.integrated.copyOnSelection" = true;
          "terminal.integrated.drawBoldTextInBrightColors" = true;
          "terminal.integrated.tabs.defaultColor" = "terminal.ansiMagenta";
          "terminal.integrated.tabs.defaultIcon" = "terminal-ubuntu";
          "terminal.integrated.persistentSessionReviveProcess" = "onExitAndWindowClose";
          # One-click Claude Code terminal profiles, one per account, with
          # permission prompts skipped. `.osx` (not `.linux`) because the whole
          # block is darwin-gated. `path` is the profile wrapper's per-user path,
          # stable across rebuilds (./claude-profiles.nix).
          "terminal.integrated.profiles.osx" = lib.genAttrs [ "claude" "claude-work" ] (name: {
            "path" = "/etc/profiles/per-user/${config.home.username}/bin/${name}";
            "args" = [
              "--permission-mode"
              "bypassPermissions"
            ];
            "icon" = "claude";
            "color" = if name == "claude-work" then "terminal.ansiBlue" else "terminal.ansiYellow";
          });
          # -- Editor --
          # JetBrainsMono Nerd Font (pkgs.nerd-fonts.jetbrains-mono) — pairs with
          # the JetBrains New UI Dark theme; ligatures on. Terminal stays UbuntuMono.
          "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'JetBrains Mono', monospace";
          "editor.fontLigatures" = true;
          "editor.formatOnSave" = true;
          "editor.codeActionsOnSave" = {
            "source.organizeImports" = "explicit";
          };
          # -- Python (editor-wide, NOT path-bound) --
          # Picks the language-server IMPLEMENTATION (Pylance when present, else
          # Jedi) — a personal editor preference, unlike the python.* settings
          # the note below excludes, which hardcode per-project interpreter paths.
          "python.languageServer" = "Default";
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
  # on the operator private key. launchd-launcher.nix → nix-ssh-keychain-load.
  # upstream-first: home-manager `services.ssh-agent` runs a NIX-built agent
  # (`mkPackageOption pkgs "openssh"`), not Apple's Keychain-backed /usr/bin one that
  # `--apple-load-keychain` needs — so it cannot replace this.
  launchd.agents.ssh-keychain-load = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    enable = true;
    config = {
      # ProgramArguments entries must be strings (not raw derivations).
      ProgramArguments = [
        # writeShellApplication (ShellCheck); its `set -euo pipefail` adds only
        # pipefail to the `set -eu` this always had. Every ssh-add is `|| true` or
        # an `if` test, so a missing key or an empty agent cannot trip errexit.
        (lib.getExe (
          pkgs.writeShellApplication {
            name = "ssh-keychain-load";
            text = ''
              /usr/bin/ssh-add --apple-load-keychain 2>/dev/null || true
              key="${operatorPrivateKey}"
              if [ -f "$key" ] && ! /usr/bin/ssh-add -l >/dev/null 2>&1; then
                /usr/bin/ssh-add --apple-use-keychain "$key" 2>/dev/null || true
              fi
            '';
          }
        ))
      ];
      RunAtLoad = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ssh-keychain-load.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ssh-keychain-load.log";
    };
  };

  home.activation = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    # ~/.grok/sandbox.toml as a REAL FILE, not a store symlink — grok counts it as a
    # hooks-paths registry entry and refuses to start on a symlink, taking every
    # grok-build run down with it. Rationale in full beside grokSandboxToml above.
    # upstream-first: grepped home-manager/modules/lib/file-type.nix — home.file has no
    # copy/mutable mode → custom.
    grokSandboxProfile = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run mkdir -p "$HOME/.grok"
      run rm -f "$HOME/.grok/sandbox.toml"
      run cp -L "${grokSandboxToml}" "$HOME/.grok/sandbox.toml"
      run chmod u+w "$HOME/.grok/sandbox.toml"
    '';

    # Regenerate the HTML email signature (JSON Resume + bundled logo) into
    # ~/.local/share/email-signature/signature.html. Best-effort: the generator fetches
    # resume.json over the network and self-skips (keeping any existing artifact) when
    # offline, and `|| true` ensures a failed fetch never aborts a switch — it self-heals on
    # the next activation. Same "let the tool own its fetched, mutable state" pattern as
    # claudeCodePlugins. Custom on purpose: pinned home-manager's accounts/email.nix `signature.*`
    # options only configure a signature INSIDE a mail client (htmlFormat is Thunderbird-only);
    # nothing renders a standalone, paste-ready HTML file.
    emailSignature = lib.mkIf isMacosHost (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${email-signature}/bin/email-signature || true
      ''
    );
  };

}
