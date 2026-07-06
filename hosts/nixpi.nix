# NixOS host for Raspberry Pi 4 (aarch64-linux) — the fleet's LIVE server.
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
#
# SSH ACCESS: over the Cloudflare Tunnel connector below (remotely-managed,
# token-based — no port-forward, no public IP). mDNS (nixpi.local) also works
# on the LAN. Service tokens live at /etc/secrets/ — place manually after
# provisioning. The connector unit retries on failure (Restart=on-failure) so
# dropping the file in after first boot self-heals without a rebuild.
{
  lib,
  ...
}:
{
  imports = [
    ../modules/nixos/cloudflared.nix
    ../modules/nixos/caddy-proxy.nix
  ];

  networking.hostName = "nixpi";

  # nixpkgs enables systemd stage-1 by default (boot.initrd.systemd.enable), and
  # its TPM2 support (nixos/modules/system/boot/systemd/tpm2.nix) forces the
  # `tpm-tis` + `tpm-crb` kernel modules into boot.initrd.availableKernelModules.
  # The raspberry-pi-nix `linux-rpi` kernel builds neither as a loadable module,
  # and makeModulesClosure treats availableKernelModules as REQUIRED root modules
  # (boot.initrd.allowMissingModules defaults false) — so the missing module is a
  # FATAL `modprobe: Module tpm-crb not found`, failing linux-rpi-*-modules-shrunk.
  # The Pi 4 has no TPM, so disable initrd TPM2 support at the source (removes
  # both modules).
  boot.initrd.systemd.tpm2.enable = lib.mkForce false;

  # CONFIRMED BOOT FIX: use the SCRIPTED (bash) initrd, not systemd-initrd.
  # nixpkgs enables systemd stage-1 (boot.initrd.systemd.enable) by default, but on
  # the raspberry-pi-nix `linux-rpi` kernel it HANGS stage-1 mounting the real root
  # at /sysroot (the Pi never reaches stage-2 / a login). The classic scripted
  # initrd mounts /sysroot and hands off reliably on this kernel, so force it off.
  # mkForce because nixpkgs sets the default to true; keep this OFF forever — a
  # config that reintroduces systemd-initrd will not reboot on this hardware.
  boot.initrd.systemd.enable = lib.mkForce false;

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  networking.useDHCP = true;

  raspberry-pi-nix = {
    board = "bcm2711";
  };

  # SSH over the Cloudflare Tunnel — loginless, token-based connector. Place a
  # token at /etc/secrets/cloudflared-token after provisioning; the unit retries
  # on failure so dropping the file in after first boot self-heals.
  services.cloudflared-connector.enable = true;

  # Local reverse-proxy/router, sitting behind the tunnel. Today it serves only
  # the public kattakath.com static landing page; future services front new
  # virtualHosts entries here rather than a new tunnel per-service.
  services.caddy-proxy = {
    enable = true;
    virtualHosts."kattakath.com".root = ../packages/landing;
  };

  system.stateVersion = "24.05";
}
