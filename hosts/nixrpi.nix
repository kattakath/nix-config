# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
_: {
  networking.hostName = "nixrpi";

  raspberry-pi-nix = {
    board = "bcm2711";
  };

  # Tunnel credentials wired via agenix — see secrets/nixrpi-tunnel-creds.age
  # age.secrets declaration added once secrets/nixrpi-tunnel-creds.age exists
  services.cloudflared.tunnels."41e4c439-83d7-43a0-9a03-bba58eb9e66d" = {
    credentialsFile = "/run/agenix/nixrpi-tunnel-creds";
    ingress."nixrpi.kattakath.com" = "ssh://localhost:22";
    default = "http_status:404";
  };

  system.stateVersion = "24.05";
}
