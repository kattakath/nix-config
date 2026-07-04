# Generic x86_64-linux NixOS host — UEFI + systemd-boot + VirtIO.
# Runs under QEMU TCG emulation on Apple Silicon (slow but functional).
# Bootstrap (from live ISO — single command):
#   nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixamd
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
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "ahci"
    "sd_mod"
  ];

  # Declarative disk layout for `disko-install` at bootstrap time.
  # Mirrors nixarm: disko.enableConfig = false keeps fileSystems ownership here,
  # avoiding any merge conflict if an image builder is added later.
  disko.enableConfig = false;
  disko.devices = {
    disk.vda = {
      type = "disk";
      device = "/dev/vda";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
              extraArgs = [
                "-n"
                "boot"
              ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              extraArgs = [
                "-L"
                "nixos"
              ];
            };
          };
        };
      };
    };
  };

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
