# ---- The fleet's three host configurations ----------------------------------
#
# Nothing here changed in wave 2 except where it lives and that the builders are
# reached through `config.flake.lib.*` — the public composition seam — rather
# than through a `let` binding only this file could see. `darwinConfigurations`
# is declared mergeable in modules/parts/lib-option.nix; `nixosConfigurations`
# flake-parts already declares (modules/nixosConfigurations.nix:11).
{ config, ... }:
let
  inherit (config.flake.lib) mkDarwin mkNixos;
  inherit (config.fleet) hostedSites;
in
{
  # ---- macOS system configurations ---------------------------------------
  # Built with `activate` (packages/activate.nix) — or any equivalent
  # `darwin-rebuild switch`; the extraModules entry below is what lets the bare
  # form find this flake at all.
  flake.darwinConfigurations = {
    # Apple Silicon Mac (aarch64-darwin), client only — no incoming traffic.
    "macos" = mkDarwin {
      system = "aarch64-darwin";
      hostname = "macos";
      # OPERATOR-ONLY, and deliberately NOT in hosts/macos.nix: this records
      # where this Mac's working tree happens to sit, which is machine trivia
      # rather than fleet policy. mkDarwin loads hosts/<hostname>.nix out of
      # THIS repo, and templates/default scaffolds downstream Macs with the
      # same `hostname = "macos"` — so anything put there would follow a clone
      # home and plant a DANGLING /etc/nix-darwin/flake.nix (activation still
      # succeeds; `darwin-rebuild` then silently ignores it, because `-e` is
      # false on a broken link). `extraModules` here is evaluated only for our
      # own flake.darwinConfigurations, so consumers never see it.
      extraModules = [
        (
          { config, loginName, ... }:
          {
            # Makes a bare `sudo darwin-rebuild switch` work — no --flake, no
            # #attr, no cd. Upstream takes `dirname $(readlink -f
            # /etc/nix-darwin/flake.nix)` as the flake and defaults the
            # attribute to `scutil --get LocalHostName`, which is already
            # `macos` here. A plain STRING source is the load-bearing part: a
            # path literal would copy a frozen snapshot into the store, while a
            # string symlinks the live tree, so a rebuild sees edits.
            environment.etc."nix-darwin/flake.nix".source = "${
              config.users.users.${loginName}.home
            }/Developer/github.com/kattakath/nix-config/flake.nix";
          }
        )
      ];
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
    # Raspberry Pi 4 — the fleet's LIVE server, carrying its real site list
    # directly (config.fleet.hostedSites, modules/parts/identity.nix) since the
    # private nix-personal flake was retired 2026-09-15. It used to say
    # "kattakath.com static landing page" — that apex left nixpi on 2026-09-07
    # and is a DNS-only CNAME to GitHub Pages now.
    # No extraModules: hosts/nixpi.nix imports its own Pi hardware modules via
    # mkNixos specialArgs.
    "nixpi" = mkNixos {
      system = "aarch64-linux";
      hostname = "nixpi";
      inherit hostedSites;
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
