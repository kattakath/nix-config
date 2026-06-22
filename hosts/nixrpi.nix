# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
{ config, secretsDir, ... }: {
  networking.hostName = "nixrpi";

  networking.useDHCP = true;

  # TODO: nixrpi-tunnel-creds.age is encrypted only to the user personal key.
  # Re-encrypt to host key after first boot (same steps as nixbox).

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
