# Generic x86_64-linux NixOS host — UEFI + systemd-boot + VirtIO.
# Runs under QEMU TCG emulation on Apple Silicon (slow but functional).
# Bootstrap (from live ISO — single command):
#   nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixamd
#
# Modeled on hosts/nixarm.nix. The Cloudflare tunnel is ACTIVE:
# the CF tunnel + DNS (nixamd.kattakath.com) are reserved and
# secrets/nixamd-tunnel-token.age is rekeyed to nixamd's live SSH host key
# (agenix-host-rekey 2026-07-04). The connector unit runs at boot via
# modules/nixos/cloudflared.nix, which picks up the "nixamd-tunnel-token" secret.
{
  lib,
  secretsDir,
  ...
}:
let
  # nixamd host key added as recipient and token re-encrypted 2026-07-04
  # (agenix-host-rekey). Connector activates at boot via the rekeyed
  # nixamd-tunnel-token secret.
  tunnelReady = true;
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

  # Cloudflare Tunnel — active. tunnelReady=true enables the nixamd-tunnel-token
  # secret; modules/nixos/cloudflared.nix (which guards on the secret's presence)
  # starts the hardened cloudflared-connector unit at boot.
  # Token rekeyed to the nixamd host key 2026-07-04 (agenix-host-rekey).
  age.secrets = lib.mkIf tunnelReady {
    "nixamd-tunnel-token".file = "${secretsDir}/nixamd-tunnel-token.age";
  };

  system.stateVersion = "24.05";
}
