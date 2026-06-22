# Generic aarch64-linux NixOS VM (e.g. UTM `virt` machine on Apple Silicon).
# UEFI + systemd-boot + VirtIO — distinct from `nixrpi`, which targets real
# Raspberry Pi 4 hardware via raspberry-pi-nix (SD image, bcm2711 bootloader).
# Install with: nixos-install --flake .#nixvm-aarch64
{ ... }:
{
  networking.hostName = "nixvm-aarch64";

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

  system.stateVersion = "24.05";
}
