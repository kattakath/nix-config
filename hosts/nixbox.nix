# NixOS VM host — x86_64-linux.
# Replace fileSystems + boot with `nixos-generate-config` output on the real machine.
{ config, secretsDir, ... }: {
  networking.hostName = "nixbox";

  # Basic networking — DHCP on all interfaces.
  networking.useDHCP = true;

  # agenix system-level identity: use the host's SSH key to decrypt system secrets.
  # TODO: nixbox-tunnel-creds.age is currently encrypted only to userKeys (the user's
  # personal ed25519 key in secrets/secrets.nix). The agenix NixOS module decrypts
  # system secrets using the HOST ssh key (/etc/ssh/ssh_host_ed25519_key), which is
  # a DIFFERENT key — so decryption will fail at activation time until the .age file
  # is re-encrypted to the host's public key. Steps to fix after first boot:
  #   1. cat /etc/ssh/ssh_host_ed25519_key.pub   # get the host key
  #   2. Add it to secrets/secrets.nix as a hostKey for nixbox
  #   3. Re-run: cd secrets && agenix -e nixbox-tunnel-creds.age
  #   4. Commit the updated .age file and secrets.nix
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

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

  age.secrets.nixbox-tunnel-creds = {
    file = "${secretsDir}/nixbox-tunnel-creds.age";
    mode = "0400";
    owner = "root";
  };

  services.cloudflared.tunnels."48199503-cdee-4f62-b233-0dfa3bac4b5a" = {
    credentialsFile = config.age.secrets.nixbox-tunnel-creds.path;
    ingress."nixbox.kattakath.com" = "ssh://localhost:22";
    default = "http_status:404";
  };

  system.stateVersion = "24.05";
}
