# ---- Remote activation: deploy-rs -------------------------------------------
#
# deploy-rs has NO flakeModule — grepped the pinned source (its flake.nix
# exports `lib`, `packages`, `overlays`, `defaultPackage`, `checks`, nothing
# module-shaped). So `flake.deploy` stays hand-written in the freeform `flake`
# attr, and this file says so out loud rather than implying flake-parts
# modularises it.
{ config, inputs, ... }:
let
  inherit (inputs) nixpkgs deploy-rs;
  inherit (config.fleet) loginName domainName;

  # `self.deploy` with every `profiles.*.path` demoted from a derivation to a
  # PLAIN (context-free) store-path string. Handing deploy-schema `self.deploy`
  # raw looks obviously right and is a trap: it does
  # `writeText (builtins.toJSON deploy)`, `toJSON` renders a derivation as its
  # outPath *carrying string context*, and writeText turns that context into a
  # real inputDrv. Measured, not guessed — the naive check's deploy.json.drv
  # references `activatable-nixos-system-nixpi…drv`, whose closure contains
  # `linux-rpi-6.6.51.drv`. That would make `nix flake check`, `/eval` and
  # nix-ci.yml build the Pi's COLD KERNEL to run a JSON-schema assertion.
  # unsafeDiscardStringContext keeps the byte-identical string, so the schema
  # still validates a real `"path": "/nix/store/…"` and the check's verdict is
  # unchanged — only the phantom build edge is gone.
  # (`config.flake.deploy` rather than `self.deploy`: the same value, reached
  # without a round trip through `processedFlake`.)
  deploySchemaSubject = config.flake.deploy // {
    nodes = nixpkgs.lib.mapAttrs (
      _: node:
      node
      // {
        profiles = nixpkgs.lib.mapAttrs (
          _: profile: profile // { path = builtins.unsafeDiscardStringContext "${profile.path}"; }
        ) node.profiles;
      }
    ) config.flake.deploy.nodes;
  };
