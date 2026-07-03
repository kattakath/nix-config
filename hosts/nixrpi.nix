# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
{
  config,
  lib,
  secretsDir,
  ...
}:
{
  networking.hostName = "nixrpi";

  # nixpkgs enables systemd stage-1 by default (boot.initrd.systemd.enable), and
  # its TPM2 support (nixos/modules/system/boot/systemd/tpm2.nix) forces the
  # `tpm-tis` + `tpm-crb` kernel modules into boot.initrd.availableKernelModules.
  # The raspberry-pi-nix `linux-rpi` kernel builds neither as a loadable module,
  # and makeModulesClosure treats availableKernelModules as REQUIRED root modules
  # (boot.initrd.allowMissingModules defaults false) — so the missing module is a
  # FATAL `modprobe: Module tpm-crb not found`, failing linux-rpi-*-modules-shrunk.
  # The Pi 4 has no TPM, so disable initrd TPM2 support at the source (removes
  # both modules). nixarm is untouched: it never imports this profile, and its
  # generic kernel builds the full TPM stack anyway.
  boot.initrd.systemd.tpm2.enable = lib.mkForce false;

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  networking.useDHCP = true;

  # nixrpi is DURABLE hardware → use approach (a): post-boot rekey, NOT prebake.
  # nixrpi-tunnel-creds.age ships encrypted only to the personal key (correct
  # pre-first-boot). After the Pi's first boot, add its own
  # /etc/ssh/ssh_host_ed25519_key.pub as a recipient in secrets/secrets.nix and
  # re-encrypt — run the agenix-host-rekey skill. The Pi's own first-boot key is
  # a unique per-host identity, so no key pinning/injection is needed.
  #
  # HAZARD: SSH host keys double as age identities — rotating/reimaging the Pi's
  # /etc/ssh key silently breaks decryption of every host-scoped .age; re-run
  # agenix-host-rekey after any host-key change.

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
