# Minimal NixOS installer ISO for nixarm (aarch64-linux / UTM QEMU VM).
# Boot from this ISO, SSH as nixos@nixarm-installer.local, then run:
#   nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixarm
# Reboot → ssh ismail@nixarm.local
_: {
  networking.hostName = "nixarm-installer";

  services.openssh.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  users.users.nixos.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
  ];
}
