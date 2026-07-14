# Minimal installer SD image for nixpi (aarch64-linux / Raspberry Pi 4).
# Flash to SD card, boot, SSH as nixos@nixpi-installer.local, then run:
#   sudo nixos-rebuild switch --flake github:kattakath/nix-config#nixpi
# Reboot → ssh ismail@nixpi.local (mDNS) to confirm the LIVE config came up.
{ lib, ... }:
{
  networking.hostName = "nixpi-installer";

  raspberry-pi-nix.board = "bcm2711";

  # Pi 4 boot fixes — MIRROR hosts/nixpi.nix (the installer boots on the same
  # hardware, so it needs the same fixes to BUILD and BOOT):
  #  - systemd initrd's TPM2 support forces tpm-tis/tpm-crb into
  #    boot.initrd.availableKernelModules, which the linux-rpi kernel does not
  #    build as loadable modules → FATAL `modprobe: Module tpm-crb not found`,
  #    failing linux-rpi-*-modules-shrunk (the SD image build). The Pi 4 has no
  #    TPM, so disable it at the source.
  #  - systemd stage-1 HANGS mounting the real root at /sysroot on the linux-rpi
  #    kernel; the scripted (bash) initrd hands off reliably. Keep both OFF.
  boot.initrd.systemd.tpm2.enable = lib.mkForce false;
  boot.initrd.systemd.enable = lib.mkForce false;

  services.openssh.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
    ];
    hashedPassword = "";
  };

  security.sudo.wheelNeedsPassword = false;

  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "24.05";
}
