# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
{ config, secretsDir, ... }: {
  networking.hostName = "nixrpi";

  networking.useDHCP = true;

  # agenix identity: same TODO as nixbox — re-encrypt nixrpi-tunnel-creds.age
  # to /etc/ssh/ssh_host_ed25519_key.pub after first boot.
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  raspberry-pi-nix = {
    board = "bcm2711";
  };

  age.secrets.nixrpi-tunnel-creds = {
    file = "${secretsDir}/nixrpi-tunnel-creds.age";
    mode = "0400";
    owner = "root";
  };

  services.cloudflared.tunnels."41e4c439-83d7-43a0-9a03-bba58eb9e66d" = {
    credentialsFile = config.age.secrets.nixrpi-tunnel-creds.path;
    ingress."nixrpi.kattakath.com" = "ssh://localhost:22";
    default = "http_status:404";
  };

  system.stateVersion = "24.05";
}
