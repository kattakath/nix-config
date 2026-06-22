# NixOS VM host — x86_64-linux.
# Replace fileSystems + boot with `nixos-generate-config` output on the real machine.
{ config, secretsDir, ... }: {
  networking.hostName = "nixbox";

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
