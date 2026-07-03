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
      agenix,
      raspberry-pi-nix,
      nix-vscode-extensions,
      nix-homebrew,
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

      # Unfree-permitting nixpkgs, ONLY for the devcontainer image (claude-code is
      # unfree). legacyPackages has unfree disabled, so the image derivation needs
      # its own instance. Deliberately scoped here — no other output imports it.
      pkgsUnfreeFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      # ---- Formatting / lint (treefmt-nix) ------------------------------------
      # Evaluate ./treefmt.nix per system. The wrapper backs `nix fmt`; the
      # `.config.build.check` derivation backs the CI formatting gate.
      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix);

      # ---- Shared dev toolchain -----------------------------------------------
      # Single source of truth for the pinned dev tools, consumed by BOTH the
      # `nix develop` devShell AND the prebuilt devcontainer image — so the two
      # can never drift. (preCommit.enabledPackages is added on the devShell side
      # only; the image bakes the treefmt wrapper directly.)
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
            inherit username;
            secretsDir = "${self}/secrets";
          };
          modules = [
            ./hosts/${hostname}.nix
            ./modules/nixos/core.nix
            ./modules/shared/nix-cache.nix # Cachix binary cache (read)
            agenix.nixosModules.default # system-level age.secrets (distinct from HM module)
            ./modules/nixos/cloudflared.nix # enables services.cloudflared daemon
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.${username} = {
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
              username
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
        };

        # Generic NixOS host — x86_64 (config-only / CI-eval; no VM launcher,
        # since x86_64 on Apple Silicon runs under slow TCG). No cloudflared /
        # agenix secret yet (no provisioned host key) — adding a tunnel is a
        # follow-up once a host key exists.
        "nixamd" = mkNixos {
          system = "x86_64-linux";
          hostname = "nixamd";
        };
      };

      # ---- Packages: container images + VM image -------------------------------
      # `nix build .#packages.<system>.dockerImage`        → minimal runtime tarball
      # `nix build .#packages.<linux>.devcontainerImage`   → devcontainer stream script (Linux only)
      # `nix build .#nixarm-image`                         → UTM-importable qcow2 → ./result/
      # Merge the per-system base with the system-specific extras in one fold —
      # flatter than nesting recursiveUpdate calls, and the merge order reads
      # top-to-bottom: base (all systems) → devcontainer (linux) → single-system.
      packages = nixpkgs.lib.foldl' nixpkgs.lib.recursiveUpdate { } [
        # Base: minimal runtime container image, per system.
        (forAllSystems (system: {
          dockerImage = (pkgsFor system).callPackage ./packages/docker-image.nix { };
        }))

        # Devcontainer image is a Linux OCI artifact — gate to the linux triple.
        # Built with unfree pkgs (claude-code) and the SHARED dev toolchain, so
        # `nix develop` inside the container resolves from the baked store.
        (nixpkgs.lib.genAttrs linuxSystems (system: {
          devcontainerImage = (pkgsUnfreeFor system).callPackage ./packages/devcontainer-image.nix {
            devPackages = devPackagesFor system;
          };
        }))

        {
          aarch64-linux.nixarm-image = self.nixosConfigurations.nixarm.config.system.build.images.qemu-efi;
          # Exposed as a package (not just wrapped in the app) so CI can build
          # it — that build is what runs the writeShellApplication shellcheck.
          aarch64-darwin.nixarm-vm = (pkgsFor "aarch64-darwin").callPackage ./packages/nixarm-vm.nix { };
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
      apps.aarch64-darwin.nixarm-vm = {
        type = "app";
        program = "${self.packages.aarch64-darwin.nixarm-vm}/bin/run-nixarm-vm";
        meta.description = "Boot nixarm qcow2 in QEMU with Apple HVF — no UTM needed (aarch64-darwin only)";
      };

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
      # `formatting` fails on any unformatted/lintable file; `pre-commit` runs
      # the configured hooks in the sandbox so CI mirrors local commits.
      # Lint/format only — kept lean so merge CI is fast. The host toplevels are
      # deliberately NOT checks: BUILDING them (esp. the cold linux-rpi kernel,
      # ~1h) is a RELEASE-time concern, done later against `nixosConfigurations.*`
      # / `darwinConfigurations.*` directly. Merge CI instead EVALUATES those
      # configs (cheap, catches config/eval errors) without building — see
      # .github/workflows/nix-ci.yml.
      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
        pre-commit = preCommitFor system;
      });
    };
}
