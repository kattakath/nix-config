# Generic NixOS VM (UTM `virt` machine / QEMU) — UEFI + systemd-boot + VirtIO.
# Architecture is chosen in flake.nix (`mkNixos { system = … }`), so this file
# is arch-agnostic and backs the aarch64 UTM VM today. Distinct from `nixrpi`,
# which targets real Raspberry Pi 4 hardware via raspberry-pi-nix (SD image).
# Install with: nixos-install --flake .#nixarm
{
  lib,
  secretsDir,
  ...
}:
{
  networking.hostName = "nixarm";

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  # DHCP on all interfaces (UTM vmnet-shared hands out a routable IP).
  networking.useDHCP = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # VirtIO initrd modules — required for the root disk to mount in a QEMU/UTM VM.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "ahci"
    "sd_mod"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  # lib.mkDefault lets the image builder (qemu-efi format) override the boot
  # label (it uses "ESP"); the installed VM always uses "boot" at runtime.
  fileSystems."/boot" = lib.mkDefault {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  # Cloudflare Tunnel — REMOTELY-MANAGED (token) connector. The tunnel, its
  # public-hostname ingress (nixarm.kattakath.com → ssh://localhost:22) and the
  # proxied CNAME all live in the Cloudflare account (provisioned once by
  # scripts/cf-one-provision.sh). This host only carries the connector token
  # (one line `TUNNEL_TOKEN=…`) via agenix; modules/nixos/cloudflared.nix
  # (imported globally) runs the hardened systemd unit at boot — no login.
  #
  # nixarm uses the SAME post-boot rekey flow as nixrpi — NO prebake, NO pinned
  # host key baked into any image. nixarm-tunnel-token.age ships encrypted only to
  # the personal key (correct pre-first-boot). The nixarm image is generic and
  # generates its own /etc/ssh host key at first boot; after that first boot, add
  # its own /etc/ssh/ssh_host_ed25519_key.pub as a recipient in secrets/secrets.nix
  # and re-encrypt — run the agenix-host-rekey skill. Its first-boot key is a
  # unique per-image identity, so no key pinning/injection is needed.
  #
  # HAZARD: SSH host keys double as age identities — rotating/reimaging the VM's
  # /etc/ssh key silently breaks decryption of every host-scoped .age; re-run
  # agenix-host-rekey after any host-key change.
  age.secrets."nixarm-tunnel-token".file = "${secretsDir}/nixarm-tunnel-token.age";

  system.stateVersion = "24.05";
}
