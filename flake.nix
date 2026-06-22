{
  description = "All-in-one Nix mono-repo: NixOS VMs + Raspberry Pi 4, macOS (nix-darwin), Home Manager for Linux/macOS/containers, and minimal Docker images — single source of truth across all hosts.";

  inputs = {
    # Unstable channel as the single source of truth for every platform.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # macOS system layer (standalone, not NixOS). Follows the parent nixpkgs
    # so we never download a second copy of the package set.
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # User layer, shared by every host. Also pinned to the parent nixpkgs.
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Formatting/lint aggregator: one config (./treefmt.nix) drives `nix fmt`,
    # the `checks.formatting` CI gate, and the pre-commit hook. Single source.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Git pre-commit hooks, installed automatically on `nix develop`.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # Raspberry Pi 4 NixOS support: kernel, firmware, and SD-card image builder.
    raspberry-pi-nix.url = "github:nix-community/raspberry-pi-nix";
    raspberry-pi-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      home-manager,
      treefmt-nix,
      git-hooks,
      agenix,
      raspberry-pi-nix,
      ...
    }:
    let
      # ---- Single source of truth for the human username ----------------------
      username = "izzy";

      # ---- DRY system mapping -------------------------------------------------
      # The canonical set of architectures this repo targets. Every package /
      # devShell output is generated for all of them via forAllSystems.
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [ "aarch64-darwin" ];
      allSystems = linuxSystems ++ darwinSystems;

      # Generate an attrset keyed by system, e.g. { "x86_64-linux" = f "x86_64-linux"; ... }
      forAllSystems = f: nixpkgs.lib.genAttrs allSystems f;

      # Per-system nixpkgs accessor (legacyPackages avoids a redundant eval).
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # ---- Formatting / lint (treefmt-nix) ------------------------------------
      # Evaluate ./treefmt.nix per system. The wrapper backs `nix fmt`; the
      # `.config.build.check` derivation backs the CI formatting gate.
      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix);

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

      # ---- Home Manager builder (user logic, 100% reused) ---------------------
      # One helper produces a standalone homeConfiguration for any (system, user,
      # homeDirectory). Platform-specific modules are appended per call so the
      # shared profile stays pure. This is the DRY seam: system logic lives in
      # modules/{linux,darwin}, user logic lives in modules/shared.
      mkHome =
        {
          system,
          homeDirectory ? (
            if nixpkgs.lib.hasSuffix "darwin" system then "/Users/${username}" else "/home/${username}"
          ),
          modules ? [ ],
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsFor system;
          extraSpecialArgs = {
            secretsDir = ./secrets;
          };
          modules = [
            ./modules/shared/home.nix
            {
              home = {
                inherit username homeDirectory;
                # Keep in lockstep with nixpkgs; bump deliberately.
                stateVersion = "24.05";
              };
            }
          ]
          ++ modules;
        };

      # ---- NixOS system builder ---------------------------------------------------
      # Produces a full NixOS system with Home Manager embedded. Home Manager user
      # config is the same shared profile used by standalone and darwin hosts.
      mkNixos =
        {
          system,
          hostname,
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit agenix raspberry-pi-nix username;
            secretsDir = ./secrets;
          };
          modules = [
            ./hosts/${hostname}.nix
            ./modules/nixos/core.nix
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  secretsDir = ./secrets;
                };
                users.${username} = {
                  imports = [
                    ./modules/shared/home.nix
                    agenix.homeManagerModules.default
                  ];
                  home.stateVersion = "24.05";
                };
              };
            }
          ]
          ++ extraModules;
        };
    in
    {
      # ---- macOS system configuration ----------------------------------------
      # Built with `darwin-rebuild switch --flake .#macbook`.
      darwinConfigurations."macbook" = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = {
          inherit
            self
            home-manager
            agenix
            username
            ;
        };
        modules = [ ./hosts/macbook.nix ];
      };

      # ---- NixOS system configurations -------------------------------------------
      # Built with `nixos-rebuild switch --flake .#<hostname>`.
      # SD card image for RPi: nix build .#nixosConfigurations.raspberrypi.config.system.build.sdImage
      nixosConfigurations = {
        "nixos-vm" = mkNixos {
          system = "x86_64-linux";
          hostname = "nixos-vm";
        };

        "raspberrypi" = mkNixos {
          system = "aarch64-linux";
          hostname = "raspberrypi";
          extraModules = [
            raspberry-pi-nix.nixosModules.raspberry-pi
            raspberry-pi-nix.nixosModules.sd-image
          ];
        };
      };

      # ---- Standalone Home Manager configurations ----------------------------
      # Built with `home-manager switch --flake .#user@<host>`.
      homeConfigurations = {
        "${username}@ubuntu-vm" = mkHome {
          system = "x86_64-linux";
          modules = [
            ./modules/linux/nix-ld.nix
            agenix.homeManagerModules.default
          ];
        };

        "${username}@raspberrypi" = mkHome {
          system = "aarch64-linux";
          modules = [
            ./modules/linux/nix-ld.nix
            agenix.homeManagerModules.default
          ];
        };
      };

      # ---- Minimal runtime container image -----------------------------------
      # `nix build .#packages.<system>.dockerImage` → loadable tarball.
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          dockerImage = pkgs.callPackage ./packages/docker-image.nix { };
        }
      );

      # ---- Multi-architecture dev shell --------------------------------------
      # `nix develop` on any target. Used as the default Devcontainer profile.
      # The shellHook installs the git pre-commit hook automatically. nixd is the
      # eval-aware LSP for editor completion. statix/deadnix/jq are exposed as
      # standalone binaries (NOT via preCommit.enabledPackages, which only yields
      # the treefmt wrapper) so the .vscode lint tasks can call them directly.
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          preCommit = preCommitFor system;
        in
        {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                git
                nixd # eval-aware Nix LSP (flake/home-manager/nix-darwin completion)
                home-manager.packages.${system}.default
                treefmtEval.${system}.config.build.wrapper # `treefmt` / `nix fmt`
                statix # anti-pattern linter — .vscode "nix: statix" task
                deadnix # dead-code linter — .vscode "nix: deadnix" task
                jq # flattens deadnix JSON for the problem matcher
              ]
              ++ preCommit.enabledPackages;

            shellHook = ''
              ${preCommit.shellHook}
              echo "nix-config devShell ready on ${system} — pre-commit hooks installed"
            '';
          };
        }
      );

      # ---- Formatter: `nix fmt` runs treefmt (nixfmt + statix + deadnix) ------
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # ---- Checks: `nix flake check` enforces formatting + lint + hooks ------
      # `formatting` fails on any unformatted/lintable file; `pre-commit` runs
      # the configured hooks in the sandbox so CI mirrors local commits.
      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
        pre-commit = preCommitFor system;
      });
    };
}
