# ---- The three system builders — MOVED, NOT TRANSLATED ----------------------
#
# ADR-002 §6 is explicit about this file: the ~600 lines of `genAttrs` ->
# `perSystem` elsewhere in this wave are mechanical and provable by an empty
# `nix flake show` diff; THESE carry the operational knowledge, so they stay
# plain Nix functions inside the freeform `flake` attr and are copied verbatim.
# flake-parts modularises outputs, not builders — there is no `mkDarwin`
# flakeModule, and inventing one would be the motto's "proprietary monolith"
# half.
#
# Path literals are the one edit: they are resolved relative to THIS file
# (CLAUDE.md § Paths — two axes), so `./hosts/x.nix` became `../../hosts/x.nix`.
{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (inputs)
    nixpkgs
    nix-darwin
    home-manager
    nix-vscode-extensions
    nix-homebrew
    determinate
    agenix
    mcp-servers-nix
    raspberry-pi-nix
    agent-skills-vercel
    agent-skills-anthropic
    agent-skills-cloudflare
    agent-skills-anthropic-official
    agent-skills-jeffallan
    agent-skills-mac-automation
    agent-skills-excalidraw
    agent-skills-trailofbits
    agent-skills-superpowers
    agent-skills-jsonresume
    agent-skills-vercel-agent
    agent-skills-vercel-workflow
    agent-skills-litellm
    claude-plugins-official
    grok-build-plugin-cc
    kattakath-skills
    ;

  # ABSORBED capsules (ADR-002 waves 3 and 4), reached through the flake's own
  # module registry rather than through an input. The engine may read a capsule;
  # a capsule may not read the engine — see modules/parts/capsules.nix.
  inherit (config.flake.modules.nixos) cloudflared-connector firmware-secrets;
  # Home-manager capsule modules come through the RAW seam, not
  # `flake.modules` — see modules/parts/capsules.nix § The RAW module seam for
  # the measurement (deferredModule's wrapper reorders `home.packages`).
  inherit (config.capsuleModules.homeManager)
    keychain-secrets
    media-cli
    local-rag
    cloud-cli
    ;
  # tart-vms (wave 5) — through the RAW seam too, and for a SECOND reason on top
  # of the home.packages one: both runner modules `imports = [ ./slots.nix ]`,
  # and the module system dedupes by PATH IDENTITY. `flake.modules`'
  # deferredModule merge would hand the base list two anonymous
  # `{ imports = [ … ]; }` wrappers instead of two paths, so the shared
  # slots.nix would be collected twice. Named as the capsule spells them, then
  # used as bare paths below.
  inherit (config.capsuleModules.darwin) tart-github-runner tart-gitlab-runner;

  inherit (config.fleet)
    identityArgs
    cachixUrl
    cachixKey
    operatorSshKey
    jsonResumeUrl
    logoUrl
    tokensUrl
    publicMcpServers
    publicMcpPort
    googleAccount
    ;

  # The Home-Manager sub-module embedded in every host, built from an identity
  # attrset (`idArgs` = { loginName; fullName; userEmail; domainName; }) so a host
  # COULD carry a per-host persona rather than the single global identity, though
  # nothing in the fleet does today. Called with `identityArgs` by default; hosts
  # that override
  # (mkDarwin's `identity` arg) pass their own. The home-manager profile keys on
  # idArgs.loginName, and extraSpecialArgs threads that same identity into
  # modules/shared/home.nix. extraSpecialArgs also adds mcp-servers-nix etc.
  #
  # `extraHomeModules` is the public COMPOSITION HOOK for private (or third-party)
  # home-manager modules — the private layer's entrypoint: this
  # flake owns the contract, never the private stack. Callers (typically a
  # private flake that re-exports `darwinConfigurations.macos` via `lib.mkDarwin`)
  # pass zero or more modules; the public tree ships none. See
  # docs/private-home-modules.md.
  mkHomeManagerModule =
    {
      idArgs,
      extraHomeModules ? [ ],
    }:
    {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        # Back up (don't abort on) any pre-existing UNMANAGED file that a newly
        # Nix-managed home.file would clobber — e.g. ~/.claude/settings.json and
        # ~/.claude/plugins/known_marketplaces.json, now owned by the
        # programs.claude-code marketplaces/settings options. Without this, HM
        # activation hard-fails on the first such collision.
        backupFileExtension = "hm-bak";
        extraSpecialArgs = idArgs // {
          inherit
            mcp-servers-nix
            agent-skills-vercel
            agent-skills-anthropic
            agent-skills-cloudflare
            agent-skills-anthropic-official
            agent-skills-jeffallan
            agent-skills-mac-automation
            agent-skills-excalidraw
            agent-skills-trailofbits
            agent-skills-superpowers
            agent-skills-jsonresume
            agent-skills-vercel-agent
            agent-skills-vercel-workflow
            agent-skills-litellm
            claude-plugins-official
            grok-build-plugin-cc
            # This operator's OWN agent-resource repo (flake.nix), pinned only
            # for the superhook / page-lab-pick PATH packages.
            kattakath-skills
            # jsonResumeUrl: the raw resume.json URL (or null), consumed by home.nix
            # to bake into the jsonresume package as its default --url (darwin
            # home.packages; inert on the NixOS hosts).
            jsonResumeUrl
            # logoUrl: the raw logo.svg URL from the same gist (or null), consumed by
            # home.nix to bake into the email-signature package as its default
            # --logo-url (darwin only; inert on the NixOS hosts).
            logoUrl
            # tokensUrl: the raw tokens.json (DTCG brand tokens) URL from the same gist
            # (or null), baked into the email-signature package as its default
            # --tokens-url (darwin only; inert on the NixOS hosts).
            tokensUrl
            # operatorSshKey: fleet operator public key — home.nix feeds it to
            # programs.git.signing.allowedSigners so git can verify SSH commit sigs
            # (and the file stays in lockstep with secrets/operator-key.nix).
            operatorSshKey
            # publicMcpServers: the ONE list of servers published on the public MCP
            # gateway. The macos gateway hosts exactly this list, and
            # modules/parts/terranix.nix renders the SAME value into the portal
            # registrations. terranix renders outside any host's module system, so
            # it cannot read that option back — threading the fleet value to BOTH
            # consumers is what stops the two halves drifting into a portal entry
            # pointing at a server the gateway does not host.
            publicMcpServers
            # publicMcpPort: the loopback port that gateway binds, and the port
            # the tunnel's ingress routes to. It rides HERE, not in identityArgs,
            # and the distinction is the whole point: identityArgs is what a
            # consumer OVERRIDES through mkDarwin's `identity`, so anything routed
            # through it is ABSENT the moment they pass their own. This list is
            # fleet constants, supplied whatever identity the caller brings.
            #
            # It went into identityArgs on 2026-09-16 and broke exactly that way:
            # a template consumer's documented four-field identity turned
            # `local.mcpGateway.public = [ … ]` into "attribute 'publicMcpPort'
            # missing", naming a symbol that appears nowhere in the template, its
            # README or the option description — and only once they enabled the
            # feature. Its sibling above was always here; they belong together.
            publicMcpPort
            # googleAccount: the canonical identity (identity.nix). A FLEET constant,
            # so it rides here rather than in identityArgs for the reason stated on
            # publicMcpPort above — a consumer's four-field identity must keep working.
            # home.nix derives the gitlab.com include's address from it, so no
            # literal address is left in that file (ADR-004 §7, inventory #3).
            googleAccount
            ;
          # MODULE, not a flake — hence the name. It was the `keychain-secrets`
          # flake INPUT, consumed as `.homeManagerModules.default`, until ADR-002
          # wave 4 absorbed it (modules/features/keychain-secrets/). The rename is
          # the whole point: a consumer left writing
          # `keychainSecretsModule.homeManagerModules.default` fails loudly
          # instead of half-resolving. Same move as the two nixos capsules'
          # cloudflaredConnectorModule / firmwareSecretsModule in mkNixos below.
          keychainSecretsModule = keychain-secrets;
          # Same shape, same reason, one wave later: the `media-cli` flake INPUT
          # (consumed as `.homeManagerModules.default`) became the ABSORBED
          # capsule modules/features/media-cli/ in ADR-002 wave 5. A MODULE, so
          # the name says so — a consumer left writing
          # `mediaCliModule.homeManagerModules.default` fails loudly instead of
          # half-resolving. It rides the RAW seam for the `home.packages`
          # ordering reason above, which matters more here than anywhere else:
          # this module contributes the Mac's largest single package block.
          mediaCliModule = media-cli;
          # Third of the same shape, wave 6: the `local-rag` flake INPUT
          # (consumed as `.homeManagerModules.default`) became the ABSORBED
          # capsule modules/features/local-rag/. A MODULE, so the name says so
          # — a consumer left writing
          # `localRagModule.homeManagerModules.default` fails loudly instead of
          # half-resolving. RAW seam again, for the `home.packages` ordering
          # reason above: `local.rag.ollama` turns on home-manager's own
          # `services.ollama`, which contributes to that list.
          localRagModule = local-rag;
          # Fourth of the same shape (ADR-004 phase 3, born in-tree — no flake
          # input ever existed): the AWS CLI + `~/.aws/config.example` capsule,
          # modules/features/cloud-cli/. RAW seam for the home.packages reason.
          cloudCliModule = cloud-cli;
          # A SOURCE PATH, not a module and not a derivation — home.nix
          # `callPackage`s it with the HOST's pkgs so the five gitlab-tart slot
          # shims are built against `nixpkgs.config.allowUnfree` from
          # hosts/macos.nix, exactly as they were when this came from the
          # nix-tart-vms input. It was the `nix-tart-vms` flake input until
          # ADR-002 wave 5; keeping it in extraSpecialArgs rather than per-call
          # is the two-composition-call-sites lesson, unchanged. Why a capsule
          # publishes a path at all: modules/parts/capsules.nix § The SOURCE
          # seam.
          gitlabTartSource = config.capsuleSources.tart-vms.gitlab-tart;
        };
        users.${idArgs.loginName} = {
          imports = [ ../shared/home.nix ] ++ extraHomeModules;
          home.stateVersion = "24.05";
        };
      };
    };

  # ---- NixOS system builder -----------------------------------------------
  # Full NixOS system with Home Manager embedded, using the same shared user
  # profile as the darwin host.
  mkNixos =
    {
      system,
      hostname,
      # WHICH host profile to load — the twin of mkDarwin's `hostModule` below,
      # and it outlived that fix (c4a522a) by a day because only the darwin half
      # was hardened. Same mechanism: `hostname` is a STRING indexing the
      # ENGINE's directory, so a downstream consumer inherits the operator's
      # host wholesale. Measured 2026-09-16 — `mkNixos { hostname = "nixvm"; }`
      # for a caller with no connection to this fleet evaluated to
      # `users.users.ismail` present, holding the OPERATOR'S ssh-ed25519 public
      # key as its sole authorized key, with `loginName` in
      # `nix.settings.trusted-users` (modules/nixos/core.nix:18-21, :34) and
      # `wheel`. `lib.mkNixos` is a real flake output and flakehub-publish.yml
      # publishes this flake with `visibility: public`.
      #
      # Point it at `hosts/generic-linux.nix` for a host that carries nothing
      # personal. `hostname` still selects the default and is otherwise unused.
      hostModule ? ../../hosts/${hostname}.nix,
      identity ? identityArgs,
      # The login credential, granted as `authorizedKeys` by
      # modules/nixos/core.nix. DEFAULTS TO NONE, deliberately unlike `identity`
      # above: a name being wrong is cosmetic, a key being wrong is an ACCOUNT on
      # someone else's server. The fleet's own hosts pass the fleet value
      # explicitly at the call site (modules/parts/hosts.nix), so the grant is
      # visible where the host is declared rather than inherited silently.
      operatorSshKey ? null,
      extraModules ? [ ],
      # Sites Caddy serves on this host — see the comment in
      # modules/parts/identity.nix and docs/private-home-modules.md. The fleet's
      # own hosts pass `config.fleet.hostedSites` at the call site
      # (modules/parts/hosts.nix); a caller that passes nothing still gets Caddy,
      # with zero vhosts.
      hostedSites ? [ ],
    }:
    nixpkgs.lib.nixosSystem {
      # Set the platform via the MODERN `nixpkgs.hostPlatform` module option
      # (below), NOT nixosSystem's legacy `system` arg — that arg only sets
      # the deprecated `nixpkgs.system`, leaving `nixpkgs.hostPlatform`
      # undefined. Modules that read `config.nixpkgs.hostPlatform.system`
      # would otherwise fail with "option `nixpkgs.hostPlatform' was accessed
      # but has no value". The two cannot both be set (nixpkgs forbids it), so
      # we drop the arg entirely.
      # Cachix substituter URL + trusted-PUBLIC-key (verification key, safe to
      # expose — NOT a secret) consumed by modules/shared/nix-cache.nix;
      # operatorSshKey (the authorizedKeys credential) by modules/nixos/core.nix.
      # Both are NixOS-only, so they are not in mkDarwin's specialArgs.
      specialArgs = identity // {
        inherit
          cachixUrl
          cachixKey
          operatorSshKey
          hostedSites
          ;
        # MODULES, not flakes — hence the names. Both of these were flake INPUTS
        # consumed as `.nixosModules.default` until ADR-002 absorbed them
        # (cloudflared-connector in wave 3, firmware-secrets in wave 4), and the
        # rename is the whole point: a host left writing
        # `firmwareSecretsModule.nixosModules.default` fails loudly instead of
        # half-resolving.
        cloudflaredConnectorModule = cloudflared-connector;
        firmwareSecretsModule = firmware-secrets;
        # The Pi's hardware modules (kernel/firmware/sd-image) reach
        # hosts/nixpi.nix through here, NOT through a per-call `extraModules`:
        # that per-call wiring made the private nix-personal flake (retired
        # 2026-09-15) repeat the same two modules to build the same Pi — a shape
        # leak. nix-config must build every host standalone; a composition layer
        # passes data only.
        raspberryPiNix = raspberry-pi-nix;
        # For hosts/nixvm.nix's `build-vm` variant, whose QEMU runner executes
        # on the aarch64-darwin Mac. LAZY: only `system.build.vm` forces it, so
        # the aarch64-linux toplevel eval (CI) never pulls in darwin pkgs. Same
        # principle as raspberryPiNix above — a host's shape lives in its own
        # file, never in a per-call `extraModules`.
        darwinPkgs = nixpkgs.legacyPackages."aarch64-darwin";
      };
      modules = [
        { nixpkgs.hostPlatform = system; }
        hostModule
        ../nixos/core.nix
        ../shared/nix-cache.nix # Cachix binary cache (read)
        # Determinate Nix on the NixOS hosts too (2026-09-21, the org-adoption
        # guide's "install Determinate Nix" step). Unlike the darwin module, this
        # one does NOT disable `nix.*`: it swaps `nix.package` for Determinate's
        # Nix, runs `determinate-nixd` as nix-daemon's ExecStart, and retargets
        # the generated nix.conf to /etc/nix/nix.custom.conf (included by the
        # nixd-managed one) — so core.nix's `nix.settings` and nix-cache.nix keep
        # applying unchanged. It is prebuilt: the aarch64-linux Nix package is
        # served by install.determinate.systems (nix-cache.nix carries that
        # substituter + key precisely so the Pi and the warm-cache runner FETCH
        # it rather than build a C++ Nix). nixpi must never build (CLAUDE.md).
        determinate.nixosModules.default
        home-manager.nixosModules.home-manager
        (mkHomeManagerModule { idArgs = identity; })
      ]
      ++ extraModules;
    };

  # ---- nix-darwin system builder ------------------------------------------
  # Mirrors mkNixos for the Mac. hostPlatform is driven from `system` (NOT
  # hardcoded in modules/darwin/core.nix) even though this fleet has a single
  # darwin host today.
  # `identity` defaults to the global identityArgs; a host COULD pass its own to
  # run under a per-host persona (different loginName/fullName/userEmail/
  # domainName), though nothing in the fleet does today. It flows to the system
  # modules via
  # specialArgs AND to home-manager via mkHomeManagerModule, so the two agree.
  mkDarwin =
    {
      system,
      hostname,
      # WHICH host profile to load. Defaults to this repo's `hosts/<hostname>.nix`,
      # which is right for the fleet's own hosts — but `hostname` is a STRING that
      # indexes the ENGINE's directory, so a downstream consumer passing
      # `hostname = "macos"` silently inherits the OPERATOR'S ~900-line host:
      # the operator's own account, both self-hosted CI runner lanes, and 34
      # Homebrew casks — all evaluated for a caller with no connection to this
      # fleet (measured 2026-09-15).
      #
      # That defeats the reason templates/ exists: consume the engine INSTEAD of
      # forking it. So the host is now a MODULE, not just a name — pass your own,
      # or point at `hosts/generic-darwin.nix` for a host that carries nothing
      # personal. `hostname` still selects the default and is otherwise unused.
      hostModule ? ../../hosts/${hostname}.nix,
      identity ? identityArgs,
      extraModules ? [ ],
      # Private / third-party home-manager modules (see docs/private-home-modules.md).
      # A generic seam with no second caller today — nix-personal, the flake that
      # used it, was retired 2026-09-15 — and the fleet's own hosts pass nothing.
      extraHomeModules ? [ ],
    }:
    nix-darwin.lib.darwinSystem {
      inherit system;
      specialArgs = identity;
      modules = [
        {
          nixpkgs.hostPlatform = system;
          nixpkgs.overlays = [ nix-vscode-extensions.overlays.default ];
        }
        # Determinate Nix owns the daemon + /etc/nix/nix.conf on macOS
        # (implies nix.enable = false). Route the Cachix cache through
        # /etc/nix/nix.custom.conf via customSettings — NEVER hand-write
        # environment.etc."nix/nix.custom.conf" (that aborts the 2nd rebuild
        # with "custom settings in /etc/nix/nix.custom.conf, aborting
        # activation"). Replaces ./modules/shared/nix-cache.nix here (that
        # module is now NixOS-only, since nix.settings is unavailable once
        # Determinate manages Nix).
        determinate.darwinModules.default
        {
          determinateNix.enable = true; # implies nix.enable = false
          determinateNix.customSettings = {
            extra-substituters = [ cachixUrl ];
            extra-trusted-public-keys = [ cachixKey ];

            # DEDUPLICATE AS PATHS LAND (2026-09-15). This store ran its whole
            # life with hard-linking off: the first `nix store optimise` after a
            # 22.1 GiB garbage collection linked 326,352 files and returned a
            # further ~4 GiB, and `nix-collect-garbage` had been reporting "hard
            # linking is currently saving 0.0 KiB" all along. Setting it here
            # makes that continuous rather than a ritual nobody remembers to run
            # — the cost is a hash+link step on every store write, which is the
            # right trade on a machine that substitutes whole fleet closures.
            # Allowed: it is absent from Determinate's `disallowedOptions`
            # (modules/nix-darwin/default.nix) and used in their own test flake.
            auto-optimise-store = true;

            # WHY THE OPERATOR IS TRUSTED (2026-09-15). Nix's default is
            # `trusted-users = root`, and a NON-trusted user's client-side
            # settings are silently discarded by the daemon. That is not a
            # theoretical limit — it is the root cause of the "nixpi must build
            # itself" saga: after CI warms the closure into Cachix, a Mac that
            # had already queried those paths while they were absent keeps the
            # 404 in its narinfo NEGATIVE cache for an hour and goes on planning
            # a BUILD. The one-word fix, `--narinfo-cache-negative-ttl 0`, is
            # answered with "ignoring the client-specified setting … you are not
            # a trusted user", so the operator cannot clear it at all and the
            # tempting escape is to move the build onto the Pi (now blocked,
            # .claude/hooks/pretooluse-bash-guard.js Rule 1d). Same mechanism
            # silently ignores `--builders` and `--max-jobs 0`.
            #
            # Cost, stated rather than waved past: a trusted user can set
            # substituters and other restricted settings for their own builds,
            # which is close to root-equivalent for store CONTENT. Accepted for
            # the OPERATOR alone: that user already has admin + sudo and owns
            # this very file, so the grant adds no capability they lacked — it
            # only stops the daemon discarding their intent.
            #
            # "admin" is a macOS role, "trusted" is a Nix-daemon role — they are
            # NOT the same grant. Any future account gets the macOS one by
            # itself; this list grows only as a recorded decision. From an
            # untrusted session every restricted client option (`--option …`,
            # notably the documented nixpi cache-trap escape
            # `--narinfo-cache-negative-ttl 0`) is answered with "ignoring the
            # client-specified setting … you are not a trusted user", while
            # everything DAEMON-side — the Cachix substituter and key above —
            # still applies.
            #
            # Lands in /etc/nix/nix.custom.conf (rendered by customSettings),
            # which the daemon reads only at startup — see
            # docs/new-mac-runbook.md, "INERT until the nix daemon restarts".
            #
            # `extra-trusted-users`, not `trusted-users`: appends rather than
            # replacing, so `root` survives and a future Determinate default is
            # not clobbered — same additive shape as the two lines above.
            # `identity.loginName` (not a literal) so a per-host `identity`
            # override, which templates/default/ uses, trusts ITS own operator.
            extra-trusted-users = [ identity.loginName ];
          };
          # Let determinate-nixd collect garbage in the background instead of
          # waiting for a hand-run `sudo nix-collect-garbage -d` (the 2026-09-15
          # one freed 22.1 GiB, i.e. it had been deferred far too long). Two
          # consequences, accepted rather than discovered later: old generations
          # are reaped on ITS schedule, so there is no guaranteed rollback target
          # on this Mac; and collected flake-input sources are re-fetched on the
          # next eval. Neither touches nixpi — it is a separate daemon, and
          # deploy-rs magicRollback protects the Pi's own generation.
          determinateNix.determinateNixd.garbageCollector.strategy = "automatic";
          # LINUX BUILDS ON macOS (for `nix run .#nixvm`, `.#nixpi`):
          # Determinate's NATIVE Linux builder (Apple Virtualization framework —
          # no remote builder, no Docker) is ENABLED on this host, so aarch64-linux
          # and x86_64-linux derivations build locally on-demand. Verify with
          # `determinate-nixd version` (shows `native-linux-builder`); it appears
          # as an `external-builders` entry in `nix config show`. The raw
          # `external-builders` line is reserved — Determinate renders it and
          # `determinateNix.customSettings` rejects it (asserts at eval) — but the
          # VM itself IS configurable here since the pinned module grew
          # `determinateNix.determinateNixd.builder.{state,memoryBytes,cpuCount}`
          # (-> /etc/determinate/config.json; defaults enabled / 8 GiB / 1 CPU,
          # and upstream's option text says do NOT change cpuCount). The account
          # entitlement is still out-of-band: https://dtr.mn/features. It is a
          # build-only, ephemeral sandbox — heavy multi-core builds (e.g. the cold
          # RPi kernel) are still best done in the GitHub-hosted CI. nix-darwin's
          # `nix.linux-builder` is unusable here — it requires `nix.enable = true`,
          # which Determinate turns off (nix-darwin#1505).
          #
          # POST-ACTIVATION NUDGE. The builder above is an account entitlement
          # PLUS a per-machine daemon login, and only the first half is declared
          # anywhere. A fresh Mac — or a rebuilt daemon — is logged out, the
          # rendered `external-builders` is empty, and every aarch64-linux build
          # then dies with "platform mismatch — Required system: 'aarch64-linux',
          # Current system: 'aarch64-darwin'". That reads as a flake bug and is
          # not one: it is an AUTH gap, and the cost of not saying so is an hour
          # of debugging the wrong layer (docs/new-mac-runbook.md records it as a
          # manual step precisely because it kept being rediscovered).
          #
          # Nothing here can perform the login — it needs a FlakeHub token from a
          # browser — so this only PROBES and prints the fix, the same shape as
          # the macos-automator TCC nudge in modules/shared/mcp.nix:1317. It is
          # silent once the feature is advertised, and silent when the binary is
          # absent or errors, so it cannot nag on a healthy rebuild.
          #
          # Probes `version` (the FEATURE list), not `status` (the login flag):
          # the feature is what a build actually consumes, and it also catches
          # the daemon that is logged in but too STALE to offer it — the second
          # failure mode the runbook records, which a login check would miss.
          #
          # upstream-first: `system.activationScripts.postActivation` is
          # nix-darwin's own last-phase hook (verified against the pinned module:
          # it sits alongside extraActivation/extraPostActivation/
          # extraUserPostActivation), so this adds no scheduling of ours.
          system.activationScripts.postActivation.text = lib.mkAfter ''
            if [ -x /usr/local/bin/determinate-nixd ] \
              && dnd_version="$(/usr/local/bin/determinate-nixd version 2>/dev/null)"; then
              case "$dnd_version" in
                *native-linux-builder*) : ;; # entitled AND logged in — nothing to say.
                *)
                  echo "" >&2
                  echo "  ⚠ Determinate's native Linux builder is NOT active on this Mac." >&2
                  echo "    Every aarch64-linux build — nix run .#nixvm, .#nixpi, the Pi closure —" >&2
                  echo "    fails with 'platform mismatch'. That is an AUTH gap, not a config bug." >&2
                  echo "    One-time, per machine:" >&2
                  echo "      1. mint a token:  https://flakehub.com/user/settings?editview=tokens" >&2
                  echo "      2. store it:      secret set FLAKEHUB_TOKEN" >&2
                  echo "      3. log in:        secret exec FLAKEHUB_TOKEN -- sh -c \\" >&2
                  echo "           'determinate-nixd auth login token --token-file <(printf %s \"\$FLAKEHUB_TOKEN\")'" >&2
                  echo "    If it persists, the daemon may be stale:  sudo determinate-nixd upgrade" >&2
                  echo "    Verify:  determinate-nixd version | grep native-linux-builder" >&2
                  echo "    Details: docs/new-mac-runbook.md" >&2
                  ;;
              esac
            fi
          '';
        }
        nix-homebrew.darwinModules.nix-homebrew # declaratively install brew (arch-correct prefix)
        # Provides `age.secrets.*` (host-decrypted agenix secrets) — dropped when
        # the fleet's runner retirement collapsed agenix to an operator-only vault
        # (#184), re-added 2026-08-23 for modules/darwin/github-runner.nix's
        # host-decrypted GitHub App key. Inert unless a host actually declares
        # `age.secrets.*`.
        agenix.darwinModules.default
        # local.tart.githubRunners.* option surface (ephemeral Tart-VM CI runners) —
        # in the BASE list, not per-call extraModules, so EVERY mkDarwin
        # composition has the options (nix-personal called mkDarwin itself and a
        # per-call wire broke its eval — the PR #452 lesson, second verse; that
        # flake went 2026-09-15, but the argument holds for any future caller).
        # Inert unless a host sets local.tart.githubRunners (hosts/macos.nix).
        tart-github-runner
        # local.tart.gitlabRunner option surface (declarative gitlab-runner on the
        # same Tart custom executor + slot budget). Same base-list rationale.
        # Inert unless a host enables it (hosts/macos.nix).
        tart-gitlab-runner
        hostModule
        home-manager.darwinModules.home-manager
        (mkHomeManagerModule {
          idArgs = identity;
          inherit extraHomeModules;
        })
      ]
      ++ extraModules;
    };
in
{
  # ---- Composition API (private flakes, local overrides) --------------------
  # The composition contract: this public flake is the engine; a private
  # stack could plug in via `extraHomeModules` without forking hosts/ (no
  # caller does today — see docs/repo-map.md, nix-personal retired
  # 2026-09-15). The terranix renderers join this same attrset from
  # modules/parts/terranix.nix — see modules/parts/lib-option.nix for why that
  # is possible at all.
  flake.lib = {
    inherit
      mkDarwin
      mkNixos
      mkHomeManagerModule
      identityArgs
      ;
  };
}
