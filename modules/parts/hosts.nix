# ---- The fleet's three host configurations ----------------------------------
#
# Nothing here changed in wave 2 except where it lives and that the builders are
# reached through `config.flake.lib.*` — the public composition seam — rather
# than through a `let` binding only this file could see. `darwinConfigurations`
# is declared mergeable in modules/parts/lib-option.nix; `nixosConfigurations`
# flake-parts already declares (modules/nixosConfigurations.nix:11).
{ config, inputs, ... }:
let
  inherit (inputs) nixpkgs raspberry-pi-nix;
  inherit (config.flake.lib) mkDarwin mkNixos;
in
{
  # ---- macOS system configurations ---------------------------------------
  # Built with `darwin-rebuild switch --flake .#macos`.
  flake.darwinConfigurations = {
    # Apple Silicon Mac (aarch64-darwin), client only — no incoming traffic.
    "macos" = mkDarwin {
      system = "aarch64-darwin";
      hostname = "macos";
    };

    # The former `macvm` Tart guest was REMOVED 2026-09-05 — deliberately, as
    # a thin re-addable layer, not an amputation: everything generic lives on
    # in the tart-vms capsule (modules/features/tart-vms/ — lifecycle CLI,
    # plug-and-play bootstrap, golden-image bake; it was the extracted
    # nix-tart-vms flake until ADR-002 wave 5), and the re-add procedure
    # is docs/macvm-readd-runbook.md. A baked golden image (tahoe-golden)
    # stays parked in ~/.tart for the day it returns.
  };

  # ---- NixOS system configurations -------------------------------------------
  # Built with `nixos-rebuild switch --flake .#<hostname>`.
  # SD card image for the Pi: nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
  flake.nixosConfigurations = {
    # Raspberry Pi 4 — the fleet's LIVE server. SITE-FREE in this public repo:
    # `hostedSites` defaults to [ ], so the real vhost list arrives from the
    # private nix-personal flake (docs/private-home-modules.md). It used to say
    # "kattakath.com static landing page" — that apex left nixpi on 2026-09-07
    # and is a DNS-only CNAME to GitHub Pages now.
    "nixpi" = mkNixos {
      system = "aarch64-linux";
      hostname = "nixpi";
      extraModules = [
        raspberry-pi-nix.nixosModules.raspberry-pi
        raspberry-pi-nix.nixosModules.sd-image
      ];
    };

    # Throwaway aarch64-linux dev VM, materialised ONLY as the graphical
    # `build-vm` variant behind `nix run .#nixvm` (an XFCE desktop in a
    # native QEMU window — it boots a THROWAWAY overlay, never an installed
    # disk). Since Determinate's native Linux builder is now enabled on the
    # macos host, the aarch64-linux guest closure builds locally with NO
    # provisioning — there is no installed nixvm, no builder VM, no runner.
    "nixvm" = mkNixos {
      system = "aarch64-linux";
      hostname = "nixvm";
      extraModules = [
        # The `build-vm` variant runs on the aarch64-darwin Mac, so its QEMU
        # runner must be macOS-native. host.pkgs is the pkgs whose qemu the
        # generated run-nixvm-vm executes — point it at aarch64-darwin. LAZY:
        # only the `system.build.vm` path forces this, so the aarch64-linux
        # toplevel eval (CI) never pulls in darwin pkgs. The rest of the variant
        # (graphics, desktop) lives in hosts/nixvm.nix.
        { virtualisation.vmVariant.virtualisation.host.pkgs = nixpkgs.legacyPackages."aarch64-darwin"; }
      ];
    };

    # (There is no separate `nixpi-installer`. The LIVE `nixpi` sdImage above
    # IS the flashable artifact — it bakes NO secrets (the tunnel token + Wi-Fi
    # are planted on the FAT FIRMWARE partition post-flash by nixpi-flash), so
    # it is a pure function of the flake and is prebuilt in CI, published to the
    # installer-latest release, and Cachix-warmed. `nix run .#nixpi-flash`
    # flashes it in one step — the old two-step "boot a minimal installer, ssh
    # nixos@nixpi-installer.local, nixos-rebuild" image was redundant and removed.)
  };
}
