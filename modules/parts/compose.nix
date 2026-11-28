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
  ...
}:
let
  inherit (inputs)
    nixpkgs
    nix-darwin
    home-manager
    nix-vscode-extensions
    nix-homebrew
    nix-plist-manager
    agenix
    nixos-hardware
    agent-skills-excalidraw
    agent-skills-mac-automation
    agent-skills-vercel-agent
    nixpkgs-claude-code
    ;

  # The fleet store-retention policy (darwin customSettings min-free/max-free).
  storeRetention = import ../_lib/store-retention.nix;

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
    jsonResumeUrl
    logoUrl
    tokensUrl
    ;

  # The Home-Manager sub-module embedded in every host, built from an identity
  # attrset (`idArgs` = { loginName; fullName; userEmail; domainName; }) so a host
  # COULD carry a per-host identity rather than the single global identity, though
  # nothing in the fleet does today. Called with `identityArgs` by default; hosts
  # that override
  # (mkDarwin's `identity` arg) pass their own. The home-manager profile keys on
  # idArgs.loginName, and extraSpecialArgs threads that same identity into
  # modules/home/default.nix.
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
        # Nix-managed home.file would clobber. Without this, HM activation
        # hard-fails on the first such collision.
        backupFileExtension = "hm-bak";
        extraSpecialArgs = idArgs // {
          # Reviewed commit per third-party marketplace, keyed by its marketplace name;
          # flake.lock is the one copy (the `marketplace-*` inputs).
          marketplaceRevs = {
            context7-marketplace = inputs.marketplace-context7.rev;
            trailofbits = inputs.marketplace-trailofbits.rev;
            fullstack-dev-skills = inputs.marketplace-fullstack-dev-skills.rev;
            grafana-skills = inputs.marketplace-grafana-skills.rev;
          };
          inherit
            agent-skills-excalidraw
            agent-skills-mac-automation
            agent-skills-vercel-agent
            nixpkgs-claude-code
            # kattakath-skills is DELIBERATELY ABSENT from this seam (removed
            # 2026-10-02, when its last home-manager consumer died). The pin is still
            # load-bearing — modules/parts/checks.nix (grep `inputs.kattakath-skills`) — but it
            # reads `inputs.kattakath-skills` directly in the FLAKE ENGINE, where
            # `inputs` is already in scope. It is not a home-manager module, so nothing reached
            # through here; an extraSpecialArg no module declares is dead weight that
            # deadnix structurally cannot see (it was `inherit`ed, hence "used").
            # jsonResumeUrl: the raw resume.json URL (or null), consumed by modules/home/default.nix
            # to bake into the jsonresume package as its default --url (darwin
            # home.packages; inert on the NixOS hosts).
            jsonResumeUrl
            # logoUrl: the raw logo.svg URL from the same gist (or null), consumed by
            # modules/home/default.nix to bake into the email-signature package as its default
            # --logo-url (darwin only; inert on the NixOS hosts).
            logoUrl
            # tokensUrl: the raw tokens.json (DTCG brand tokens) URL from the same gist
            # (or null), baked into the email-signature package as its default
            # --tokens-url (darwin only; inert on the NixOS hosts).
            tokensUrl
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
        };
        users.${idArgs.loginName} = {
          # `../home` is a DIRECTORY literal — Nix resolves it to
          # modules/home/default.nix, the profile's entry point.
          imports = [ ../home ] ++ extraHomeModules;
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
      # host wholesale. Measured 2026-09-16 — `mkNixos { hostname = "nixos"; }`
      # for a caller with no connection to this fleet evaluated to
      # `users.users.ismail` present, holding the OPERATOR'S ssh-ed25519 public
      # key as its sole authorized key, with `loginName` in
      # `nix.settings.trusted-users` (modules/nixos/core.nix) and
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
      # The heartbeat slug registry (`config.fleet.heartbeats`), for
      # modules/nixos/service-heartbeat.nix's eval-time "the slug exists" assertion.
      # Defaults to none: a host that pings nothing never reads it.
      fleetHeartbeats ? { },
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
      # expose — NOT a secret) consumed by modules/nixos/nix-cache.nix;
      # operatorSshKey (the authorizedKeys credential) by modules/nixos/core.nix.
      # Both are NixOS-only, so they are not in mkDarwin's specialArgs.
      specialArgs = identity // {
        inherit
          cachixUrl
          cachixKey
          operatorSshKey
          hostedSites
          fleetHeartbeats
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
        # that per-call wiring made the private [redacted] flake (retired
        # 2026-09-15) repeat the same two modules to build the same Pi — a shape
        # leak. nix-config must build every host standalone; a composition layer
        # passes data only.
        nixosHardware = nixos-hardware;
        # For hosts/nixos.nix's `build-vm` variant, whose QEMU runner executes
        # on the aarch64-darwin Mac. LAZY: only `system.build.vm` forces it, so
        # the aarch64-linux toplevel eval (CI) never pulls in darwin pkgs. Same
        # principle as nixosHardware above — a host's shape lives in its own
        # file, never in a per-call `extraModules`.
        darwinPkgs = nixpkgs.legacyPackages."aarch64-darwin";
      };
      modules = [
        { nixpkgs.hostPlatform = system; }
        hostModule
        ../nixos/core.nix
        ../nixos/nix-cache.nix # Cachix binary cache (read)
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
  # run under a per-host identity (different loginName/fullName/userEmail/
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
      # A generic seam with no second caller today — [redacted], the flake that
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
        # nix-darwin owns the Nix daemon and /etc/nix/nix.conf (`nix.enable`, the
        # default). Until 2026-11-27 Determinate Nix did, and this block routed the
        # same settings through `determinateNix.customSettings`; ADR-018 moved every
        # host to upstream Nix and retired that lane. The Linux builder and the
        # store GC are nix-darwin's own (modules/darwin/nix.nix).
        (
          { pkgs, ... }:
          let
            daemonSettings = {
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
              auto-optimise-store = true;

              # Build-time GC floor — same values as NixOS, one source
              # (modules/_lib/store-retention.nix).
              min-free = storeRetention.minFree;
              max-free = storeRetention.maxFree;

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
              # Lands in /etc/nix/nix.conf, which the daemon reads only at
              # startup (nix-darwin restarts it when the file changes) — see
              # docs/new-mac-runbook.md, "INERT until the nix daemon restarts".
              #
              # `extra-trusted-users`, not `trusted-users`: appends rather than
              # replacing, so `root` survives and a future default is not
              # clobbered — same additive shape as the two lines above.
              # `identity.loginName` (not a literal) so a per-host `identity`
              # override, which templates/default/ uses, trusts ITS own operator.
              extra-trusted-users = [ identity.loginName ];
            };
          in
          {
            nix = {
              package = pkgs.nix;
              settings = daemonSettings // {
                # Upstream still marks flakes experimental (Determinate turned
                # them on by default).
                experimental-features = [
                  "nix-command"
                  "flakes"
                ];
                # Upstream defaults to false and then BUILDS every
                # allowSubstitutes = false wrapper (boot.json, a system toplevel,
                # deploy-rs's activatable) instead of fetching it — seen on the
                # 2026-11-27 nixpi deploy. Determinate's nix.conf set it.
                always-allow-substitutes = true;
              };
            };
          }
        )
        nix-homebrew.darwinModules.nix-homebrew # declaratively install brew (arch-correct prefix)
        # Provides `age.secrets.*` (host-decrypted agenix secrets) — dropped when
        # the fleet's runner retirement collapsed agenix to an operator-only vault
        # (#184), re-added 2026-08-23 for modules/darwin/github-runner.nix's
        # host-decrypted GitHub App key. Inert unless a host actually declares
        # `age.secrets.*`.
        agenix.darwinModules.default
        # local.tart.githubRunners.* option surface (ephemeral Tart-VM CI runners) —
        # in the BASE list, not per-call extraModules, so EVERY mkDarwin
        # composition has the options ([redacted] called mkDarwin itself and a
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
        # `programs.nix-plist-manager` (System Settings as typed options) for the
        # macOS user only — `sharedModules` here, not mkHomeManagerModule, which
        # the NixOS hosts share. Base list for the same reason as the tart
        # surfaces above. Inert until a module enables it (modules/darwin/core.nix).
        { home-manager.sharedModules = [ nix-plist-manager.homeManagerModules.default ]; }
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
  # caller does today — see docs/map/engine.md, [redacted] retired
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
