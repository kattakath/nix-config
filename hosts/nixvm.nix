# NixOS sandbox VM (UTM `virt` machine / QEMU HVF) — UEFI + systemd-boot +
# VirtIO. Architecture is chosen in flake.nix (`mkNixos { system = … }`), so
# this file is arch-agnostic and backs the aarch64 UTM VM today. Distinct from
# `nixpi`, which targets real Raspberry Pi 4 hardware via raspberry-pi-nix (SD
# image). MINIMAL for now — boots, serial console, SSH, disko; no desktop
# environment / no remote-desktop module yet (deferred to a follow-up).
# Install (from live ISO — single command):
#   nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixvm
{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.hostName = "nixvm";

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

  # Serial console — UTM/QEMU headless access before/without a display.
  systemd.services."serial-getty@ttyAMA0".enable = true;

  # Declarative disk layout for `disko --mode disko` at install time.
  # disko.enableConfig = false: disko owns the partition/format step but does NOT
  # generate fileSystems entries — the qemu-efi image builder (disk-image.nix)
  # declares fileSystems."/" at the same priority, causing a merge conflict if
  # both emit that option. The manual fileSystems blocks below are the runtime
  # declarations; disko.devices is consumed only by the disko CLI.
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
  # lib.mkDefault lets the image builder (qemu-efi) override the /boot label
  # (it uses "ESP"); the installed VM always uses "boot" at runtime.
  fileSystems."/boot" = lib.mkDefault {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  # ---- Self-hosted GitHub Actions runner (aarch64-linux) --------------------
  # Native `services.github-runners` (nixpkgs) — deliberately NOT
  # juspay/github-nix-ci, which wraps this SAME module but couples the token to
  # agenix; this fleet uses sops-nix (and agenix is banned). Registers ONE runner
  # against the nix-config repo so the aarch64-linux CI leg can build on this VM
  # (native, reliable) rather than the flaky Pi.
  #
  # TOKEN: a fine-grained GitHub PAT (repo Administration: read+write) delivered
  # by sops-nix at /run/secrets/gh-runner-token. The runner self-registers with
  # it and refreshes its own registration tokens.
  #
  # SECURITY: `ephemeral = true` — the runner runs ONE job then deregisters; the
  # unit re-registers a fresh runner, so nothing persists between jobs. This repo
  # is PUBLIC: do NOT point fork-PR workflows at this runner. Only wire trusted
  # jobs (push to your own branches) to `runs-on: [self-hosted, aarch64-linux]`.
  # This module only STANDS UP the runner; nix-ci.yml is not rewired to use it yet.
  services.github-runners.nixvm = {
    enable = true;
    url = "https://github.com/ismailkattakath/nix-config";
    tokenFile = config.sops.secrets."gh-runner-token".path;
    ephemeral = true;
    replace = true;
    extraLabels = [
      "nix"
      "nixvm"
    ];
    # On PATH for workflows, beyond the runner's bundled node: nix + git, plus
    # cachix to push build closures to the ismailkattakath cache.
    extraPackages = with pkgs; [
      nix
      git
      cachix
    ];
  };

  # sops-nix: decrypt ../secrets/nixvm.yaml at activation with this host's SSH
  # host key. `gh-runner-token` → /run/secrets/gh-runner-token (root-only 0400),
  # consumed as the runner's tokenFile. Edit: `sops secrets/nixvm.yaml`.
  sops = {
    defaultSopsFile = ../secrets/nixvm.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."gh-runner-token" = {
      restartUnits = [ "github-runner-nixvm.service" ];
    };
  };

  system.stateVersion = "24.05";
}
