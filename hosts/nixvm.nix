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
{
  lib,
  pkgs,
  darwinPkgs,
  ...
}:
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
  # THE INITRD'S `linux` TERMINFO ENTRY IS UNREACHABLE ON THIS MAC, so drop it.
  # Without this, EVERY build of nixvm (base toplevel AND build-vm) dies in
  # `initrd-linux-*` with:
  #   Error: failed to get symlink metadata for ".../ncurses-*/share/terminfo/l/linux"
  #
  # Three facts compose into that, and none of them is a nixpkgs bug:
  #   1. This Mac's "Nix Store" APFS volume is CASE-INSENSITIVE, so ncurses'
  #      `terminfo/L/` and `terminfo/l/` are one directory (same inode).
  #   2. Nix's `use-case-hack` resolves the collision by RENAMING one on disk —
  #      the lowercase tree becomes `l~nix~case~hack~1/`. Nix un-hacks at the NAR
  #      layer, so `nix store verify` passes and the damage is invisible to it.
  #   3. nixpkgs' nixos/modules/config/terminfo.nix adds four
  #      `boot.initrd.systemd.contents` entries UNCONDITIONALLY and offers no
  #      switch for them. makeInitrdNG resolves the literal path `terminfo/l/linux`
  #      — outside the NAR layer — and finds nothing. The hacked names leak into
  #      Determinate's native Linux builder too, so building there does not help.
  #
  # ONLY `l/linux` collides: measured on this store, `v/vt100`, `v/vt102` and
  # `v/vt220` all resolve (there is no uppercase `V/` tree upstream), so they are
  # left alone rather than disabled for symmetry.
  #
  # `enable = false` is the real option surface — the `contents` submodule carries
  # a per-entry `enable` (confirmed by evaluating this very config:
  # `...contents."/etc/terminfo/l/linux"` has attrs dlopen/enable/source/target/text).
  # Deliberately NOT `lib.mkForce { }` on the whole attrset (other modules
  # contribute ~28 entries, including /init and /lib), and deliberately NOT
  # re-pointed at `l~nix~case~hack~1/linux` — that path is an artefact of THIS
  # filesystem and would not exist on a case-sensitive store.
  #
  # COST: the initrd console loses the `linux` terminfo entry. That matters only
  # to a full-screen program on the early-boot console; nothing here runs one.
  # SCOPE: this patches this instance, not the bug class. Every aarch64-linux
  # build on this Mac that resolves a mixed-case store path by literal name is
  # still exposed. The durable fixes are a case-sensitive store volume (reformat)
  # or substituting the closure from CI — neither taken, operator's call 2026-10-06.
  boot.initrd.systemd.contents."/etc/terminfo/l/linux".enable = false;

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
      # THE GUEST CARRIES ITS OWN STORE IMAGE.
      #
      # CORRECTION 2026-10-06 — the reason recorded here until today was WRONG,
      # and it was wrong in a way that forbade a feature. It said nixpkgs had
      # replaced 9p with virtiofs for every share and that `hostPkgs.virtiofsd`
      # is Linux-only, so NO share can exist on a macOS host. The second half is
      # true; the first is not. At the pinned nixpkgs (44a91898)
      # nixos/modules/virtualisation/qemu-vm.nix:27 reads
      #     useVirtiofs = hostPkgs.stdenv.hostPlatform.isLinux;
      # which is FALSE here, so shares fall back to `-virtfs local,…` 9p (:1309)
      # plus a guest mount with `fsType = "9p"` (:1405). Measured against the
      # qemu store path this runner executes: `-fsdev local,id=x help` lists the
      # security models and `-device help` lists virtio-9p-pci. SHARES WORK ON
      # THIS HOST — sharedDirectories below now uses one.
      #
      # So this setting stays, for a narrower and honest reason: it is the
      # configuration this VM is measured booting with, and it also flips
      # `mountHostNixStore`'s default (`!useNixStoreImage && !useBootLoader`) to
      # false. Mounting a macOS host's /nix/store into an aarch64-linux guest
      # over 9p has never been tried here — this is an untested alternative left
      # unadopted, NOT a claim that it cannot work.
      #
      # Cost: the image holds the closure rather than borrowing the host's, so
      # `nix run .#nixvm` builds more. It builds on the native Linux builder or
      # substitutes from Cachix — the right trade for a hand-booted dev VM. This
      # store image is the ONLY per-boot filesystem here; the root qcow2 is not.
      useNixStoreImage = true;

      # ONE share: the operator's WireGuard confs, READ-ONLY at the guest's
      # /etc/wireguard, which is the directory `wg-quick up <name>` resolves a
      # BARE interface name against.
      #
      # `lib.mkForce` IS LOAD-BEARING — do not drop it. Without it upstream's own
      # two defaults come back: `xchg` (/tmp/xchg) and `shared` (/tmp/shared),
      # the NixOS TEST driver's conveniences for passing files between a test
      # script and its guest (qemu-vm.nix:1235-1250). This VM is booted by hand
      # from a QEMU window, runs no test script, and has nothing to exchange.
      #
      # `source` is `types.str` and upstream's own description says it "can be a
      # shell variable" (:588) — its own `xchg` default is literally
      # `"$TMPDIR"/xchg`. The value is interpolated UNQUOTED into the generated
      # runner script's qemu command line (:360), so `$HOME` expands on the Mac
      # at launch. Pointing at the operator-maintained source directory keeps ONE
      # source of truth with the Darwin side: modules/home/wireguard-configs.nix
      # syncs into ~/.config/wireguard FROM this very directory.
      #
      # WHY A MOUNT AND NOT `networking.wg-quick.interfaces`:
      # grepped the pinned nixpkgs' nixos/modules/services/networking/wg-quick.nix
      # — the option DOES exist, and the two objections usually raised against it
      # do not survive reading it: it has an `autostart` toggle (:53) and a
      # `privateKeyFile` escape hatch (:88), so neither "nothing may autostart"
      # nor "the confs hold private keys" disqualifies it.
      #
      # The disqualifier is different: using it means re-expressing each conf as
      # Nix ATTRIBUTES — publicKey, endpoint, allowedIPs — and THIS REPO IS
      # PUBLIC, so the VPN peer topology would land in git history permanently
      # and irretrievably. The private overlay flake that could once have held
      # such values was retired 2026-09-15, so there is nowhere to hide it.
      # Confs therefore stay OPAQUE FILES reached by a mount: nothing here
      # parses, evaluates or re-emits their content, and no byte of them enters
      # /nix/store. (`environment.etc."wireguard/…"` is the same trap — it
      # symlinks a world-readable store path, so it is ruled out too.)
      #
      # Read-only on both sides: `writable = false` emits `readonly=on` in the
      # -virtfs arg (:1310) and `ro` in the guest mount options (:1418). 9p
      # `security_model=none` serves as the host user who owns the files, so the
      # mode-600 confs are readable in the guest by root — which is who
      # `wg-quick` runs as anyway. Expect host uids (501) in the guest's `ls -l`.
      sharedDirectories = lib.mkForce {
        wireguard = {
          source = ''"$HOME"/.local/share/wireguard-configs'';
          target = "/etc/wireguard";
          writable = false;
        };
      };

      # BOOT-STALL GUARD. Every sharedDirectories entry gets
      # `neededForBoot = true` (qemu-vm.nix:1406), so if the host source
      # directory is ever absent, renamed or moved, the guest can stall in the
      # emergency shell with no console the operator wants to debug. `nofail`
      # makes the mount best-effort instead: no confs, but a VM that boots.
      #
      # It is appended HERE, to `virtualisation.fileSystems`, and not to
      # `fileSystems` — qemu-vm.nix:1396 publishes the latter wrapped in
      # `mkVMOverride` (priority 10), and list merging keeps only the
      # highest-priority definitions, so a normal-priority append to
      # `fileSystems` would be silently DISCARDED rather than concatenated.
      # `virtualisation.fileSystems` is declared as `options.fileSystems` (:463)
      # and merges at normal priority with upstream's own definition, which is
      # why no mkForce/mkAfter is needed.
      #
      # IT WORKS BECAUSE THIS INITRD IS SYSTEMD'S. neededForBoot also stamps
      # `x-initrd.mount` on the mount, and the SCRIPTED stage-1 would not honour
      # `nofail` at all — stage-1-init.sh strips every `x-` option and its
      # mountFS calls `fail` (an emergency shell) when `mount` returns non-zero.
      # systemd-fstab-generator is what reads `nofail` and makes the unit
      # best-effort, and `boot.initrd.systemd.enable` evaluates TRUE here
      # (measured on this config, 2026-10-06). If that ever flips back to the
      # scripted initrd, this guard silently stops guarding.
      fileSystems."/etc/wireguard".options = [ "nofail" ];

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

    # ---- WireGuard: TOOLS PRESENT, NOTHING RUNNING ---------------------------
    # Lives HERE and not in modules/nixos/desktop-vm.nix because that module is
    # scoped "XFCE desktop + guest integration" and WireGuard is neither — and
    # because inside `virtualisation.vmVariant` it reaches nothing else: this
    # file is imported only by nixvm's own mkNixos call, and the vmVariant layer
    # applies only to `system.build.vm`, so neither `nixpi` (the live Pi, whose
    # closure must stay lean) nor `macos` nor even nixvm's base toplevel sees it.
    #
    # macos is DELIBERATELY UNTOUCHED: it manages WireGuard through the GUI app
    # only, with no wg/wg-quick CLI on PATH, so no shell there can bring a
    # tunnel up on the sole client Mac (hosts/macos.nix, § Brews).
    #
    # NOTHING AUTOSTARTS, ON PURPOSE. No systemd unit, no wg-quick service, no
    # activation script touches a tunnel — `networking.wg-quick.interfaces` is
    # ruled out for the reason recorded above, and nothing replaces it. The
    # confs are simply PRESENT at /etc/wireguard and the operator brings one up
    # by hand: `sudo wg-quick up <name>` (a bare interface name; see the share).
    #
    # The kernel module is listed because we are NOT using NixOS's wg-quick
    # unit, which is what would otherwise `modprobe wireguard` defensively
    # (wg-quick.nix). The guest kernel is 6.x, so `wireguard` is in-tree.
    environment.systemPackages = [ pkgs.wireguard-tools ];
    boot.kernelModules = [ "wireguard" ];
  };
}
