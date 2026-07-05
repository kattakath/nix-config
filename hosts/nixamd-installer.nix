# Minimal NixOS installer ISO for nixamd (x86_64-linux).
# Boot from this ISO, SSH as nixos@nixamd-installer.local, then run:
#   nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixamd
# Reboot → ssh ismail@nixamd.local
_: {
  networking.hostName = "nixamd-installer";

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
