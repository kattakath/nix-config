# Unprovisioned aarch64-linux DEV VM — materialised ONLY as the graphical
# `build-vm` variant behind `nix run .#nixvm` (an XFCE desktop in a native
# QEMU/Cocoa window on macOS). There is no installed nixvm and no disk layout to
# provision, no builder VM and no self-hosted runner — CI is GitHub-hosted and
# local aarch64-linux builds use Determinate's native Linux builder (enabled on
# the macos host, see flake.nix). Distinct from `nixpi`, which targets real
# Raspberry Pi 4 hardware via raspberry-pi-nix.
#
# DISPOSABLE, NOT EPHEMERAL — only the Nix STORE is rebuilt per boot
# (useNixStoreImage, below); the ROOT filesystem is a `nixvm.qcow2` that
# qemu-vm.nix creates only if ABSENT and otherwise reuses, so /home and anything
# signed in there survives until the image is deleted. `nix run .#nixvm` pins
# that image to an XDG state dir (the wrapper in modules/parts/packages.nix); a
# hand-run `./result/bin/run-nixvm-vm` instead resolves `./nixvm.qcow2` against
# the CALLER'S working directory, which is how one command grows a second VM.
#
#   nix run .#nixvm                       # builds config.system.build.vm then boots it
#   nixos-rebuild build-vm --flake .#nixvm    # equivalent; ./result/bin/run-nixvm-vm
#
# The runner's QEMU is macOS-native (host.pkgs = aarch64-darwin, set in flake.nix);
# the aarch64-linux guest closure builds on the native Linux builder or is
# substituted from Cachix.
{ lib, darwinPkgs, ... }:
{
  imports = [ ../modules/nixos/desktop-vm.nix ];

  # The `build-vm` variant runs on the aarch64-darwin Mac, so its QEMU runner
  # must be macOS-native: host.pkgs is the pkgs whose qemu the generated
  # run-nixvm-vm executes. `darwinPkgs` arrives through mkNixos specialArgs
  # (modules/parts/compose.nix) and is only forced by the `system.build.vm`
  # path, so the aarch64-linux toplevel eval never pulls in darwin pkgs.
  virtualisation.vmVariant.virtualisation.host.pkgs = darwinPkgs;

  networking.hostName = "nixvm";

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  # DHCP on all interfaces (QEMU user-mode networking hands out a 10.0.2.x lease).
  networking.useDHCP = true;

  # The base (non-vmVariant) config is kept a valid, bootable NixOS system so its
  # toplevel evaluates (CI) and `build.vm` has a coherent substrate — the build-vm
  # variant supplies the actual root qcow2 at run time (overriding fileSystems).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # VirtIO initrd modules — the root disk device class in QEMU.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "ahci"
    "sd_mod"
  ];
  # Serial console — a getty on ttyAMA0 (harmless; the base config exists only as
  # the build-vm eval substrate, so it never actually serves a login).
  systemd.services."serial-getty@ttyAMA0".enable = true;

  # Root filesystem: a PLACEHOLDER that only satisfies NixOS's "you must define a
  # root fileSystem" eval requirement for the base toplevel. There is no on-disk
  # layout anymore (disko was dropped with the installed nixvm); the build-vm
  # variant overrides fileSystems via mkVMOverride (qemu-vm.nix) to boot the
  # persistent nixvm.qcow2 instead.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # ---- Graphical `build-vm` variant -----------------------------------------
  # Everything under virtualisation.vmVariant applies ONLY when building the VM
  # runner (`nix run .#nixvm` / `nixos-rebuild build-vm`), never to the base
  # toplevel. host.pkgs (the QEMU that RUNS the script) is set to aarch64-darwin in
  # flake.nix so the runner is macOS-native.
  virtualisation.vmVariant = {
    # Turn the desktop on for the windowed VM only (the base config is an eval
    # substrate — it has no virtualisation.diskImage and is never booted).
    local.desktopVm.enable = true;

    virtualisation = {
      graphics = true; # open a QEMU display window instead of serial-only
      cores = 4;
      memorySize = 4096; # MiB of guest RAM
      # MiB ceiling for the ROOT filesystem (/home, /var) - not scratch, and not
      # the store: qemu-vm.nix creates nixvm.qcow2 only if ABSENT, so what lands
      # in /home persists. Size it generously ONCE, because raising this later
      # cannot resize an existing image and deleting the image to adopt a new
      # size is exactly what discards the state the headroom was for. Near-free:
      # a qcow2 is lazily allocated (measured 5.7 MiB of real host disk at 8192,
      # 6.9 MiB at 24576).
      diskSize = 24576;
      resolution = {
        x = 1440;
        y = 900;
      };
      # THE GUEST GETS ITS OWN STORE IMAGE, and that is forced by the host being
      # macOS. nixpkgs' qemu-vm.nix replaced 9p with virtiofs, and the generated
      # runner calls `hostPkgs.virtiofsd` for every share it creates. hostPkgs
      # here is aarch64-darwin (set above, so the QEMU window is native Cocoa),
      # and virtiofsd is Linux-only - nixpkgs refuses to evaluate it for
      # aarch64-darwin, which failed `nix flake check` on apps.*.nixvm with
      # "not available on the requested hostPlatform".
      #
      # The share it wanted was the HOST NIX STORE: mountHostNixStore defaults to
      # `!useNixStoreImage && !useBootLoader`, i.e. true. Mounting a macOS host's
      # store into a Linux guest only ever worked over 9p; with 9p gone there is
      # no version of that which works, so the guest carries its own store image
      # instead. Setting this flips mountHostNixStore's default to false, no
      # share is created, and virtiofsd is never forced.
      #
      # Cost: the image holds the closure rather than borrowing the host's, so
      # `nix run .#nixvm` builds more. It builds on the native Linux builder or
      # substitutes from Cachix - the right trade for a hand-booted dev VM. This
      # store image is the ONLY per-boot filesystem here; the root qcow2 is not.
      useNixStoreImage = true;

      # The store was not the only share. qemu-vm.nix also ships two by default -
      # `xchg` (/tmp/xchg) and `shared` (/tmp/shared) - the NixOS TEST driver's
      # conveniences for passing files between a test script and its guest. Each
      # one is a virtiofs share and therefore another `hostPkgs.virtiofsd`, so
      # dropping the store mount alone still failed. This VM is booted by hand
      # from a QEMU window and runs no test script; it has nothing to exchange.
      sharedDirectories = lib.mkForce { };

      # Guest video device X's modesetting driver binds for the desktop, plus
      # the host half of macOS<->guest CLIPBOARD sharing.
      #
      # RAW QEMU ARGS ARE CORRECT HERE — do not "fix" them to an option.
      # `virtualisation.qemu.options` is nixpkgs' own escape hatch
      # (types.listOf types.str, default [ ], nixos/modules/virtualisation/qemu-vm.nix)
      # and it concatenates additively, so this list is the whole device set.
      # Grepped the pinned nixpkgs' nixos/modules/virtualisation/ for "vdagent":
      # ZERO hits — NixOS models only the GUEST side (services.spice-vdagentd,
      # enabled in modules/nixos/desktop-vm.nix). Nothing upstream wires the
      # host chardev, so there is no option to prefer.
      #
      # How the clipboard reaches macOS: qemu 11.1.1's Cocoa UI registers a real
      # QemuClipboardPeer named "cocoa" (ui/cocoa.m), so the native window joins
      # QEMU's clipboard bus; `qemu-vdagent` is compiled in (confirmed with
      # `-chardev help` on the store path this VM runs). `clipboard=on` is
      # REQUIRED — qapi/char.json defaults it off. `name=com.redhat.spice.0` is
      # the fixed protocol contract spice-vdagent listens on, not a free choice.
      #
      # TEXT ONLY. The Cocoa peer carries no image or file clipboard.
      #
      # The virtserialport deliberately carries NO explicit `bus=`. Measured
      # 2026-10-06 against this exact qemu store path, with virtio-gpu-pci also
      # enumerated: both the explicit `bus=virtio-serial0.0` form and this
      # implicit one start cleanly, and `info qtree` shows the implicit port
      # landing on `bus: virtio-serial-bus.0` with chardev=vdagent0 and
      # name=com.redhat.spice.0. Implicit wins on fewer assumptions — it needs
      # no device id and no guess at the bus alias QEMU derives from it.
      qemu.options = [
        "-device virtio-gpu-pci"
        "-chardev qemu-vdagent,id=vdagent0,name=vdagent,clipboard=on"
        "-device virtio-serial-pci"
        "-device virtserialport,chardev=vdagent0,name=com.redhat.spice.0"
      ];
      # NOTE: no explicit `-display` flag — QEMU on macOS defaults to a native
      # Cocoa window. On a Linux host you'd add `-display gtk` here instead.
    };
  };
}
