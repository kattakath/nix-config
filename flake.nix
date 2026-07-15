{
  description = "Greenfield aarch64 Nix mono-repo: macOS (nix-darwin) client, a Raspberry Pi 4 NixOS server (nixpi), and a headless QEMU/HVF NixOS sandbox VM (nixvm) — single source of truth across the fleet.";

  inputs = {
    # Unstable channel as the single source of truth for every platform.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # macOS system layer (standalone, not NixOS). Follows the parent nixpkgs
    # so we never download a second copy of the package set.
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # User layer, shared by every host.
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Formatting/lint aggregator: one config (./treefmt.nix) drives `nix fmt`,
    # the `checks.formatting` CI gate, and the pre-commit hook. Single source.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Git pre-commit hooks, installed automatically on `nix develop`.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # Declarative disk partitioning for NixOS installs. Replaces the manual
    # parted/mkfs/mount steps with a single `disko --mode disko` command.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Raspberry Pi 4 NixOS support: kernel, firmware, and SD-card image builder.
    raspberry-pi-nix.url = "github:nix-community/raspberry-pi-nix";
    raspberry-pi-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Daily-updated VS Code Marketplace + Open VSX mirror. Lets us pin editor
    # extensions declaratively (programs.vscode). macOS-only consumer — the
    # vscode block in modules/shared/home.nix is gated `mkIf isDarwin`, so the
    # Linux hosts never reference it (and never receive it as a specialArg).
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    # Declaratively INSTALLS Homebrew itself at the arch-correct prefix
    # (/opt/homebrew on Apple Silicon `macos`) — the prefix is auto-selected
    # from the host's stdenv platform. Runs UNDER nix-darwin's built-in
    # `homebrew.*` module, which still owns brews/casks (see
    # modules/darwin/homebrew.nix). No `nixpkgs` input to follow — the module
    # uses the consumer's pkgs.
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    # Nix -> OpenTofu/Terraform JSON renderer for the Cloudflare-side tunnel
    # objects (infra/cloudflare/nixpi-tunnel.nix — the remotely-managed tunnel +
    # ingress + proxied CNAME + connector-token output).
    terranix.url = "github:terranix/terranix";
    terranix.inputs.nixpkgs.follows = "nixpkgs";

    # Determinate Nix — on the `macos` host ONLY, `determinate-nixd` takes over
    # the Nix daemon and owns /etc/nix/nix.conf (nix.enable = false there). The
    # NixOS hosts stay on standard `nix.settings`. Sourced from FlakeHub.
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";

    # agenix — encrypted secrets committed to THIS repo (age, SSH-key based).
    # Each secret in ./secrets/*.age is encrypted to its target host's SSH host
    # key (so the host decrypts at activation with /etc/ssh/ssh_host_ed25519_key)
    # plus the operator's key; recipients are declared in ./secrets/secrets.nix.
    # Pure age/SSH — no ssh-to-age step, no Go build. Follows our nixpkgs.
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # MCP (Model Context Protocol) server packaging for Claude Code. We use its
    # `lib.mkConfig` to render a PINNED {mcpServers:{…}} JSON (the 4 packaged
    # servers become reproducible store-path commands) that our localhost
    # mcp-proxy gateway consumes via --named-server-config. Threaded to
    # modules/shared/mcp.nix (darwin-gated) through extraSpecialArgs — NOT as a
    # home-manager module (the client side uses upstream
    # `programs.claude-code.mcpServers` directly). Follows our nixpkgs so we
    # never pull a second package set.
    mcp-servers-nix.url = "github:natsukium/mcp-servers-nix";
    mcp-servers-nix.inputs.nixpkgs.follows = "nixpkgs";

    # github-nix-ci — declarative self-hosted GitHub Actions runners for NixOS.
    # Used ONLY on nixvm (aarch64-linux): it wraps nixpkgs `services.github-runners`,
    # which needs a nix-daemon-managed Nix — fine on NixOS, but NOT on the macos
    # host (Determinate sets nix.enable = false; that is exactly why
    # modules/darwin/github-runner.nix hand-rolls a launchd runner instead).
    # Module-only flake (no nixpkgs input of its own — it uses the consumer's
    # pkgs), so there is nothing to `follows`.
    github-nix-ci.url = "github:juspay/github-nix-ci";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      home-manager,
      treefmt-nix,
      git-hooks,
      raspberry-pi-nix,
      nix-vscode-extensions,
      nix-homebrew,
      disko,
      terranix,
      determinate,
      agenix,
      mcp-servers-nix,
      github-nix-ci,
      ...
    }:
    let
      # ---- Single source of truth for the human identity ---------------------
      # userName is the POSIX ACCOUNT on every host (users.users.${userName},
      # home-manager.users.${userName}, /Users/ismail on the Mac) — NOT a label.
      # It is deliberately NOT the GitHub handle: renaming it would repoint
      # home-manager at a user that does not exist on the machine.
      userName = "ismailkattakath";
      domainName = "kattakath.com";
      fullName = "Ismail Kattakath";

      # The human's GitHub handle. Since the fleet moved under the `kattakath`
      # org this is NO LONGER the repo owner — it is just the person.
      handleName = "ismailkattakath";

      # Git identity. Its own binding rather than "${userName}@${domainName}",
      # so the commit address can be GitHub's noreply (which never leaks a real
      # mailbox) without dragging the POSIX account name along with it.
      userEmail = "8927166+${handleName}@users.noreply.github.com";

      # ---- Single source of truth for the GitHub owner -----------------------
      # The org that owns the repo, the Cachix cache and the self-hosted runners.
      # Split from handleName so the two can never be confused again: everything
      # that says "who publishes this" is orgName; everything that says "who is
      # the person" is handleName/userName.
      orgName = "kattakath";
      repoName = "nix-config";
      flakeRef = "github:${orgName}/${repoName}";

      # ---- Single source of truth for the Cachix binary cache ----------------
      # The public read-only CI cache, consumed by every host. Threaded into the
      # NixOS builder's specialArgs (modules/shared/nix-cache.nix) and into the
      # macOS host's Determinate customSettings — one literal, no duplication.
      cachixUrl = "https://${orgName}.cachix.org";
      cachixKey = "${orgName}.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw=";

      # ---- Single source of truth for the Cloudflare account/zone ------------
      # Threaded (with domainName) into the cfTunnelConfig terranix stack via
      # `_module.args`, so the account/zone ids and the domain live in ONE place
      # instead of being re-hardcoded. These are IDENTIFIERS, not credentials
      # (safe to commit); the API token stays in the CLOUDFLARE_API_TOKEN env var.
      cloudflareAccountId = "726e0b2aa2bc2c6944f96a042e3c461b";
      cloudflareZoneId = "6e28971881e488941d052bbbf50d69cd"; # the domainName zone

      # ---- DRY system mapping -------------------------------------------------
      # A 3-host aarch64-only FLEET: no x86_64 HOST anywhere. Every package /
      # devShell / check output is generated for the fleet systems via
      # forAllSystems. (The devcontainer IMAGE is the one multi-arch output — it
      # adds x86_64-linux via devcontainerSystems below, for Codespaces; that is a
      # dev tool, not a fleet host, so the invariant holds where it matters.)
      linuxSystems = [
        "aarch64-linux"
      ];
      darwinSystems = [
        "aarch64-darwin"
      ];
      allSystems = linuxSystems ++ darwinSystems;

      # The devcontainer image — and ONLY the image — is multi-arch. The FLEET
      # stays aarch64-only (linuxSystems), but the devcontainer is a dev tool, not
      # a host: GitHub Codespaces is x86_64-only, and an arm64-only image qemu-
      # emulates (which breaks the nix-daemon container), so the image is built for
      # both. Kept OUT of linuxSystems on purpose — adding x86_64 there would spawn
      # x86 devShells/checks/formatter and break the single-arch invariant that the
      # actual hosts rely on.
      devcontainerSystems = linuxSystems ++ [ "x86_64-linux" ];

      # Dev-tooling outputs (devShell + its treefmt eval) must cover every arch a
      # human might DEVELOP on: the fleet arches PLUS the devcontainer's x86_64.
      # `devcontainer.json` runs `nix develop .#default` as its terminal, so a
      # Codespaces user on x86_64 needs devShells.x86_64-linux.default to exist —
      # without it the container's shell errors out (and the CI smoke test does
      # too). This is NOT the fleet: no host/check/config is generated for x86_64,
      # only the dev environment. CI builds .#checks.<system> (aarch64 only), never
      # a full `nix flake check`, so no aarch64 runner tries to build this.
      devToolingSystems = nixpkgs.lib.unique (allSystems ++ devcontainerSystems);

      forAllSystems = f: nixpkgs.lib.genAttrs allSystems f;

      # Per-system nixpkgs accessor (legacyPackages avoids a redundant eval).
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # Unfree-permitting nixpkgs, ONLY for the devcontainer image (claude-code is
      # unfree). legacyPackages has unfree disabled, so the image needs its own
      # instance. Deliberately scoped here — no other output imports it.
      pkgsUnfreeFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      # ---- Cloudflare TUNNEL provisioning (terranix -> OpenTofu) --------------
      # Renders infra/cloudflare/nixpi-tunnel.nix (the remotely-managed tunnel +
      # ingress + proxied CNAME + connector-token output for nixpi) to its own
      # config.tf.json, per system.
      cfTunnelConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          # domainName is the zone name, plus the account/zone ids — threaded from
          # the single flake bindings above (one source of truth, no re-hardcoding).
          modules = [
            ./infra/cloudflare/nixpi-tunnel.nix
            {
              _module.args = {
                inherit domainName;
                accountId = cloudflareAccountId;
                zoneId = cloudflareZoneId;
              };
            }
          ];
        };

      # writeShellApplication wrapper around `tofu <action>` for the rendered
      # nixpi tunnel config. Mirrors mkCfSshTofu (same token guard, same
      # read-only-store-copy handling). On `apply`, it additionally prints the
      # SENSITIVE connector token (a sensitive tofu output) to STDOUT, clearly
      # labeled, so the operator can place it at /etc/secrets/cloudflared-token.
      # The token is NEVER written to git or the /nix/store — only echoed to the
      # operator's terminal, exactly as the retired cf-one-provision.sh did.
      mkCfTunnelTofu =
        {
          system,
          name,
          action,
        }:
        let
          pkgs = pkgsFor system;
          printToken = ''

            echo "----- CONNECTOR TOKEN for nixpi (SECRET) -----"
            echo "TUNNEL_TOKEN=$(tofu output -raw nixpi_connector_token)"
            echo ""
            echo "Store it (from the repo root): pipe the TUNNEL_TOKEN= line above into"
            echo "  nix run .#nixpi-vault-token"
            echo "then plant it on a mounted card with"
            echo "  nix run .#nixpi-provision --token        # (or reflash)"
            echo "----- end nixpi -----"
          '';
        in
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [ pkgs.opentofu ];
          text = ''
            if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
              echo "ERROR: CLOUDFLARE_API_TOKEN is unset. Export a token with" >&2
              echo "  Account Cloudflare Tunnel:Edit + Zone DNS:Edit on kattakath.com." >&2
              exit 1
            fi
            rm -f config.tf.json
            cp ${cfTunnelConfig system} config.tf.json
            tofu init
            tofu ${action}
          ''
          + nixpkgs.lib.optionalString (action == "apply") printToken;
        };

      # ---- Formatting / lint (treefmt-nix) ------------------------------------
      # The wrapper backs `nix fmt`; the `.config.build.check` derivation backs
      # the CI formatting gate.
      # Evaluated for the fleet systems PLUS the devcontainer's extra arch
      # (x86_64-linux): devPackagesFor bakes treefmtEval.<system>.build.wrapper
      # into the image, so the x86_64 image needs an x86_64 treefmt eval. This is
      # a pure eval and feeds nothing else x86 — `checks`/`packages` keep their own
      # forAllSystems (allSystems) fold, so the fleet stays aarch64-only.
      treefmtEval = nixpkgs.lib.genAttrs devToolingSystems (
        system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix
      );

      # ---- Shared dev toolchain -----------------------------------------------
      # Pinned dev tools consumed by BOTH the `nix develop` devShell AND the
      # prebuilt devcontainer image, so the two can never drift.
      # (preCommit.enabledPackages is added on the devShell side only; the image
      # bakes the treefmt wrapper directly.)
      devPackagesFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        [
          pkgs.git
          pkgs.nixd # eval-aware Nix LSP
          home-manager.packages.${system}.default
          treefmtEval.${system}.config.build.wrapper # `treefmt` / `nix fmt`
          # nixfmt as a standalone bin so bare `nixfmt` resolves on PATH for the
          # editor (devcontainer.json's nix.formatterPath + nixd formatting.command
          # both invoke it directly). Sourced from treefmt's own resolved package so
          # it can NEVER drift from the binary the wrapper/CI/pre-commit run.
          treefmtEval.${system}.config.programs.nixfmt.package
          pkgs.statix # anti-pattern linter — .vscode "nix: statix" task
          pkgs.deadnix # dead-code linter — .vscode "nix: deadnix" task
          pkgs.jq # flattens deadnix JSON for the problem matcher
          # agenix secret editing: `agenix -e secrets/<name>.age` (recipients in
          # secrets/secrets.nix). Pure age/SSH — no ssh-to-age needed.
          agenix.packages.${system}.default
        ];

      # ---- Pre-commit hooks (git-hooks.nix) -----------------------------------
      # A single hook runs the treefmt wrapper, so the commit-time tool list can
      # never drift from `nix fmt` / CI — they are literally the same binary.
      preCommitFor =
        system:
        git-hooks.lib.${system}.run {
          src = ./.;
          hooks.treefmt = {
            enable = true;
            package = treefmtEval.${system}.config.build.wrapper;
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
        }:
        nixpkgs.lib.nixosSystem {
          # Set the platform via the MODERN `nixpkgs.hostPlatform` module option
          # (below), NOT nixosSystem's legacy `system` arg — that arg only sets
          # the deprecated `nixpkgs.system`, leaving `nixpkgs.hostPlatform`
          # undefined. Modules such as github-nix-ci read
          # `config.nixpkgs.hostPlatform.system` and would otherwise fail with
          # "option `nixpkgs.hostPlatform' was accessed but has no value". The two
          # cannot both be set (nixpkgs forbids it), so we drop the arg entirely.
          specialArgs = {
            inherit
              userName
              domainName
              fullName
              handleName
              orgName
              userEmail
              # Public Cachix substituter URL + trusted-PUBLIC-key (verification
              # key, safe to expose — NOT a secret/token). Consumed by
              # modules/shared/nix-cache.nix.
              cachixUrl
              cachixKey
              ;
          };
          modules = [
            { nixpkgs.hostPlatform = system; }
            ./hosts/${hostname}.nix
            ./modules/nixos/core.nix
            ./modules/shared/nix-cache.nix # Cachix binary cache (read)
            agenix.nixosModules.default # encrypted in-repo secrets (./secrets/*.age)
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit
                    userName
                    domainName
                    fullName
                    handleName
                    orgName
                    userEmail
                    mcp-servers-nix
                    ;
                };
                users.${userName} = {
                  imports = [
                    ./modules/shared/home.nix
                  ];
                  home.stateVersion = "24.05";
                };
              };
            }
          ]
          ++ extraModules;
        };

      # ---- nix-darwin system builder ------------------------------------------
      # Mirrors mkNixos for the Mac. hostPlatform is driven from `system` (NOT
      # hardcoded in modules/darwin/core.nix) even though this fleet has a single
      # darwin host today.
      mkDarwin =
        {
          system,
          hostname,
          extraModules ? [ ],
        }:
        nix-darwin.lib.darwinSystem {
          inherit system;
          specialArgs = {
            inherit
              userName
              domainName
              fullName
              handleName
              # orgName feeds modules/darwin/github-runner.nix, which registers
              # the runner at github.com/${orgName} (org-level, not per-repo).
              orgName
              userEmail
              ;
          };
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
              # LINUX BUILDS ON macOS (for `nix run .#nixvm-gui`, `.#nixpi`):
              # use Determinate's NATIVE Linux builder (Apple Virtualization
              # framework — no remote builder, no Docker).
              # NOTE: installing `nixvm` itself does NOT need any of this —
              # nixos-anywhere runs with `--build-on remote`, so the guest
              # builds its own closure and the Mac never needs a Linux builder.
              # It is NOT configured from Nix: `external-builders` is a reserved
              # setting that Determinate manages and `determinateNix.customSettings`
              # rejects it (asserts at eval). It is a FlakeHub/account-level
              # feature — enable it via https://dtr.mn/features and verify with
              # `determinate-nixd version` (look for `native-linux-builder`; today
              # this host shows only `lazy-trees`). nix-darwin's
              # `nix.linux-builder` is unusable here — it requires
              # `nix.enable = true`, which Determinate turns off (nix-darwin#1505).
              # Until the native builder is enabled, build the aarch64-linux guest
              # on the `nixvm` CI runner (remote builder) or pull from Cachix.
            }
            nix-homebrew.darwinModules.nix-homebrew # declaratively install brew (arch-correct prefix)
            agenix.darwinModules.default # encrypted in-repo secrets (./secrets/*.age)
            ./hosts/${hostname}.nix
            home-manager.darwinModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit
                    userName
                    domainName
                    fullName
                    handleName
                    orgName
                    userEmail
                    mcp-servers-nix
                    ;
                };
                users.${userName} = {
                  imports = [ ./modules/shared/home.nix ];
                  home.stateVersion = "24.05";
                };
              };
            }
          ]
          ++ extraModules;
        };
    in
    {
      # ---- macOS system configurations ---------------------------------------
      # Built with `darwin-rebuild switch --flake .#macos`.
      darwinConfigurations = {
        # Apple Silicon Mac (aarch64-darwin), client only — no incoming traffic.
        "macos" = mkDarwin {
          system = "aarch64-darwin";
          hostname = "macos";
        };
      };

      # ---- NixOS system configurations -------------------------------------------
      # Built with `nixos-rebuild switch --flake .#<hostname>`.
      # SD card image for the Pi: nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
      nixosConfigurations = {
        # Raspberry Pi 4 — LIVE server (kattakath.com static landing page).
        "nixpi" = mkNixos {
          system = "aarch64-linux";
          hostname = "nixpi";
          extraModules = [
            raspberry-pi-nix.nixosModules.raspberry-pi
            raspberry-pi-nix.nixosModules.sd-image
          ];
        };

        # Headless QEMU/HVF sandbox VM (aarch64), run as a plain qemu-system-aarch64
        # process on the Mac and kept alive by a launchd daemon
        # (modules/darwin/nixvm-qemu.nix). NOT a UTM VM any more: UTM was dropped
        # after a Mac reset proved it is not CLI-provisionable (utmctl never sees a
        # hand-authored bundle, and the osascript fallback is blocked by TCC, error
        # -1728 — a permission that cannot be granted programmatically).
        # Installed with nixos-anywhere against the ISO-booted VM; see
        # docs/nixvm-qemu-runbook.md.
        "nixvm" = mkNixos {
          system = "aarch64-linux";
          hostname = "nixvm";
          extraModules = [
            disko.nixosModules.disko
            # Self-hosted GitHub Actions runner (aarch64-linux) — the NixOS-native
            # counterpart to the macOS host's hand-rolled launchd runner. Config +
            # agenix token live in hosts/nixvm.nix (gated on the token existing).
            github-nix-ci.nixosModules.default
            # Graphical `build-vm` variant runs on the aarch64-darwin Mac, so its
            # QEMU runner must be macOS-native. host.pkgs is the pkgs whose qemu
            # the generated run-nixvm-vm executes — point it at aarch64-darwin.
            # LAZY: only the `system.build.vm` path forces this, so the
            # aarch64-linux toplevel eval (CI) never pulls in darwin pkgs. The
            # rest of the variant (graphics, desktop) lives in hosts/nixvm.nix.
            { virtualisation.vmVariant.virtualisation.host.pkgs = nixpkgs.legacyPackages."aarch64-darwin"; }
          ];
        };

        # Minimal installer SD image for nixpi — flash to SD card, boot,
        # SSH as nixos@nixpi-installer.local, then run the nixpi bootstrap.
        "nixpi-installer" = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            raspberry-pi-nix.nixosModules.raspberry-pi
            raspberry-pi-nix.nixosModules.sd-image
            ./hosts/nixpi-installer.nix
          ];
        };

        # Minimal installer ISO for nixvm. Boot the (otherwise empty) QEMU VM from
        # this ISO; it is the SSH-reachable Linux that nixos-anywhere installs
        # *through*. Still load-bearing — a blank qcow2 has nothing to kexec from,
        # so the ISO is the entry point for every (re)install of nixvm.
        "nixvm-installer" = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./hosts/nixvm-installer.nix
          ];
        };
      };

      # ---- Packages: container images + installer images ------------------------
      # `nix build .#packages.aarch64-linux.devcontainerImage` → devcontainer stream script
      # `nix build .#nixvm-installer-iso`                      → nixvm installer ISO → ./result/
      # One fold merges base (all systems) → single-system, flatter than nesting
      # recursiveUpdate calls.
      #
      # REMOVED: `nixvm-image` (= nixosConfigurations.nixvm.…build.images.qemu-efi,
      # a prebuilt qcow2). It existed only to be imported into UTM, and UTM is gone
      # — nixvm is now installed by nixos-anywhere onto a blank `qemu-img create`
      # disk. It was also unbuildable ANYWHERE in this fleet: make-disk-image is
      # requiredSystemFeatures = ["kvm"], macOS has no /dev/kvm, Docker Desktop does
      # not expose one (verified on M3 Pro), and there is no other Linux builder. It
      # is not coming back; do not re-add it "for convenience".
      packages = nixpkgs.lib.foldl' nixpkgs.lib.recursiveUpdate { } [
        # Devcontainer image is a Linux OCI artifact — gate to the linux triple
        # (aarch64-only in this fleet). Built with unfree pkgs (claude-code) and
        # the SHARED dev toolchain, so `nix develop` inside the container resolves
        # from the baked store.
        (nixpkgs.lib.genAttrs devcontainerSystems (system: {
          devcontainerImage = (pkgsUnfreeFor system).callPackage ./packages/devcontainer-image.nix {
            devPackages = devPackagesFor system;
            # Identity single-sources (not in pkgs, so callPackage can't autofill):
            # the image's os-release HOME_URL + baked nix.conf Cachix lines reuse
            # these instead of re-hardcoding the handle/cache.
            inherit orgName cachixUrl cachixKey;
          };
        }))

        # Key-recovery kit (macOS only). Exposed as packages so `nix flake check`
        # BUILDS them — which is what runs writeShellApplication's shellcheck on
        # key-backup/key-recover and the explicit shellcheck on the no-Nix
        # bootstrap script. Before this, the recovery scripts lived as loose bash
        # in an iCloud folder that nothing linted and nothing evaluated.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            kit = (pkgsFor system).callPackage ./packages/key-recovery.nix {
              # The PINNED agenix, not `nix run github:ryantm/agenix` at runtime:
              # a recovery must not depend on whatever agenix master is that day.
              agenix = agenix.packages.${system}.default;
              inherit orgName;
              inherit flakeRef;
            };
          in
          {
            inherit (kit) key-backup key-recover key-recovery-bootstrap;
          }
        ))

        # nixpi SD-card provisioning toolkit (macOS only). Exposed as packages so
        # `nix flake check` BUILDS them — running writeShellApplication's shellcheck
        # on each of the four apps. See packages/nixpi-provision.nix.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            kit = (pkgsFor system).callPackage ./packages/nixpi-provision.nix { };
          in
          {
            nixpi-wifi-creds = kit.wifi-creds;
            nixpi-provision = kit.provision;
            nixpi-flash = kit.flash;
            nixpi-vault-token = kit.vault-token;
          }
        ))

        {
          # BREAK-GLASS ONLY (see the apps block): superseded by nixos-anywhere.
          aarch64-linux.nixvm = (pkgsFor "aarch64-linux").callPackage ./packages/nixvm.nix {
            diskoInstall = disko.packages.aarch64-linux.disko-install;
            inherit orgName;
          };
          aarch64-linux.nixvm-installer-iso =
            self.nixosConfigurations.nixvm-installer.config.system.build.isoImage;
          aarch64-linux.nixpi-installer-image =
            self.nixosConfigurations.nixpi-installer.config.system.build.sdImage;
        }

        # Cloudflare tunnel provisioning apps (terranix -> OpenTofu), exposed as
        # packages too so `nix flake check` builds them and runs the
        # writeShellApplication shellcheck on each wrapper.
        (forAllSystems (system: {
          cf-tunnel-apply = mkCfTunnelTofu {
            inherit system;
            name = "cf-tunnel-apply";
            action = "apply";
          };
          cf-tunnel-destroy = mkCfTunnelTofu {
            inherit system;
            name = "cf-tunnel-destroy";
            action = "destroy";
          };
        }))
      ];

      # ---- Apps: bootstrap installer + Cloudflare provisioning ---------------
      # `nix run .#nixvm` — BREAK-GLASS ONLY. Ran from *inside* the live installer
      # ISO, it disko-installs nixvm onto /dev/vda. The SUPPORTED install path is
      # now nixos-anywhere, driven from the Mac against the ISO-booted VM:
      #   nix run github:nix-community/nixos-anywhere -- --flake .#nixvm \
      #     --build-on remote --extra-files <dir> --target-host root@localhost --ssh-port 2222
      # `--build-on remote` is why no Linux builder is needed on the Mac, and
      # `--extra-files` is what plants the PRE-GENERATED SSH host key so agenix can
      # decrypt gh-runner-token-nixvm.age on FIRST boot. This app does neither, so
      # a VM installed with it comes up with a self-generated host key and the CI
      # runner silently never registers. See docs/nixvm-qemu-runbook.md.
      #
      # `nix run .#nixvm-gui` (on the aarch64-darwin Mac) — build the graphical
      # build-vm variant and boot it in a native QEMU window. Unrelated to the
      # installed VM: it boots a THROWAWAY overlay, not ~/nixvm/disk.qcow2. The
      # runner wrapper itself is darwin (host.pkgs override above); the
      # aarch64-linux guest needs a Linux builder — Determinate's native Linux
      # builder on the Mac (see the macos block above) or the nixvm CI runner /
      # Cachix.
      #
      # `nix run .#cf-tunnel-apply` / `.#cf-tunnel-destroy` — render
      # infra/cloudflare/nixpi-tunnel.nix (terranix) then `tofu init` + apply
      # (destroy). Provisions nixpi's remotely-managed tunnel + ingress +
      # proxied CNAME; cf-tunnel-apply additionally PRINTS the connector token
      # for manual placement at /etc/secrets/cloudflared-token (never written to
      # git/store). This replaces the retired scripts/cf-one-provision.sh. Token
      # scope: Account Cloudflare Tunnel:Edit + Zone DNS:Edit on kattakath.com.
      #
      # All need a live token in the environment, e.g.
      #   CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-tunnel-apply
      # Merged with recursiveUpdate so the static nixvm entry and the
      # forAllSystems cf-* apps coexist under one `apps` attribute (a bare
      # `apps.x.y = …` alongside `apps = …` is a duplicate-definition error).
      apps =
        nixpkgs.lib.recursiveUpdate
          {
            aarch64-linux.nixvm = {
              type = "app";
              program = "${self.packages.aarch64-linux.nixvm}/bin/nixvm";
              meta.description = "BREAK-GLASS: disko-install nixvm from inside the live ISO (no host-key planting — prefer nixos-anywhere)";
            };

            # `nix run .#nixvm-gui` — build the graphical build-vm variant and
            # boot it in a native macOS QEMU window. The runner wrapper is a
            # darwin derivation (host.pkgs = aarch64-darwin); the aarch64-linux
            # guest closure needs a Linux builder (Determinate's native Linux
            # builder — see the macos block — or the nixvm CI runner / Cachix).
            # run-nixvm-vm is the qemu-vm.nix script name for "nixvm".
            aarch64-darwin.nixvm-gui = {
              type = "app";
              program = "${self.nixosConfigurations.nixvm.config.system.build.vm}/bin/run-nixvm-vm";
              meta.description = "Boot a THROWAWAY nixvm with an XFCE desktop in a QEMU window (not the installed disk; needs an aarch64-linux builder)";
            };

            # `nix run github:kattakath/nix-config#macos` — one-line first
            # activation of the macos nix-darwin host straight from the flake: the
            # darwin analog of `nix run .#nixvm` (and of nixpi's
            # `nixos-rebuild switch --flake …#nixpi`). After Determinate Nix is
            # installed but before darwin-rebuild is on PATH, this builds
            # darwin-rebuild from the flake and `switch`es against this SAME
            # revision (${self}); darwin-rebuild self-elevates via sudo/Touch ID.
            # Subsequent rebuilds just use `darwin-rebuild switch --flake .#macos`.
            # `nix run .#key-backup` — on a HEALTHY Mac, before you wipe it:
            # publishes the passphrase-encrypted operator key + the bootstrap
            # script + a (non-secret) fingerprint manifest into iCloud.
            aarch64-darwin.key-backup = {
              type = "app";
              program = "${self.packages.aarch64-darwin.key-backup}/bin/key-backup";
              meta.description = "Publish the encrypted key-recovery kit to iCloud (run BEFORE resetting this Mac)";
            };

            # `nix run .#key-recover` — stage 2 of recovery. bootstrap.sh execs
            # this once Determinate Nix exists: decrypt the operator key, clone,
            # re-key agenix to the new host key, activate. Stage 1 (the stale-Nix
            # preflight + the installer itself) cannot run under Nix and lives in
            # packages/key-recovery/bootstrap.sh.
            aarch64-darwin.key-recover = {
              type = "app";
              program = "${self.packages.aarch64-darwin.key-recover}/bin/key-recover";
              meta.description = "Restore the operator SSH key, re-key agenix to this Mac's host key, and activate";
            };

            aarch64-darwin.macos = {
              type = "app";
              program = "${(pkgsFor "aarch64-darwin").writeShellScript "activate-macos" ''
                exec ${self.darwinConfigurations.macos.config.system.build.darwin-rebuild}/bin/darwin-rebuild switch --flake "${self}#macos" "$@"
              ''}";
              meta.description = "First activation of the macos nix-darwin host from the flake (after Determinate Nix)";
            };

            # nixpi SD-card provisioning (macOS). The executable runbook: build +
            # verified dd + plant token/wifi (nixpi-flash), plant onto a mounted card
            # (nixpi-provision), emit a wpa_supplicant.conf from this Mac's Wi-Fi
            # (nixpi-wifi-creds), and re-encrypt a rotated token into the vault
            # (nixpi-vault-token). See packages/nixpi-provision.nix + the flashing runbook.
            aarch64-darwin.nixpi-flash = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-flash}/bin/nixpi-flash";
              meta.description = "Fresh reflash: build (or --image) → verified dd → auto-plant token+wifi (--disk /dev/diskN)";
            };
            aarch64-darwin.nixpi-provision = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-provision}/bin/nixpi-provision";
              meta.description = "Plant the connector token and/or wpa_supplicant.conf onto a mounted nixpi FIRMWARE partition (--all|--token|--wifi)";
            };
            aarch64-darwin.nixpi-wifi-creds = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-wifi-creds}/bin/nixpi-wifi-creds";
              meta.description = "Emit a wpa_supplicant.conf from this Mac's current Wi-Fi network (SSID + keychain PSK + locale country)";
            };
            aarch64-darwin.nixpi-vault-token = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-vault-token}/bin/nixpi-vault-token";
              meta.description = "Re-encrypt a new connector token (stdin/$TUNNEL_TOKEN) into secrets/cloudflared-token.age (run from the repo root)";
            };
          }
          (
            forAllSystems (system: {
              cf-tunnel-apply = {
                type = "app";
                program = "${self.packages.${system}.cf-tunnel-apply}/bin/cf-tunnel-apply";
                meta.description = "Render infra/cloudflare/nixpi-tunnel.nix (terranix), tofu apply it, and print the connector token (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-tunnel-destroy = {
                type = "app";
                program = "${self.packages.${system}.cf-tunnel-destroy}/bin/cf-tunnel-destroy";
                meta.description = "tofu destroy the nixpi Cloudflare tunnel/ingress/CNAME (needs CLOUDFLARE_API_TOKEN)";
              };
            })
          );

      # ---- Multi-architecture dev shell --------------------------------------
      # `nix develop` on any target. Used as the default Devcontainer profile.
      # statix/deadnix/jq are exposed as standalone binaries (NOT via
      # preCommit.enabledPackages, which only yields the treefmt wrapper) so the
      # .vscode lint tasks can call them directly.
      # devToolingSystems (fleet + x86_64), NOT forAllSystems: the x86_64
      # devcontainer's terminal runs `nix develop .#default`, so that arch needs a
      # devShell output or the container shell errors. See devToolingSystems above.
      devShells = nixpkgs.lib.genAttrs devToolingSystems (
        system:
        let
          pkgs = pkgsFor system;
          preCommit = preCommitFor system;
        in
        {
          default = pkgs.mkShell {
            # Shared with the devcontainer image (devPackagesFor) so the pinned
            # nixd/treefmt/statix/deadnix/jq/home-manager set never drifts.
            packages = devPackagesFor system ++ preCommit.enabledPackages;

            # We deliberately DO NOT run git-hooks.nix's installer
            # (${preCommit.shellHook}). That installer would symlink
            # .pre-commit-config.yaml, run `git config core.hooksPath`, and write
            # .git/hooks/pre-commit with a /nix/store bash shebang. But `.git/` is
            # bind-mounted and shared between this Nix devcontainer and the Nix-less
            # macOS host (see .devcontainer/devcontainer.json workspaceMount): a
            # store-path hook installed here makes host-side `git commit` fail with
            # `fatal: cannot exec` — the kernel cannot resolve the /nix/store
            # interpreter off-Nix. A single hook file cannot be correct in both a Nix
            # and a non-Nix environment, so we skip local install entirely. The
            # `checks.pre-commit` CI gate + `nix fmt` run the same treefmt pass, so no
            # coverage is lost; run `nix fmt` before committing.
            shellHook = ''
              echo "nix-config devShell ready on ${system} — run 'nix fmt' before committing (pre-commit auto-install disabled: .git is shared with a Nix-less host; CI enforces the gate)"
            '';
          };
        }
      );

      # ---- Formatter: `nix fmt` runs treefmt (nixfmt + statix + deadnix) ------
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # ---- Checks: `nix flake check` enforces formatting + lint + hooks ------
      # Lint/format only, to keep merge CI fast. The host toplevels are
      # deliberately NOT checks: BUILDING them (esp. the cold Pi kernel, ~1h) is
      # a RELEASE-time concern. Merge CI instead EVALUATES the host configs
      # (cheap, catches config/eval errors) without building — see
      # .github/workflows/nix-ci.yml.
      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
        pre-commit = preCommitFor system;
      });
    };
}
