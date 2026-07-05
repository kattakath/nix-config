# Generic NixOS VM (UTM `virt` machine / QEMU) — UEFI + systemd-boot + VirtIO.
# Architecture is chosen in flake.nix (`mkNixos { system = … }`), so this file
# is arch-agnostic and backs the aarch64 UTM VM today. Distinct from `nixrpi`,
# which targets real Raspberry Pi 4 hardware via raspberry-pi-nix (SD image).
# Install (from live ISO — single command):
#   nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixarm
{
  lib,
  ...
}:
{
  networking.hostName = "nixarm";

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

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

  # Declarative disk layout for `disko --mode disko` at install time.
  # disko.enableConfig = false: disko owns the partition/format step but does NOT
  # generate fileSystems entries — the qemu-efi image builder (disk-image.nix)
  # declares fileSystems."/" at the same priority, causing a merge conflict if
  # both emit that option. The manual fileSystems blocks below are the runtime
  # declarations; disko.devices is consumed only by the disko CLI.
  disko.enableConfig = false;
  disko.devices = {
    disk.vda = {
      type = "disk";
      device = "/dev/vda";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
              extraArgs = [
                "-n"
                "boot"
              ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              extraArgs = [
                "-L"
                "nixos"
              ];
            };
          };
        };
      };
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  # lib.mkDefault lets the image builder (qemu-efi) override the /boot label
  # (it uses "ESP"); the installed VM always uses "boot" at runtime.
  fileSystems."/boot" = lib.mkDefault {
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
