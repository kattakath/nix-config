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
    in
    {
      # ---- macOS system configuration ----------------------------------------
      # Built with `darwin-rebuild switch --flake .#m3pro`.
      darwinConfigurations."m3pro" = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = {
          inherit
            home-manager
            username
            nix-vscode-extensions
            ;
        };
        modules = [ ./hosts/m3pro.nix ];
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
        "nixbox" = mkNixos {
          system = "aarch64-linux";
          hostname = "nixbox";
        };
      };

      # ---- Packages: container image + VM image --------------------------------
      # `nix build .#packages.<system>.dockerImage`  → loadable tarball
      # `nix build .#nixbox-image`                   → UTM-importable qcow2 → ./result/
      packages =
        nixpkgs.lib.recursiveUpdate
          (forAllSystems (
            system:
            let
              pkgs = pkgsFor system;
            in
            {
              dockerImage = pkgs.callPackage ./packages/docker-image.nix { };
            }
          ))
          {
            aarch64-linux.nixbox-image = self.nixosConfigurations.nixbox.config.system.build.images.qemu-efi;
          };

      # ---- Apps: native VM launcher (macOS only) -----------------------------
      # `nix run .#nixbox-vm` — boots the nixbox qcow2 in QEMU with Apple HVF
      # acceleration. No UTM required. User-mode networking with hostfwd 2222→22
      # for direct SSH before the Cloudflare tunnel is active.
      #
      # Prerequisites:
      #   1. Build qcow2 on an aarch64-linux builder: nix build .#nixbox-image
      #   2. Copy to the default disk path (or set NIXBOX_DISK=/path/to/qcow2):
      #        cp result/*.qcow2 ~/.local/state/nixbox-vm/nixbox.qcow2
      apps.aarch64-darwin.nixbox-vm =
        let
          pkgs = pkgsFor "aarch64-darwin";
          script = pkgs.writeShellScript "run-nixbox-vm" ''
            set -euo pipefail

            STATE="''${XDG_STATE_HOME:-$HOME/.local/state}/nixbox-vm"
            DISK="''${NIXBOX_DISK:-$STATE/nixbox.qcow2}"
            VARS="$STATE/OVMF_VARS.fd"

            FIRMWARE_CODE="${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd"
            FIRMWARE_VARS="${pkgs.qemu}/share/qemu/edk2-aarch64-vars.fd"

            if [ ! -f "$FIRMWARE_CODE" ]; then
              echo "error: aarch64 UEFI firmware not found at $FIRMWARE_CODE" >&2
              echo "hint: check that pkgs.qemu ships edk2-aarch64-code.fd on aarch64-darwin" >&2
              exit 1
            fi

            if [ ! -f "$DISK" ]; then
              echo "error: nixbox disk image not found: $DISK" >&2
              echo "" >&2
              echo "Build it (requires an aarch64-linux builder or remote builder):" >&2
              echo "  nix build .#nixbox-image && cp result/*.qcow2 $DISK" >&2
              echo "" >&2
              echo "Or point to an existing qcow2:  NIXBOX_DISK=/path/to/nixbox.qcow2 nix run .#nixbox-vm" >&2
              exit 1
            fi

            mkdir -p "$STATE"

            # Copy UEFI vars on first run so boot-order changes persist across reboots.
            if [ ! -f "$VARS" ] && [ -f "$FIRMWARE_VARS" ]; then
              cp "$FIRMWARE_VARS" "$VARS"
            fi

            PFLASH_VARS=""
            if [ -f "$VARS" ]; then
              PFLASH_VARS="-drive if=pflash,format=raw,file=$VARS"
            fi

            echo "nixbox-vm: booting $DISK" >&2
            echo "  SSH (direct):  ssh -p 2222 izzy@localhost" >&2
            echo "  SSH (tunnel):  ssh izzy@nixbox.kattakath.com  (once tunnel is active)" >&2
            echo "  QEMU monitor:  Ctrl-a c  (then 'quit' to exit)" >&2

            exec ${pkgs.qemu}/bin/qemu-system-aarch64 \
              -machine virt,accel=hvf \
              -cpu host \
              -m "''${NIXBOX_MEMORY:-2048}" \
              -smp "''${NIXBOX_CPUS:-4}" \
              -drive if=pflash,format=raw,file="$FIRMWARE_CODE",readonly=on \
              $PFLASH_VARS \
              -drive file="$DISK",format=qcow2,if=virtio \
              -netdev user,id=net0,hostfwd=tcp::2222-:22 \
              -device virtio-net-pci,netdev=net0 \
              -serial mon:stdio \
              -nographic
          '';
        in
        {
          type = "app";
          program = "${script}";
          meta.description = "Boot nixbox qcow2 in QEMU with Apple HVF — no UTM needed (aarch64-darwin only)";
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
