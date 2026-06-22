# Generic NixOS VM (UTM `virt` machine / QEMU) — UEFI + systemd-boot + VirtIO.
# Architecture is chosen in flake.nix (`mkNixos { system = … }`), so this file
# is arch-agnostic and backs the aarch64 UTM VM today. Distinct from `nixrpi`,
# which targets real Raspberry Pi 4 hardware via raspberry-pi-nix (SD image).
# Install with: nixos-install --flake .#nixvm
{ config, secretsDir, ... }:
{
  networking.hostName = "nixvm";

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
  fileSystems."/boot" = {
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
  # avoid re-encryption). After first boot, re-encrypt the cred to this host's
  # key so agenix can decrypt it at activation:
  #   1. cat /etc/ssh/ssh_host_ed25519_key.pub
  #   2. Add it as a recipient in secrets/secrets.nix
  #   3. cd secrets && agenix -e nixbox-tunnel-creds.age   (or: re-encrypt via age)
  #   4. Commit + nixos-rebuild switch
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
