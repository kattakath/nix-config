# NixOS VM host — x86_64-linux.
# Replace fileSystems + boot with `nixos-generate-config` output on the real machine.
_: {
  networking.hostName = "nixbox";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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
