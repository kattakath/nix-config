# NixOS sandbox VM (UTM `virt` machine / QEMU HVF) — UEFI + systemd-boot +
# VirtIO. Architecture is chosen in flake.nix (`mkNixos { system = … }`), so
# this file is arch-agnostic and backs the aarch64 UTM VM today. Distinct from
# `nixpi`, which targets real Raspberry Pi 4 hardware via raspberry-pi-nix (SD
# image). The base config stays MINIMAL — boots, serial console, SSH, disko; no
# desktop in the installed image.
#
# GUI WITHOUT UTM: the graphical desktop lives ONLY in the `build-vm` variant
# (virtualisation.vmVariant, below) via the opt-in modules/nixos/desktop-vm.nix.
# Build+run a windowed QEMU VM straight from the flake — no UTM, no VM config
# maintained outside Nix:
#   nix run .#nixvm-gui                       # builds config.system.build.vm then boots it
#   nixos-rebuild build-vm --flake .#nixvm    # equivalent; ./result/bin/run-nixvm-vm
# The runner's QEMU is macOS-native (host.pkgs = aarch64-darwin, set in
# flake.nix), but the GUEST is aarch64-linux, so building it on the Mac needs an
# aarch64-linux builder. On the `macos` host that means Determinate's native
# Linux builder — a FlakeHub/account feature enabled via https://dtr.mn/features
# (verify: `determinate-nixd version`), NOT a flake setting and NOT nix-darwin's
# `nix.linux-builder` (which needs nix.enable = true; Determinate disables it —
# nix-darwin#1505). Until it is enabled, build the guest on any aarch64-linux
# builder or pull from Cachix. The installed image stays headless.
#
# Install (from live ISO — single command):
#   nix --extra-experimental-features 'nix-command flakes' run github:ismailkattakath/nix-config#nixvm
{
  lib,
  config,
  pkgs,
  ...
}:
let
  # The self-hosted GitHub Actions runner is GATED on its agenix token existing.
  # Flakes only see committed files, so `pathExists` is false until
  # secrets/gh-runner-token-nixvm.age is created + committed — the config thus
  # evaluates cleanly now (runner absent) and the runner activates automatically
  # once the operator lands the secret. See the runner block near the bottom.
  runnerTokenFile = ../secrets/gh-runner-token-nixvm.age;
  runnerEnabled = builtins.pathExists runnerTokenFile;
in
{
  imports = [ ../modules/nixos/desktop-vm.nix ];

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

  # ---- Graphical `build-vm` variant (GUI without UTM) -----------------------
  # Everything under virtualisation.vmVariant applies ONLY when building the VM
  # runner (`nix run .#nixvm-gui` / `nixos-rebuild build-vm`), never to the
  # installed image or the CI runner. host.pkgs (the QEMU that RUNS the script)
  # is set to aarch64-darwin in flake.nix so the runner is macOS-native.
  virtualisation.vmVariant = {
    # Turn the desktop on for the windowed VM only (base nixvm stays headless).
    services.desktopVm.enable = true;

    virtualisation = {
      graphics = true; # open a QEMU display window instead of serial-only
      cores = 4;
      memorySize = 4096; # MiB of guest RAM
      diskSize = 8192; # MiB writable scratch overlay for the throwaway session
      resolution = {
        x = 1440;
        y = 900;
      };
      # Guest video device X's modesetting driver binds for the desktop.
      qemu.options = [ "-device virtio-gpu-pci" ];
      # NOTE: no explicit `-display` flag — QEMU on macOS defaults to a native
      # Cocoa window. On a Linux host you'd add `-display gtk` here instead.
    };
  };

  # ---- Self-hosted GitHub Actions runner (github-nix-ci) --------------------
  # NixOS-native runner via `services.github-runners` (wrapped by github-nix-ci).
  # Works here because nixvm is plain NixOS — unlike the macos host, where
  # Determinate sets nix.enable = false and forces the hand-rolled launchd runner
  # (modules/darwin/github-runner.nix). github-nix-ci runs the runner as the
  # `github-runner` system user; with noDefaultLabels its labels are `nixvm` +
  # `aarch64-linux`, so CI targets it with `runs-on: [nixvm, aarch64-linux]`.
  #
  # OPERATOR STEPS to bring it online (secrets/ is not editable from this repo
  # tooling — do these by hand):
  #   1. Mint a GitHub PAT (repo scope + manage self-hosted runners) for
  #      ismailkattakath/nix-config.
  #   2. Add nixvm's SSH host key + the operator key as recipients for
  #      `gh-runner-token-nixvm.age` in secrets/secrets.nix.
  #   3. `agenix -e secrets/gh-runner-token-nixvm.age`, paste the PAT, save.
  #   4. Commit the .age — `runnerEnabled` flips true; `nixos-rebuild switch
  #      --flake .#nixvm` on a RUNNING nixvm registers the ephemeral runner.
  #   5. Flip the aarch64-linux CI legs to `runs-on: [nixvm, aarch64-linux]`
  #      (keep the fork guard — the repo is public).
  age.secrets = lib.mkIf runnerEnabled {
    "gh-runner-token-nixvm" = {
      file = runnerTokenFile;
      owner = "github-runner"; # user github-nix-ci runs the runner as (Linux)
    };
  };
  services.github-nix-ci.personalRunners = lib.mkIf runnerEnabled {
    "ismailkattakath/nix-config" = {
      num = 1;
      tokenFile = config.age.secrets."gh-runner-token-nixvm".path;
    };
  };
  # github-nix-ci's runner PATH ships nix/nixci/cachix/jq but NOT git, which
  # actions/checkout and the nix-ci "git add -A" git-purity step both require.
  services.github-nix-ci.runnerSettings.extraPackages = [ pkgs.git ];

  system.stateVersion = "24.05";
}
