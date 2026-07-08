{
  description = "Greenfield aarch64 Nix mono-repo: macOS (nix-darwin) client, a Raspberry Pi 4 NixOS server (nixpi), and a UTM/QEMU NixOS sandbox VM (nixvm) — single source of truth across the fleet.";

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

    # Nix -> OpenTofu/Terraform JSON renderer for the Cloudflare-side ZTIA SSH
    # objects (infra/cloudflare/nixpi-ssh.nix). Re-added after being dropped
    # with LiteLLM (#109/greenfield rewrite) — now backs the SSH cutover
    # instead, mirroring the retired cf-litellm-apply/destroy pattern.
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
      userName = "ismail";
      domainName = "kattakath.com";
      fullName = "Ismail Kattakath";
      handleName = "ismailkattakath";

      # ---- Single source of truth for the Cachix binary cache ----------------
      # The public read-only CI cache, consumed by every host. Threaded into the
      # NixOS builder's specialArgs (modules/shared/nix-cache.nix) and into the
      # macOS host's Determinate customSettings — one literal, no duplication.
      cachixUrl = "https://${handleName}.cachix.org";
      cachixKey = "${handleName}.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I=";

      # ---- DRY system mapping -------------------------------------------------
      # A 3-host aarch64-only fleet: no x86_64 anywhere (devcontainer aarch64-only
      # too). Every package / devShell output is generated for both via
      # forAllSystems.
      linuxSystems = [
        "aarch64-linux"
      ];
      darwinSystems = [
        "aarch64-darwin"
      ];
      allSystems = linuxSystems ++ darwinSystems;

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

      # ---- Cloudflare provisioning (terranix -> OpenTofu) ---------------------
      # Renders infra/cloudflare/nixpi-ssh.nix (the ZTIA SSH target/application/
      # policy for nixpi) to a config.tf.json store path, per system. Mirrors the
      # retired cfLitellmConfig/mkCfLitellmTofu pattern byte-for-byte (see
      # `git show main:flake.nix`) — same rendering + wrapper shape, now backing
      # SSH instead of the LiteLLM proxy.
      cfSshConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./infra/cloudflare/nixpi-ssh.nix ];
        };

      # writeShellApplication wrapper around `tofu <action>` for the rendered
      # nixpi ZTIA config. Requires CLOUDFLARE_API_TOKEN in the env (the
      # Cloudflare provider reads it as its api_token). The generated
      # config.tf.json is a read-only store copy, so we `rm -f` any previous copy
      # before re-copying; tofu state then lands beside where you run the app.
      mkCfSshTofu =
        {
          system,
          name,
          action,
        }:
        let
          pkgs = pkgsFor system;
        in
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [ pkgs.opentofu ];
          text = ''
            if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
              echo "ERROR: CLOUDFLARE_API_TOKEN is unset. Export a token with" >&2
              echo "  Account Zero Trust:Edit (Access apps+policies, Infrastructure targets)." >&2
              exit 1
            fi
            rm -f config.tf.json
            cp ${cfSshConfig system} config.tf.json
            tofu init
            tofu ${action}
          '';
        };

      # ---- Cloudflare TUNNEL provisioning (terranix -> OpenTofu) --------------
      # Renders infra/cloudflare/nixpi-tunnel.nix (the remotely-managed tunnel +
      # ingress + proxied CNAME + connector-token output for nixpi) to its own
      # config.tf.json, per system. Separate stack/state from the ZTIA SSH
      # config (cfSshConfig) — the tunnel is provisioned independently of the
      # Access/CA objects layered on top of it.
      cfTunnelConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./infra/cloudflare/nixpi-tunnel.nix ];
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
            echo "Place the line below at /etc/secrets/cloudflared-token on nixpi (root-only, NEVER commit):"
            echo "TUNNEL_TOKEN=$(tofu output -raw nixpi_connector_token)"
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
      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix);

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
              # LINUX BUILDS ON macOS (for `nix run .#nixvm-gui`, `.#nixvm`,
              # `.#nixpi`): use Determinate's NATIVE Linux builder (Apple
              # Virtualization framework — no UTM, no remote builder, no Docker).
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

        # UTM/QEMU HVF sandbox VM (aarch64, Apple Silicon UTM native).
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

        # Minimal installer ISO for nixvm — boot from this on UTM/QEMU,
        # SSH as nixos@nixvm-installer.local, then run the nixvm bootstrap app.
        "nixvm-installer" = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./hosts/nixvm-installer.nix
          ];
        };
      };

      # ---- Packages: container images + VM image -------------------------------
      # `nix build .#packages.aarch64-linux.devcontainerImage` → devcontainer stream script
      # `nix build .#nixvm-image`                              → UTM-importable qcow2 → ./result/
      # One fold merges base (all systems) → single-system, flatter than nesting
      # recursiveUpdate calls.
      packages = nixpkgs.lib.foldl' nixpkgs.lib.recursiveUpdate { } [
        # Devcontainer image is a Linux OCI artifact — gate to the linux triple
        # (aarch64-only in this fleet). Built with unfree pkgs (claude-code) and
        # the SHARED dev toolchain, so `nix develop` inside the container resolves
        # from the baked store.
        (nixpkgs.lib.genAttrs linuxSystems (system: {
          devcontainerImage = (pkgsUnfreeFor system).callPackage ./packages/devcontainer-image.nix {
            devPackages = devPackagesFor system;
            # Identity single-sources (not in pkgs, so callPackage can't autofill):
            # the image's os-release HOME_URL + baked nix.conf Cachix lines reuse
            # these instead of re-hardcoding the handle/cache.
            inherit handleName cachixUrl cachixKey;
          };
        }))

        {
          aarch64-linux.nixvm-image = self.nixosConfigurations.nixvm.config.system.build.images.qemu-efi;
          aarch64-linux.nixvm = (pkgsFor "aarch64-linux").callPackage ./packages/nixvm.nix {
            diskoInstall = disko.packages.aarch64-linux.disko-install;
            inherit handleName;
          };
          aarch64-linux.nixvm-installer-iso =
            self.nixosConfigurations.nixvm-installer.config.system.build.isoImage;
          aarch64-linux.nixpi-installer-image =
            self.nixosConfigurations.nixpi-installer.config.system.build.sdImage;
        }

        # Cloudflare ZTIA-SSH provisioning apps (terranix -> OpenTofu), exposed
        # as packages too so `nix flake check` builds them and runs the
        # writeShellApplication shellcheck on each wrapper. Mirrors the retired
        # cf-litellm-apply/destroy pattern (`git show main:flake.nix`).
        (forAllSystems (system: {
          cf-ssh-apply = mkCfSshTofu {
            inherit system;
            name = "cf-ssh-apply";
            action = "apply";
          };
          cf-ssh-destroy = mkCfSshTofu {
            inherit system;
            name = "cf-ssh-destroy";
            action = "destroy";
          };
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
      # `nix run .#nixvm` (on an aarch64-linux builder, from the live installer
      # ISO) — disko-install bootstrap for the nixvm sandbox VM.
      #
      # `nix run .#nixvm-gui` (on the aarch64-darwin Mac) — build the graphical
      # build-vm variant and boot it in a native QEMU window, no UTM. The runner
      # wrapper itself is darwin (host.pkgs override above); the aarch64-linux
      # guest needs a Linux builder — Determinate's native Linux builder on the
      # Mac (see the macos block above) or the nixvm CI runner / Cachix.
      #
      # `nix run .#cf-ssh-apply` / `.#cf-ssh-destroy` — render
      # infra/cloudflare/nixpi-ssh.nix (terranix) then `tofu init` + apply
      # (destroy for the other) against the Cloudflare account. Token scope:
      # Account Zero Trust:Edit (covers Access apps/policies + Infrastructure
      # targets).
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
              meta.description = "Bootstrap NixOS nixvm on aarch64-linux from the live ISO via disko-install";
            };

            # `nix run .#nixvm-gui` — build the graphical build-vm variant and
            # boot it in a native macOS QEMU window (no UTM). The runner wrapper
            # is a darwin derivation (host.pkgs = aarch64-darwin); the
            # aarch64-linux guest closure needs a Linux builder (Determinate's
            # native Linux builder — see the macos block — or the nixvm CI runner
            # / Cachix). run-nixvm-vm is the qemu-vm.nix script name for "nixvm".
            aarch64-darwin.nixvm-gui = {
              type = "app";
              program = "${self.nixosConfigurations.nixvm.config.system.build.vm}/bin/run-nixvm-vm";
              meta.description = "Boot the nixvm sandbox with an XFCE desktop in a QEMU window (no UTM; needs an aarch64-linux builder)";
            };

            # `nix run github:ismailkattakath/nix-config#macos` — one-line first
            # activation of the macos nix-darwin host straight from the flake: the
            # darwin analog of `nix run .#nixvm` (and of nixpi's
            # `nixos-rebuild switch --flake …#nixpi`). After Determinate Nix is
            # installed but before darwin-rebuild is on PATH, this builds
            # darwin-rebuild from the flake and `switch`es against this SAME
            # revision (${self}); darwin-rebuild self-elevates via sudo/Touch ID.
            # Subsequent rebuilds just use `darwin-rebuild switch --flake .#macos`.
            aarch64-darwin.macos = {
              type = "app";
              program = "${(pkgsFor "aarch64-darwin").writeShellScript "activate-macos" ''
                exec ${self.darwinConfigurations.macos.config.system.build.darwin-rebuild}/bin/darwin-rebuild switch --flake "${self}#macos" "$@"
              ''}";
              meta.description = "First activation of the macos nix-darwin host from the flake (after Determinate Nix)";
            };
          }
          (
            forAllSystems (system: {
              cf-ssh-apply = {
                type = "app";
                program = "${self.packages.${system}.cf-ssh-apply}/bin/cf-ssh-apply";
                meta.description = "Render infra/cloudflare/nixpi-ssh.nix (terranix) and tofu apply it (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-ssh-destroy = {
                type = "app";
                program = "${self.packages.${system}.cf-ssh-destroy}/bin/cf-ssh-destroy";
                meta.description = "tofu destroy the nixpi ZTIA-SSH Cloudflare resources (needs CLOUDFLARE_API_TOKEN)";
              };
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
      devShells = forAllSystems (
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
