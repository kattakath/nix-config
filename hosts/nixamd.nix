# Generic x86_64-linux NixOS host — UEFI + systemd-boot + VirtIO.
# CONFIG-ONLY / CI-eval today: there is no VM launcher, because x86_64 on Apple
# Silicon runs under slow TCG emulation (not sensible to boot locally). This
# host exists so the flake evaluates the x86_64-linux path; a real machine must
# replace the boot/fileSystems stanza below with `nixos-generate-config`
# hardware output (real disk-by-uuid, actual kernel modules, etc.).
#
# Modeled on hosts/nixarm.nix, but WITHOUT the Cloudflare tunnel: nixamd has no
# provisioned SSH host key yet, so there is no agenix recipient to encrypt a
# tunnel credential to. Adding a tunnel is a follow-up once a host key exists
# (mint the key, add it to secrets/secrets.nix, encrypt an nixamd-tunnel-creds
# secret, then wire services.cloudflared here like nixarm does).
{
  lib,
  ...
}:
{
  networking.hostName = "nixamd";

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  # DHCP on all interfaces.
  networking.useDHCP = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # VirtIO initrd modules — required for the root disk to mount in a QEMU VM.
  # A real machine needs its own nixos-generate-config hardware output here.
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
  fileSystems."/boot" = lib.mkDefault {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  # No Cloudflare tunnel yet (no host key → no agenix recipient). The shared
  # modules/nixos/cloudflared.nix enables the daemon unconditionally; override
  # it off here so eval/activation never expects a credentials file that does
  # not exist. Flip this on (and add the tunnel + secret) once nixamd has a
  # provisioned host key — see the header note.
  services.cloudflared.enable = lib.mkForce false;

  system.stateVersion = "24.05";
}
