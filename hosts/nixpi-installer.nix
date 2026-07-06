# Minimal installer SD image for nixpi (aarch64-linux / Raspberry Pi 4).
# Flash to SD card, boot, SSH as nixos@nixpi-installer.local, then run:
#   sudo nixos-rebuild switch --flake github:ismailkattakath/nix-config#nixpi
# Reboot → ssh ismail@nixpi.local (mDNS) to confirm the LIVE config came up.
_: {
  networking.hostName = "nixpi-installer";

  raspberry-pi-nix.board = "bcm2711";

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
