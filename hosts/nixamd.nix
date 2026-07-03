# Generic x86_64-linux NixOS host — UEFI + systemd-boot + VirtIO.
# CONFIG-ONLY / CI-eval today: there is no VM launcher, because x86_64 on Apple
# Silicon runs under slow TCG emulation (not sensible to boot locally). This
# host exists so the flake evaluates the x86_64-linux path; a real machine must
# replace the boot/fileSystems stanza below with `nixos-generate-config`
# hardware output (real disk-by-uuid, actual kernel modules, etc.).
#
# Modeled on hosts/nixarm.nix. The Cloudflare tunnel is PRE-WIRED but INERT:
# the CF tunnel + DNS (nixamd.kattakath.com) are already reserved and
# secrets/nixamd-tunnel-token.age exists (encrypted to the PERSONAL key only).
# But nixamd has no provisioned SSH host key yet, so it could not decrypt that
# token at activation. The connector is therefore gated behind `tunnelReady`
# (default false) so it stays off. Once a real host exists:
#   1. boot it, collect /etc/ssh/ssh_host_ed25519_key.pub,
#   2. add it as a recipient in secrets/secrets.nix,
#   3. re-encrypt the existing token adding that host key (skill: agenix-host-rekey),
#   4. flip `tunnelReady` to true.
# modules/nixos/cloudflared.nix (imported globally) then runs the hardened
# systemd connector at boot by picking up the "nixamd-tunnel-token" secret.
{
  lib,
  secretsDir,
  ...
}:
let
  # Kept false: the CF tunnel + secrets/nixamd-tunnel-token.age already exist,
  # but nixamd has no host key among the recipients, so it could not decrypt the
  # token at activation. Flip to true once a real nixamd's /etc/ssh host key is
  # added as a recipient and the token re-encrypted (agenix-host-rekey).
  tunnelReady = false;
in
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

  # Cloudflare Tunnel — PRE-WIRED but inert (see the header note). Gated on
  # `tunnelReady` so the missing nixamd-tunnel-token.age never breaks eval; when
  # false the "nixamd-tunnel-token" secret is undeclared, so
  # modules/nixos/cloudflared.nix (which guards on the secret's presence) leaves
  # the connector unit off. Flip `tunnelReady` to true once the .age exists.
  age.secrets = lib.mkIf tunnelReady {
    "nixamd-tunnel-token".file = "${secretsDir}/nixamd-tunnel-token.age";
  };

  system.stateVersion = "24.05";
}
