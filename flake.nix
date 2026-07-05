{
  description = "All-in-one Nix mono-repo: NixOS VMs + Raspberry Pi 4, macOS (nix-darwin), Home Manager for Linux/macOS/containers, and minimal Docker images — single source of truth across all hosts.";

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

    # Nix → OpenTofu/Terraform JSON. Renders infra/cloudflare/*.nix to a
    # config.tf.json consumed by the cf-litellm-apply/destroy apps (OpenTofu +
    # the Cloudflare provider). Pure-eval lib; follows the parent nixpkgs so it
    # never pulls a second copy.
    terranix.url = "github:terranix/terranix";
    terranix.inputs.nixpkgs.follows = "nixpkgs";

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
    # (/opt/homebrew on Apple Silicon `nixcon`, /usr/local on Intel `nixtel`) —
    # the prefix is auto-selected from the host's stdenv platform. Runs UNDER
    # nix-darwin's built-in `homebrew.*` module, which still owns brews/casks
    # (see modules/darwin/homebrew.nix). No `nixpkgs` input to follow — the
    # module uses the consumer's pkgs.
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      home-manager,
      treefmt-nix,
      git-hooks,
      terranix,
      raspberry-pi-nix,
      nix-vscode-extensions,
      nix-homebrew,
      disko,
      ...
    }:
    let
      # ---- Single source of truth for the human identity ---------------------
      userName = "ismail";
      domainName = "kattakath.com";
      fullName = "Ismail Kattakath";
      handleName = "ismailkattakath";

      # ---- DRY system mapping -------------------------------------------------
      # The four architectures this repo targets. Every package / devShell
      # output is generated for all of them via forAllSystems.
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
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

      # ---- Cloudflare provisioning (terranix → OpenTofu) ----------------------
      # Renders infra/cloudflare/litellm.nix to a config.tf.json store path, per
      # system. The cf-litellm-apply/destroy wrappers `cp` it into the CWD and run
      # `tofu init` + apply/destroy against the Cloudflare account.
      cfLitellmConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./infra/cloudflare/litellm.nix ];
        };

      # writeShellApplication wrapper around `tofu <action>` for the rendered
      # LiteLLM Cloudflare config. Requires CLOUDFLARE_API_TOKEN in the env (the
      # Cloudflare provider reads it as its api_token). The generated
      # config.tf.json is a read-only store copy, so we `rm -f` any previous copy
      # before re-copying; tofu state then lands beside where you run the app.
      mkCfLitellmTofu =
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
              echo "  Account Cloudflare Tunnel:Edit, Zone DNS:Edit," >&2
              echo "  Account Access Apps+Policies:Edit, Account Access Service Tokens:Edit." >&2
              exit 1
            fi
            rm -f config.tf.json
            cp ${cfLitellmConfig system} config.tf.json
            tofu init
            tofu ${action}
          '';
        };

      # Landing-page Cloudflare provisioning — parallels the LiteLLM helpers above
      # but renders infra/cloudflare/landing.nix: a dedicated PUBLIC tunnel (no
      # Access). Same CLOUDFLARE_API_TOKEN requirement + read-only-store-copy dance.
      cfLandingConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./infra/cloudflare/landing.nix ];
        };

      mkCfLandingTofu =
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
              echo "  Account Cloudflare Tunnel:Edit and Zone DNS:Edit on kattakath.com." >&2
              exit 1
            fi
            rm -f config.tf.json
            cp ${cfLandingConfig system} config.tf.json
            tofu init
            tofu ${action}
          '';
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

      # ---- NixOS system builder ---------------------------------------------------
      # Full NixOS system with Home Manager embedded, using the same shared user
      # profile as the darwin hosts.
      mkNixos =
        {
          system,
          hostname,
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
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
            ./hosts/${hostname}.nix
            ./modules/nixos/core.nix
            ./modules/shared/nix-cache.nix # Cachix binary cache (read)
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
      # Mirrors mkNixos for macOS hosts. hostPlatform is driven from `system`
      # (NOT hardcoded in modules/darwin/core.nix), so one shared darwin module
      # set serves both the aarch64-darwin (nixcon) and x86_64-darwin (nixtel) Macs.
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
              home-manager
              userName
              domainName
              fullName
              handleName
              nix-vscode-extensions
              ;
          };
          modules = [
            { nixpkgs.hostPlatform = system; }
            nix-homebrew.darwinModules.nix-homebrew # declaratively install brew (arch-correct prefix)
            ./hosts/${hostname}.nix
            ./modules/shared/nix-cache.nix # Cachix binary cache (read)
          ]
          ++ extraModules;
        };
    in
    {
      # ---- macOS system configurations ---------------------------------------
      # Built with `darwin-rebuild switch --flake .#<hostname>`.
      darwinConfigurations = {
        # Apple Silicon Mac (aarch64-darwin).
        "nixcon" = mkDarwin {
          system = "aarch64-darwin";
          hostname = "nixcon";
        };

        # Intel Mac (x86_64-darwin) — a real Apple Intel Mac. Homebrew installs
        # to /usr/local automatically (nix-homebrew keys the prefix off the host
        # platform); Touch ID is gated off in modules/darwin/core.nix (no sensor).
        "nixtel" = mkDarwin {
          system = "x86_64-darwin";
          hostname = "nixtel";
        };
      };

      # ---- NixOS system configurations -------------------------------------------
      # Built with `nixos-rebuild switch --flake .#<hostname>`.
      # SD card image for RPi: nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
      nixosConfigurations = {
        "nixrpi" = mkNixos {
          system = "aarch64-linux";
          hostname = "nixrpi";
          extraModules = [
            raspberry-pi-nix.nixosModules.raspberry-pi
            raspberry-pi-nix.nixosModules.sd-image
          ];
        };

        # Generic NixOS VM (UTM `virt` / UEFI) — aarch64 (Apple Silicon UTM native).
        "nixarm" = mkNixos {
          system = "aarch64-linux";
          hostname = "nixarm";
          extraModules = [
            disko.nixosModules.disko
          ];
        };

        # Generic NixOS host — x86_64 (config-only / CI-eval; no VM launcher,
        # since x86_64 on Apple Silicon runs under slow TCG). No cloudflared /
        # agenix secret yet (no provisioned host key) — adding a tunnel is a
        # follow-up once a host key exists.
        "nixamd" = mkNixos {
          system = "x86_64-linux";
          hostname = "nixamd";
          extraModules = [
            disko.nixosModules.disko
          ];
        };

        # Minimal installer ISO for nixarm — boot from this on UTM/QEMU,
        # SSH as nixos@nixarm-installer.local, then run the nixarm bootstrap app.
        "nixarm-installer" = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./hosts/nixarm-installer.nix
          ];
        };

        # Minimal installer ISO for nixamd — boot from this, SSH as
        # nixos@nixamd-installer.local, then run the nixamd bootstrap app.
        "nixamd-installer" = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./hosts/nixamd-installer.nix
          ];
        };

        # Minimal installer SD image for nixrpi — flash to SD card, boot,
        # SSH as nixos@nixrpi-installer.local, then switch to the nixrpi config.
        "nixrpi-installer" = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            raspberry-pi-nix.nixosModules.raspberry-pi
            raspberry-pi-nix.nixosModules.sd-image
            ./hosts/nixrpi-installer.nix
          ];
        };
      };

      # ---- Packages: container images + VM image -------------------------------
      # `nix build .#packages.<system>.dockerImage`        → minimal runtime tarball
      # `nix build .#packages.<linux>.devcontainerImage`   → devcontainer stream script (Linux only)
      # `nix build .#packages.<linux>.litellmImage`        → LiteLLM proxy OCI image (Linux only)
      # `nix build .#packages.<linux>.inkmcpImage`         → inkmcp container stream script (Linux only)
      # `nix build .#nixarm-image`                         → UTM-importable qcow2 → ./result/
      # One fold merges base (all systems) → devcontainer (linux) → single-system,
      # flatter than nesting recursiveUpdate calls.
      packages = nixpkgs.lib.foldl' nixpkgs.lib.recursiveUpdate { } [
        # Base: minimal runtime container image, per system.
        (forAllSystems (system: {
          dockerImage = (pkgsFor system).callPackage ./packages/docker-image.nix { };
        }))

        # Nix-rendered docker-compose for the LiteLLM proxy + cloudflared
        # connector (packages/litellm-compose.nix, pkgs.formats.yaml). Plain
        # arch-agnostic text, so expose it for every system.
        #   nix build .#packages.<system>.litellmCompose
        (forAllSystems (system: {
          litellmCompose = (pkgsFor system).callPackage ./packages/litellm-compose.nix { };
        }))

        # Cloudflare provisioning apps (terranix → OpenTofu). Exposed as packages
        # too — like nixarm/nixamd — so `nix flake check` builds them and runs the
        # writeShellApplication shellcheck on each wrapper.
        (forAllSystems (system: {
          cf-litellm-apply = mkCfLitellmTofu {
            inherit system;
            name = "cf-litellm-apply";
            action = "apply";
          };
          cf-litellm-destroy = mkCfLitellmTofu {
            inherit system;
            name = "cf-litellm-destroy";
            action = "destroy";
          };
        }))

        # The public landing page — a content-pinned static asset copy, so it
        # builds on every system.  nix build .#landing
        (forAllSystems (system: {
          landing = (pkgsFor system).callPackage ./packages/landing.nix { };
        }))

        # Landing-page Cloudflare provisioning apps (parallels cf-litellm-* above).
        (forAllSystems (system: {
          cf-landing-apply = mkCfLandingTofu {
            inherit system;
            name = "cf-landing-apply";
            action = "apply";
          };
          cf-landing-destroy = mkCfLandingTofu {
            inherit system;
            name = "cf-landing-destroy";
            action = "destroy";
          };
        }))

        # Devcontainer image is a Linux OCI artifact — gate to the linux triple.
        # Built with unfree pkgs (claude-code) and the SHARED dev toolchain, so
        # `nix develop` inside the container resolves from the baked store.
        (nixpkgs.lib.genAttrs linuxSystems (system: {
          devcontainerImage = (pkgsUnfreeFor system).callPackage ./packages/devcontainer-image.nix {
            devPackages = devPackagesFor system;
          };
        }))

        # LiteLLM proxy image is an OCI (Linux) artifact — gate to the linux
        # triple like devcontainerImage; OCI images never target darwin.
        (nixpkgs.lib.genAttrs linuxSystems (system: {
          litellmImage = (pkgsFor system).callPackage ./packages/litellm-image.nix { };
        }))

        # inkmcp container image is a Linux OCI artifact — gate to the linux
        # triple. FREE deps only, so it uses pkgsFor (mirrors dockerImage), not
        # the unfree devcontainer fold. streamLayeredImage/enableFakechroot are
        # Darwin-forbidden, so this genAttrs linuxSystems is the required gate.
        (nixpkgs.lib.genAttrs linuxSystems (system: {
          inkmcpImage = (pkgsFor system).callPackage ./packages/inkmcp-image.nix { };
        }))

        {
          aarch64-linux.nixarm-image = self.nixosConfigurations.nixarm.config.system.build.images.qemu-efi;
          # Exposed as packages (not just wrapped in apps) so CI can build them —
          # that build is what runs the writeShellApplication shellcheck on each script.
          aarch64-darwin.nixarm-vm = (pkgsFor "aarch64-darwin").callPackage ./packages/nixarm-vm.nix { };
          aarch64-linux.nixarm = (pkgsFor "aarch64-linux").callPackage ./packages/nixarm.nix {
            diskoInstall = disko.packages.aarch64-linux.disko-install;
            inherit handleName;
          };
          x86_64-linux.nixamd = (pkgsFor "x86_64-linux").callPackage ./packages/nixamd.nix {
            diskoInstall = disko.packages.x86_64-linux.disko-install;
            inherit handleName;
          };
          aarch64-linux.nixarm-installer-iso =
            self.nixosConfigurations.nixarm-installer.config.system.build.isoImage;
          x86_64-linux.nixamd-installer-iso =
            self.nixosConfigurations.nixamd-installer.config.system.build.isoImage;
          aarch64-linux.nixrpi-installer-image =
            self.nixosConfigurations.nixrpi-installer.config.system.build.sdImage;
        }
      ];

      # ---- Apps: native VM launcher (macOS only) -----------------------------
      # `nix run .#nixarm-vm` — boots the nixarm qcow2 in QEMU with Apple HVF
      # acceleration. No UTM required. User-mode networking with hostfwd 2222→22
      # for direct SSH before the Cloudflare tunnel is active.
      #
      # Prerequisites:
      #   1. Build qcow2 on an aarch64-linux builder: nix build .#nixarm-image
      #   2. Copy to the default disk path (or set NIXARM_DISK=/path/to/qcow2):
      #        cp result/*.qcow2 ~/.local/state/nixarm-vm/nixarm.qcow2
      # The per-system nixarm/nixamd launchers plus the terranix cf-litellm apps.
      # Merged with recursiveUpdate so the static single-system entries and the
      # forAllSystems cf apps coexist under one `apps` attribute (a bare
      # `apps.x.y = …` alongside `apps = …` is a duplicate-definition error).
      #
      # cf-litellm-apply/destroy — `nix run .#cf-litellm-apply`:
      #   render infra/cloudflare/litellm.nix (terranix) then `tofu init` + apply
      #   (destroy for the other). Both need a live token in the environment:
      #     CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-litellm-apply
      #   Token scopes: Account Cloudflare Tunnel:Edit, Zone DNS:Edit,
      #     Account Access Apps+Policies:Edit, Account Access Service Tokens:Edit.
      #   Exposed on all four systems (aarch64-darwin for the user's Mac + the
      #   linux triple), matching the packages fold that builds the wrappers.
      apps =
        nixpkgs.lib.recursiveUpdate
          {
            aarch64-darwin.nixarm-vm = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixarm-vm}/bin/run-nixarm-vm";
              meta.description = "Boot nixarm qcow2 in QEMU with Apple HVF — no UTM needed (aarch64-darwin only)";
            };
            aarch64-linux.nixarm = {
              type = "app";
              program = "${self.packages.aarch64-linux.nixarm}/bin/nixarm";
              meta.description = "Bootstrap NixOS nixarm on aarch64-linux from the live ISO via disko-install";
            };
            x86_64-linux.nixamd = {
              type = "app";
              program = "${self.packages.x86_64-linux.nixamd}/bin/nixamd";
              meta.description = "Bootstrap NixOS nixamd on x86_64-linux from the live ISO via disko-install";
            };
          }
          (
            forAllSystems (system: {
              cf-litellm-apply = {
                type = "app";
                program = "${self.packages.${system}.cf-litellm-apply}/bin/cf-litellm-apply";
                meta.description = "Render infra/cloudflare/litellm.nix (terranix) and tofu apply it (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-litellm-destroy = {
                type = "app";
                program = "${self.packages.${system}.cf-litellm-destroy}/bin/cf-litellm-destroy";
                meta.description = "tofu destroy the LiteLLM Cloudflare resources (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-landing-apply = {
                type = "app";
                program = "${self.packages.${system}.cf-landing-apply}/bin/cf-landing-apply";
                meta.description = "Render infra/cloudflare/landing.nix (terranix) and tofu apply it (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-landing-destroy = {
                type = "app";
                program = "${self.packages.${system}.cf-landing-destroy}/bin/cf-landing-destroy";
                meta.description = "tofu destroy the landing-page Cloudflare resources (needs CLOUDFLARE_API_TOKEN)";
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
      # deliberately NOT checks: BUILDING them (esp. the cold rpi kernel, ~1h) is
      # a RELEASE-time concern. Merge CI instead EVALUATES the host configs
      # (cheap, catches config/eval errors) without building — see
      # .github/workflows/nix-ci.yml.
      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
        pre-commit = preCommitFor system;
      });
    };
}