in
{
  # ---- Remote activation: deploy-rs nodes (MAGIC ROLLBACK) -----------------
  #
  # ⚠ NEVER `deploy .#nixpi` FROM THIS PUBLIC REPO for a real deploy. ⚠
  #
  # Exactly the same trap as `darwin-rebuild switch --flake .#macos`: the node
  # below points at THIS repo's `nixosConfigurations.nixpi`, which is the
  # SITE-FREE public baseline. `hostedSites` defaults to `[ ]` here, so a
  # successful deploy from this tree hands the live Pi a Caddy with ZERO
  # vhosts and no dontsell.ai connector unit — kattakath.com, snoringirl.com,
  # ismail.kattakath.com and dontsell.ai all go dark, while sshd and the
  # primary tunnel keep working. Magic rollback CANNOT save you from that: it
  # only reverts an activation that leaves the host UNREACHABLE, and a
  # site-free Pi is perfectly reachable — deploy-rs would report SUCCESS.
  # The real sites live in the private nix-personal flake; deploy from there.
  #
  # This node still ships here because it is the ENGINE, not the deployment —
  # same public-engine / private-plug-in contract as `mkNixos { hostedSites }`
  # and `mkDarwin { extraHomeModules }`. nix-personal re-exports its own
  # `deploy.nodes.nixpi` by reusing these settings against ITS
  # `nixosConfigurations.nixpi` (see docs/private-home-modules.md), so the
  # rollback semantics, timeouts and ssh plumbing are single-sourced here and
  # never re-derived in the private tree.
  #
  # `deploy` with no `--targets` fans out over EVERY node, so an
  # argument-less `deploy` in this repo IS a live-Pi deploy. Always name the
  # target.
  flake.deploy.nodes.nixpi = {
    # The TUNNELLED hostname, not nixpi.local: the Pi has no public IP and no
    # port-forward, and the LAN name only resolves when the Mac happens to be
    # on the same network. Reaching it needs a `ProxyCommand cloudflared
    # access ssh --hostname %h`, which modules/shared/home.nix now declares as
    # a real `Host nixpi.<domain>` block — so plain `ssh` resolves it, and so
    # does the `nix copy --to ssh://…` leg (nix shells out to the system ssh,
    # which reads ~/.ssh/config). That is why `sshOpts` stays EMPTY: deploy-rs
    # space-joins sshOpts into NIX_SSHOPTS, which nix re-splits on whitespace,
    # so an inline `-o ProxyCommand=cloudflared access ssh …` would be
    # mangled for the copy leg. ~/.ssh/config is the only place a spaced
    # ProxyCommand survives both legs.
    # NOTE: this path also depends on a Cloudflare Zero Trust *Access
    # Application* for the hostname existing — hand-created, NOT in terranix,
    # and it silently vanished once (2026-08-20). See docs/private-home-modules.md.
    hostname = "nixpi.${domainName}";

    # Who we SSH in as (the operator, keys-only) vs who ACTIVATES (root, via
    # passwordless sudo — modules/nixos/core.nix puts the operator in `wheel`
    # with `security.sudo.wheelNeedsPassword = false`, so no `interactiveSudo`).
    # loginName comes from identityArgs, never a literal.
    sshUser = loginName;

    # THE WHOLE REASON THIS EXISTS. magicRollback makes the Pi wait for a
    # confirmation over a fresh ssh connection after activating; autoRollback
    # covers the other half (an activation script that exits non-zero). With
    # both on, the failure mode of a bad nixpi generation is "deploy failed,
    # Pi still serving" instead of "drive home and reflash the SD card".
    magicRollback = true;
    autoRollback = true;

    # The Pi must NEVER build. remoteBuild = true copies the *derivation* and
    # runs `nix build --store ssh-ng://` on the target — a Pi 4 building the
    # closure (worst case the cold linux-rpi kernel) is exactly what
    # CLAUDE.md forbids. false = build on the Mac / pull from CI's Cachix push.
    remoteBuild = false;

    # Deliberately NOT `fastConnection = true`: that flag DROPS
    # `--substitute-on-destination` from the `nix copy`, forcing the entire
    # closure through the Cloudflare Tunnel. Left false so the Pi substitutes
    # from the public Cachix cache itself (modules/shared/nix-cache.nix) and
    # only the cache misses cross the tunnel.
    fastConnection = false;

    # Both defaults are too tight for THIS target, and a timeout here does not
    # mean "slow" — it means an unattended ROLLBACK of a good deploy.
    # activationTimeout: a Pi 4 on an SD card takes minutes to run
    # switch-to-configuration + restart units (upstream default is 240s).
    # confirmTimeout: the confirmation rides a SECOND ssh session that must
    # re-dial the tunnel and re-do Cloudflare Access (upstream default 30s).
    activationTimeout = 600;
    confirmTimeout = 120;

    profiles.system = {
      user = "root";
      # `activate.nixos` wraps the toplevel in a buildEnv that adds the
      # deploy-rs activator scripts, and installs into /nix/var/nix/profiles/
      # system — the SAME profile `nixos-rebuild` uses, so generations and
      # `nixos-rebuild --rollback` stay unified across both tools.
      # The system is read off the config rather than written twice.
      path =
        deploy-rs.lib.${config.flake.nixosConfigurations.nixpi.config.nixpkgs.hostPlatform.system}.activate.nixos
          config.flake.nixosConfigurations.nixpi;
    };
  };

  # ---- deploy-rs schema gate (per system) ---------------------------------
  # deploy-rs ships TWO deployChecks; we take exactly ONE of them, on purpose.
  #
  #   deploy-schema   ✅ validates `self.deploy` against deploy-rs' own
  #                      interface.json. Cheap: a check-jsonschema run over a
  #                      serialised attrset. KNOW WHAT IT DOES AND DOES NOT
  #                      COVER, because the difference is load-bearing here:
  #                      it checks TYPES on KNOWN keys (`magicRollback = "yes"`
  #                      → `'yes' is not of type 'boolean', 'null'`), the
  #                      REQUIRED keys (`hostname`, `profiles.*.path`), and the
  #                      node/profile NAME pattern. It does NOT reject UNKNOWN
  #                      keys: interface.json sets `additionalProperties: false`
  #                      on the `nodes` and `profiles` MAPS only (to constrain
  #                      names), never on `generic_settings`/`node_settings`/
  #                      `profile_settings`. So a typo'd `magicRollBack` /
  #                      `confirmTimeOut` VALIDATES CLEAN — measured against
  #                      this exact schema, exit 0 — and the Pi then deploys
  #                      with magic rollback silently OFF. Renaming a setting is
  #                      still a HUMAN review item; this gate cannot catch it.
  #   deploy-activate ❌ EXCLUDED. It interpolates `toString profile.path`, so
  #                      the derivation BUILD-DEPENDS on nixpi's activatable
  #                      closure — i.e. the full aarch64-linux toplevel, worst
  #                      case the cold linux-rpi kernel. `checks` is what
  #                      `nix flake check`, /eval and nix-ci.yml build, and all
  #                      three are deliberately lint-only (see
  #                      modules/parts/checks.nix). Adding it would turn every
  #                      `/eval` into a Pi-closure build on Determinate's 1-CPU
  #                      Linux builder. All it asserts is that `activate.nixos`
  #                      produced its two wrapper scripts — an upstream
  #                      invariant, not a property of OUR config.
  #
  # Gated on `deploy-rs.lib ? ${system}` for the aarch64-only invariant:
  # deploy-rs exports `lib` for FOUR systems (both darwins + both linuxes) and
  # the README's canonical `mapAttrs … deploy-rs.lib` would therefore create
  # checks.x86_64-linux AND checks.x86_64-darwin, which this flake permits
  # nowhere. Folding over perSystem instead keeps `checks` at exactly the
  # two fleet arches (`systems`, modules/parts/systems.nix); the guard is what
  # makes that safe if upstream ever drops one of them.
  perSystem =
    { system, ... }:
    {
      checks = nixpkgs.lib.optionalAttrs (deploy-rs.lib ? ${system}) {
        inherit (deploy-rs.lib.${system}.deployChecks deploySchemaSubject) deploy-schema;
      };
    };
}
