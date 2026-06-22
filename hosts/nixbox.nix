# Generic NixOS VM (UTM `virt` machine / QEMU) — UEFI + systemd-boot + VirtIO.
# Architecture is chosen in flake.nix (`mkNixos { system = … }`), so this file
# is arch-agnostic and backs the aarch64 UTM VM today. Distinct from `nixrpi`,
# which targets real Raspberry Pi 4 hardware via raspberry-pi-nix (SD image).
# Install with: nixos-install --flake .#nixbox
{
  config,
  lib,
  secretsDir,
  ...
}:
{
  networking.hostName = "nixbox";

  # DHCP on all interfaces (UTM vmnet-shared hands out a routable IP).
  networking.useDHCP = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # VirtIO initrd modules — required for the root disk to mount in a QEMU/UTM VM.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "ahci"
    "sd_mod"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  # lib.mkDefault lets the image builder (qemu-efi format) override the boot
  # label (it uses "ESP"); the installed VM always uses "boot" at runtime.
  fileSystems."/boot" = lib.mkDefault {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  # Cloudflare Tunnel — reuses the existing tunnel cred (UUID + DNS CNAME live
  # on Cloudflare as nixbox.kattakath.com; the secret keeps its nixbox-* name to
  # avoid re-encryption). agenix decrypts it at activation with the host key
  # (age.identityPaths = /etc/ssh/ssh_host_ed25519_key in modules/nixos/core.nix).
  #
  # Two ways to make that key match the secret's recipient:
  #   (a) post-boot rekey — boot, collect the new host key, re-encrypt, rebuild
  #       (skill: agenix-host-rekey). Note: an in-VM `nixos-rebuild switch` is too
  #       heavy for the TCG-emulated VM and can crash it; prefer (b) for VMs.
  #   (b) PREBAKE (verified) — pin a host keypair offline, encrypt the cred to its
  #       public half, and inject the private half into the image's /etc/ssh/
  #       before first boot so the tunnel is up at boot with zero logins and no
  #       in-VM rebuild (skill: nixbox-prebake-hostkey).
  #
  # DECISION RULE: use (a) post-boot rekey for a DURABLE host (its own first-boot
  # key = a unique identity, no custom injection). Reserve (b) prebake for
  # DISPOSABLE VMs / distributed images that must have a working tunnel at first
  # boot with zero logins. Never share one pinned key across rebuilt durable images.
  #
  # HAZARD: SSH host keys double as age identities. Rotating/replacing
  # /etc/ssh/ssh_host_ed25519_key (reinstall, reimage, manual rotation) silently
  # makes every host-scoped .age here undecryptable at next activation — re-run
  # the agenix-host-rekey skill after any host-key change, then rebuild.
  age.secrets.tunnel-creds = {
    file = "${secretsDir}/nixbox-tunnel-creds.age";
    mode = "0400";
    owner = "root";
  };

  services.cloudflared.tunnels."48199503-cdee-4f62-b233-0dfa3bac4b5a" = {
    credentialsFile = config.age.secrets.tunnel-creds.path;
    ingress."nixbox.kattakath.com" = "ssh://localhost:22";
    default = "http_status:404";
  };

  system.stateVersion = "24.05";
}
