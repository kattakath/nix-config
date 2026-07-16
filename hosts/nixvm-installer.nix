# Minimal NixOS installer ISO for nixvm (aarch64-linux, headless QEMU/HVF VM).
# Boot the empty QEMU VM from this ISO; it is the SSH-reachable Linux that
# nixos-anywhere installs *through* (see docs/nixvm-qemu-runbook.md + the
# nixvm-qemu-provision skill). Reboot → ssh ismailkattakath@nixvm.local
{
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

  # Operator PUBLIC key, single-sourced (see secrets/operator-key.nix). PUBLIC-only,
  # so the installer ISO stays secret-free.
  users.users.nixos.openssh.authorizedKeys.keys = [
    (import ../secrets/operator-key.nix)
  ];
}
