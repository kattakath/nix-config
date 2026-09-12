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
{ config, inputs, ... }:
let
  inherit (inputs)
    nixpkgs
    nix-darwin
    home-manager
    nix-vscode-extensions
    nix-homebrew
    determinate
    agenix
    firmware-secrets
    keychain-secrets
    media-cli
    local-rag
    nix-tart-vms
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
    ;

  # The first ABSORBED capsule (ADR-002 wave 3), reached through the flake's own
  # module registry rather than through an input. The engine may read a capsule;
  # a capsule may not read the engine — see modules/parts/capsules.nix.
  inherit (config.flake.modules.nixos) cloudflared-connector;

  inherit (config.fleet)
    identityArgs
    cachixUrl
    cachixKey
    operatorSshKey
    jsonResumeUrl
    logoUrl
    tokensUrl
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
  # home-manager modules — same role as `provision.sh` for Vast stacks: this
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
            keychain-secrets
            media-cli
            local-rag
            # nix-tart-vms: home.nix installs the gitlab-tart slot shims
            # (PATH-stable + GC-rooted so ~/.gitlab-runner/config.toml can
            # reference them). In extraSpecialArgs, NOT per-call — the
            # two-composition-call-sites lesson.
            nix-tart-vms
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
            # operatorSshKey: fleet operator public key — home.nix writes
            # ~/.ssh/allowed_signers from it so git can verify SSH commit sigs
            # (and the file stays in lockstep with secrets/operator-key.nix).
            operatorSshKey
            ;
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
      extraModules ? [ ],
      # Sites Caddy serves on this host — see the comment in
      # modules/parts/identity.nix and docs/private-home-modules.md. Public hosts
      # pass nothing (Caddy still runs, zero vhosts); a private composition flake
      # overrides it.
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
      specialArgs = identityArgs // {
        inherit
          cachixUrl
          cachixKey
          operatorSshKey
          firmware-secrets
          hostedSites
          ;
        # A MODULE, not a flake — hence the name. `firmware-secrets` above is
        # still an input (a flake, consumed as `.nixosModules.default`); this one
        # was too until wave 3 absorbed it, and the rename is the whole point: a
        # host that writes `cloudflaredConnectorModule.nixosModules.default`
        # fails loudly instead of half-resolving.
        cloudflaredConnectorModule = cloudflared-connector;
      };
      modules = [
        { nixpkgs.hostPlatform = system; }
        ../../hosts/${hostname}.nix
        ../nixos/core.nix
        ../shared/nix-cache.nix # Cachix binary cache (read)
        home-manager.nixosModules.home-manager
        (mkHomeManagerModule { idArgs = identityArgs; }) # NixOS hosts use the global identity
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
      identity ? identityArgs,
      extraModules ? [ ],
      # Private / third-party home-manager modules (see docs/private-home-modules.md).
      # Public hosts pass nothing; a private composition flake passes its modules here.
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
          };
          # LINUX BUILDS ON macOS (for `nix run .#nixvm`, `.#nixpi`):
          # Determinate's NATIVE Linux builder (Apple Virtualization framework —
          # no remote builder, no Docker) is ENABLED on this host, so aarch64-linux
          # and x86_64-linux derivations build locally on-demand. Verify with
          # `determinate-nixd version` (shows `native-linux-builder`); it appears
          # as an `external-builders` entry in `nix config show`. It is NOT
          # configured from Nix — `external-builders` is a reserved setting
          # Determinate manages and `determinateNix.customSettings` rejects it
          # (asserts at eval); it is a FlakeHub/account-level feature enabled
          # out-of-band via https://dtr.mn/features. It is a build-only, ephemeral,
          # 1-CPU/8GB sandbox — heavy multi-core builds (e.g. the cold RPi kernel)
          # are still best done in the GitHub-hosted CI. nix-darwin's
          # `nix.linux-builder` is unusable here — it requires `nix.enable = true`,
          # which Determinate turns off (nix-darwin#1505).
        }
        nix-homebrew.darwinModules.nix-homebrew # declaratively install brew (arch-correct prefix)
        # Provides `age.secrets.*` (host-decrypted agenix secrets) — dropped when
        # the fleet's runner retirement collapsed agenix to an operator-only vault
        # (#184), re-added 2026-08-23 for modules/darwin/github-runner.nix's
        # host-decrypted GitHub App key. Inert unless a host actually declares
        # `age.secrets.*`.
        agenix.darwinModules.default
        # tart.githubRunners.* option surface (ephemeral Tart-VM CI runners) —
        # in the BASE list, not per-call extraModules, so EVERY mkDarwin
        # composition has the options (nix-personal calls mkDarwin itself;
        # a per-call wire broke its eval — the PR #452 lesson, second
        # verse). Inert unless a host sets tart.githubRunners (hosts/macos.nix).
        nix-tart-vms.darwinModules.github-runner
        # tart.gitlabRunner option surface (declarative gitlab-runner on the
        # same Tart custom executor + slot budget). Same base-list rationale.
        # Inert unless a host enables it (hosts/macos.nix).
        nix-tart-vms.darwinModules.gitlab-runner
        ../../hosts/${hostname}.nix
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
  # Mirrors the Vast provisioner contract: this public flake is the engine;
  # private stacks plug in via `extraHomeModules` without forking hosts/.
  # Consumers: a private flake calls `nix-config.lib.mkDarwin { …; extraHomeModules = [ … ]; }`.
  # The terranix renderers join this same attrset from
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
