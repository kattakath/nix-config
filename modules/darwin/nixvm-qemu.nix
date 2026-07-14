# nixvm — the aarch64-linux CI runner VM, as a plain QEMU/HVF launchd daemon.
#
# WHY THIS EXISTS (and why it is NOT UTM any more)
# nixvm's only job is to be the `aarch64-linux` self-hosted runner that
# .github/workflows/nix-ci.yml targets with `runs-on: [nixvm, aarch64-linux]`.
# It used to be a UTM VM. A macOS reset proved that unworkable: UTM cannot be
# provisioned from the CLI (utmctl never sees a hand-authored bundle, and the
# osascript fallback is blocked by TCC — error -1728, a permission that cannot be
# granted programmatically). UTM was never the VM anyway; it is a GUI wrapper
# around QEMU. So we run QEMU directly and keep the whole thing declarative.
#
# Linux on Apple Silicon REQUIRES virtualisation — there is no "NixOS on the bare
# metal" option short of Asahi replacing macOS. What we can drop is every layer
# above QEMU: no UTM, no Docker Desktop, no devcontainer, no prebuilt qcow2, no
# GUI, and no TCC prompts. nixpkgs' qemu is codesigned with
# com.apple.security.hypervisor, so `-accel hvf` gives real hardware acceleration.
#
# THE DISK IS NOT MANAGED BY NIX. This module only *runs* the VM; it does not
# create it. The qcow2 and the pre-generated SSH host key are provisioned by the
# nixvm-qemu-provision skill (nixos-anywhere --build-on remote --extra-files).
# That host key is load-bearing: agenix decrypts gh-runner-token-nixvm.age with
# it, so the recipient in secrets/secrets.nix must match the key planted at
# install time or the runner silently never starts. See docs/nixvm-qemu-runbook.md.
{
  config,
  lib,
  pkgs,
  userName,
  ...
}:
let
  cfg = config.services.nixvm-qemu;

  # /var/lib, NOT the user's home. A 50 GB CI runner VM owned by a launchd DAEMON
  # has no business living inside someone's home directory: it makes the whole CI
  # runner a casualty of any account change, and deleting the user would delete
  # the VM. Keeping it under /var/lib means a user rename/removal only changes
  # ownership, never the path.
  vmDir = "/var/lib/nixvm";
  disk = "${vmDir}/disk.qcow2";
  efivars = "${vmDir}/efivars.fd";

  # Boot only from the disk. The installer ISO is deliberately NOT attached: once
  # NixOS is installed, leaving the CD in makes EDK2 prefer it and the VM
  # reinstalls/loops instead of booting the system you just built.
  qemuArgs = [
    "${pkgs.qemu}/bin/qemu-system-aarch64"
    "-M"
    "virt"
    "-accel"
    "hvf"
    "-cpu"
    "host"
    "-smp"
    (toString cfg.vcpus)
    "-m"
    (toString cfg.memoryMiB)
    "-drive"
    "if=pflash,format=raw,readonly=on,file=${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd"
    "-drive"
    "if=pflash,format=raw,file=${efivars}"
    "-drive"
    "if=virtio,format=qcow2,file=${disk}"
    # User-mode networking: outbound works, and the guest's sshd is reachable at
    # localhost:${toString cfg.sshPort}. No vmnet — that needs root and an
    # entitlement, and the runner only ever makes OUTBOUND calls to GitHub.
    "-netdev"
    "user,id=n0,hostfwd=tcp::${toString cfg.sshPort}-:22"
    "-device"
    "virtio-net-pci,netdev=n0"
    "-display"
    "none"
    "-serial"
    "file:${vmDir}/serial.log"
  ];
in
{
  options.services.nixvm-qemu = {
    enable = lib.mkEnableOption "the nixvm aarch64-linux CI runner VM (headless QEMU/HVF)";

    vcpus = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = ''
        vCPUs given to the guest. The Mac is an M3 Pro: 12 cores (6 performance +
        6 efficiency). Do NOT set this to 12 — vCPUs are just threads competing
        with macOS and your own work, and the guest would size `nix build -j` to
        match and thrash the host. 8 leaves real headroom.
      '';
    };

    memoryMiB = lib.mkOption {
      type = lib.types.int;
      default = 16384; # 16 GiB of the host's 36 GiB
      description = "Guest RAM in MiB. Fixed allocation, so leave the host plenty.";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "Host port forwarded to the guest's sshd (user-mode networking).";
    };
  };

  config = lib.mkIf cfg.enable {
    launchd.daemons.nixvm-qemu = {
      # A DAEMON, not a user agent: the CI runner must come up on boot without
      # anyone logging in. It runs AS the user (HVF needs no root — only the
      # hypervisor entitlement, which nixpkgs' qemu binary already carries), but
      # its state lives in /var/lib/nixvm, so the VM outlives any one account.
      serviceConfig = {
        ProgramArguments = qemuArgs;
        UserName = userName;
        RunAtLoad = true;
        KeepAlive = true; # a crashed VM is a dead CI runner; always bring it back
        StandardOutPath = "${vmDir}/qemu.out.log";
        StandardErrorPath = "${vmDir}/qemu.err.log";
        WorkingDirectory = vmDir;
        ProcessType = "Adaptive";
      };
    };

    # Own the state dir on every activation. This is what lets the VM survive a
    # user rename/removal: the PATH is fixed (/var/lib/nixvm) and only the owner
    # follows userName, so switching accounts is a chown — not a 50 GB migration
    # and not a destroyed CI runner.
    system.activationScripts.extraActivation.text = lib.mkAfter ''
      mkdir -p ${vmDir}
      chown -R ${userName}:staff ${vmDir}
      chmod 700 ${vmDir}

      # Fail loudly if the VM was never provisioned, instead of letting launchd
      # crash-loop QEMU against a missing disk forever.
      if [ ! -f "${disk}" ]; then
        echo "warning: services.nixvm-qemu is enabled but ${disk} does not exist."
        echo "         nixvm has not been provisioned on this Mac yet — the launchd"
        echo "         daemon will keep restarting QEMU until it is. Provision with"
        echo "         the nixvm-qemu-provision skill (see docs/nixvm-qemu-runbook.md)."
      fi
    '';
  };
}
