# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
{
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

  # Cloudflare Tunnel — REMOTELY-MANAGED (token) connector. The tunnel, its
  # public-hostname ingress (nixrpi.kattakath.com → ssh://localhost:22) and the
  # proxied CNAME live in the Cloudflare account (provisioned once by
  # scripts/cf-one-provision.sh). This host only carries the connector token
  # (one line `TUNNEL_TOKEN=…`) via agenix; modules/nixos/cloudflared.nix
  # (imported globally) runs the hardened systemd unit at boot — no login.
  #
  # nixrpi is DURABLE hardware → use approach (a): post-boot rekey, NOT prebake.
  # nixrpi-tunnel-token.age ships encrypted only to the personal key (correct
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

  age.secrets."nixrpi-tunnel-token".file = "${secretsDir}/nixrpi-tunnel-token.age";

  system.stateVersion = "24.05";
}
