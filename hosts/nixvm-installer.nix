# Minimal NixOS installer ISO for nixvm (aarch64-linux / UTM QEMU VM).
# Boot from this ISO, SSH as nixos@nixvm-installer.local, then run:
#   nix --extra-experimental-features 'nix-command flakes' run github:kattakath/nix-config#nixvm
# Reboot → ssh ismailkattakath@nixvm.local
_: {
  networking.hostName = "nixvm-installer";

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
