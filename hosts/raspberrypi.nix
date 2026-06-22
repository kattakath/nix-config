# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.raspberrypi.config.system.build.sdImage
_: {
  networking.hostName = "raspberrypi";

  raspberry-pi-nix = {
    board = "bcm2711";
  };

  system.stateVersion = "24.05";
}
