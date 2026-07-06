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
      ...
    }:
    let
      # ---- Single source of truth for the human identity ---------------------
      userName = "ismail";
      domainName = "kattakath.com";
      fullName = "Ismail Kattakath";
      handleName = "ismailkattakath";

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
            nix-homebrew.darwinModules.nix-homebrew # declaratively install brew (arch-correct prefix)
            ./hosts/${hostname}.nix
            ./modules/shared/nix-cache.nix # Cachix binary cache (read)
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
      ];

      # ---- Apps: bootstrap installer -----------------------------------------
      # `nix run .#nixvm` (on an aarch64-linux builder, from the live installer
      # ISO) — disko-install bootstrap for the nixvm sandbox VM.
      apps = {
        aarch64-linux.nixvm = {
          type = "app";
          program = "${self.packages.aarch64-linux.nixvm}/bin/nixvm";
          meta.description = "Bootstrap NixOS nixvm on aarch64-linux from the live ISO via disko-install";
        };
      };

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
