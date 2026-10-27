# Unprovisioned aarch64-linux HEADLESS DEV VM — materialised ONLY as the
# `build-vm` variant behind `nix run .#nixvm` (a console in a native QEMU/Cocoa
# window on macOS; SSH on 127.0.0.1:2222). There is no installed nixvm, no disk
# layout to provision, no builder VM and no self-hosted runner — CI is GitHub-hosted and
# local aarch64-linux builds use Determinate's native Linux builder (enabled on
# the macos host, see modules/parts/compose.nix). Distinct from `nixpi`, which targets real
# Raspberry Pi 4 hardware via nixos-hardware's raspberry-pi/4.
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
# The runner's QEMU is macOS-native (host.pkgs = aarch64-darwin, set below from compose.nix's darwinPkgs);
# the aarch64-linux guest closure builds on the native Linux builder or is
# substituted from Cachix.
#
# NO GUI, AND NO SWITCH TO TURN ONE ON. The XFCE stack (`local.desktopVm`,
# modules/nixos/desktop-vm.nix, the HM Xft/DPI module, the clipboard/audio QEMU
# args, the polkit rule) sat dormant from 2026-10-06 and was DELETED 2026-10-17;
# git history keeps it (`git log --diff-filter=D -- modules/nixos/desktop-vm.nix`).
# The GUI job moved to the `nixos` host (UTM + GNOME, hosts/nixos.nix).
# Args hold only what THIS level uses — `nix fmt` runs `deadnix --edit`, which prunes the
# rest — so take `pkgs`/`lib` in the inner vmVariant function, not here.
{
  darwinPkgs,
  loginName,
  ...
}:
{
  # ONE `virtualisation.vmVariant` definition in this file, always: it is a module
  # FUNCTION, so a dotted `virtualisation.vmVariant.x = …;` beside it is an
  # "attribute already defined" error at parse time, not a module merge.

  networking.hostName = "nixvm";

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
  # The initrd `terminfo/l/linux` fix for the Mac's case-insensitive store lives
  # in modules/nixos/core.nix (guarded on boot.initrd.systemd.enable).

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

  # ---- Headless `build-vm` variant ------------------------------------------
  # Everything under virtualisation.vmVariant applies ONLY when building the VM
  # runner (`nix run .#nixvm` / `nixos-rebuild build-vm`), never to the base
  # toplevel. host.pkgs (the QEMU that RUNS the script) is set to aarch64-darwin below
  # (compose.nix's darwinPkgs) so the runner is macOS-native.
  # A module FUNCTION, for `lib` (the outer args no longer take it — see the ARGS
  # note above). `virtualisation.vmVariant`'s type comes from `extendModules`
  # (nixpkgs virtualisation/build-vm.nix), so a definition may be a function.
  virtualisation.vmVariant =
    { lib, ... }:
    {
      # ---- BREAK-GLASS CONSOLE ----------------------------------------------
      # SSH on 127.0.0.1:2222 is the only other route in — and this account
      # has NO PASSWORD, so a getty login prompt is unanswerable. If
      # sshd ever fails to start there would be no recovery short of killing
      # QEMU, which is a power-pull for a durable qcow2.
      # `services.getty.autologinUser` (nixos/modules/services/ttys/getty.nix:62,
      # `nullOr str`) drops straight to a shell on the console instead.
      # `loginName` comes from identityArgs — never a literal.
      services.getty.autologinUser = loginName;

      virtualisation = {
        # The runner runs ON the aarch64-darwin Mac, so its QEMU must be
        # macOS-native: host.pkgs is the pkgs whose qemu the generated
        # run-nixvm-vm executes. `darwinPkgs` arrives through mkNixos
        # specialArgs (modules/parts/compose.nix) and is only forced by the
        # `system.build.vm` path, so the aarch64-linux toplevel eval never
        # pulls in darwin pkgs.
        host.pkgs = darwinPkgs;

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
        # THE GUEST CARRIES ITS OWN STORE IMAGE.
        #
        # CORRECTION 2026-10-06 — the reason recorded here until today was WRONG.
        # It said nixpkgs implements every share via virtiofs and that
        # `hostPkgs.virtiofsd` is Linux-only, so NO share can exist on a macOS
        # host. The second half is true; the first is not. At the pinned nixpkgs,
        # nixos/modules/virtualisation/qemu-vm.nix reads
        #     useVirtiofs = hostPkgs.stdenv.hostPlatform.isLinux;
        # which is FALSE here, so shares fall back to `-virtfs local,…` 9p
        # plus a guest mount with `fsType = "9p"`. Measured against the
        # qemu store path this runner executes: `-fsdev local,id=x help` lists the
        # security models and `-device help` lists virtio-9p-pci. SHARES WORK ON
        # THIS HOST — there is simply NONE CONFIGURED. One was built on 2026-10-06
        # (the operator's WireGuard confs, read-only at /etc/wireguard) and he
        # reverted it the same day: he wants no conf provisioning into this VM.
        # Keep the fact; do not reinstate the false impossibility claim.
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

        # ---- WRITABLE STORE. WITHOUT THIS, NIX IS ENTIRELY BROKEN IN THE GUEST --
        # NOT an optimisation and not a preference — the line above silently
        # turned nix off, through TWO layers of inherited defaults that nobody
        # chose:
        #   `writableStore`      default = cfg.mountHostNixStore   (qemu-vm.nix)
        #   `mountHostNixStore`  default = !useNixStoreImage && !useBootLoader
        # So `useNixStoreImage = true` forces mountHostNixStore false, which drags
        # writableStore to FALSE by inheritance. Confirmed by evaluating this very
        # config before the fix: writableStore = false, mountHostNixStore = false.
        #
        # WHAT THAT COSTS. With writableStore false, /nix/store is a BIND of
        # /nix/.ro-store, an erofs mounted `ro` (qemu-vm.nix's
        # `virtualisation.fileSystems`) — and
        # `findmnt /nix/store` in the guest confirmed `erofs ro,relatime`. The
        # nix-daemon then dies on its first write:
        #   unexpected Nix daemon error: error: creating directory
        #   "/nix/store/.links": Read-only file system
        # With it true, the SAME stanza switches to overlayfs —
        # lowerdir=/nix/.ro-store, upperdir=/nix/.rw-store/upper,
        # workdir=/nix/.rw-store/work — and /nix/.rw-store is a tmpfs
        # (writableStoreUseTmpfs defaults true). So the
        # per-boot-fresh-store design SURVIVES: the upper layer is RAM and is
        # discarded every boot. Nothing durable changes.
        #
        # THIS VM WAS UPSTREAM'S OWN DOCUMENTED FAILING CASE, which is the
        # strongest argument against ever "simplifying" this line away.
        # nixos/tests/qemu-vm-store.nix declares a node
        #   imageReadOnly = { useNixStoreImage = true; writableStore = false; }  (:26-28)
        # and asserts `imageReadOnly.fail(build_derivation)` (:56), against
        #   imageWritable = { useNixStoreImage = true; writableStore = true; }   (:21-23)
        # asserted `imageWritable.succeed(build_derivation)` (:51). We had
        # imageReadOnly's exact pair.
        #
        # THE FULL CAUSAL CHAIN, measured over SSH in a clean guest 2026-10-06 —
        # it took three agents and a live shell to connect these:
        #   read-only store -> every nix operation fails -> home-manager-ismail
        #   .service fails on EVERY boot ("cannot open connection to remote store
        #   'daemon'") -> ~/.zshrc and ~/.zshenv are never written -> an
        #   interactive zsh finds no startup files -> zsh-newuser-install.
        # The wizard was never a zsh or home-manager bug. It was this line.
        #
        # DETERMINATE IS NOT THE CAUSE — do not go looking there. Upstream's test
        # fails identically with stock nix, and the daemon was healthy: it logged
        # `accepted connection from pid 1456, user ismail (trusted)` and died only
        # on the write. The `Authentication failure, s: Permanent` FlakeHub line in
        # the same journal is unrelated noise (no token in a disposable guest).
        #
        # RULED OUT, so nobody retries them:
        #   * `useNixStoreImage = false` + a 9p host store — loses the fresh-store
        #     design AND exposes every store path to the macOS case-insensitive
        #     `~nix~case~hack~` collision class, not just the one terminfo entry
        #     already worked around in modules/nixos/core.nix.
        #   * swapping Determinate for upstream nix — upstream's own test proves
        #     the daemon is irrelevant.
        #   * skipping nix during HM activation — home-manager's `activate` calls
        #     `nix-store --realise` and `nix-env --profile --set` unconditionally,
        #     so this is impossible without forking home-manager.
        writableStore = true;

        # NO SHARES AT ALL, and `lib.mkForce` is what keeps it that way: without
        # it upstream's own two defaults come back — `xchg` (/tmp/xchg) and
        # `shared` (/tmp/shared), the NixOS TEST driver's conveniences for passing
        # files between a test script and its guest (qemu-vm.nix's own
        # `virtualisation.sharedDirectories` definition). This
        # VM is booted by hand from a QEMU window, runs no test script, and has
        # nothing to exchange.
        sharedDirectories = lib.mkForce { };

        # RAW QEMU ARGS ARE CORRECT HERE — `virtualisation.qemu.options` is
        # nixpkgs' own escape hatch (types.listOf types.str, additive).
        #
        # ---- USB PASSTHROUGH: NOT AVAILABLE — decided 2026-10-06, do not re-attempt
        # NO `qemu.options` LINE FIXES THIS. That is the whole point of the note:
        # `usb-host` IS compiled in (the binary links libusb-1.0.30 and carries
        # host-libusb.c strings — a real backend, not a stub), but libusb on macOS
        # can only capture a WHOLE device and needs an Apple CAPTURE ENTITLEMENT to
        # detach a kernel driver. Apple's class drivers claim mass storage, HID,
        # audio, video and CDC-serial, i.e. everything worth forwarding.
        # QEMU's one FIDO-specific escape hatch is absent in this build, measured:
        # `-device u2f-passthru,help` -> "Device 'u2f-passthru' not found".
        # USB/IP is structurally impossible host-side: `usbipd-mac`'s DriverKit
        # USB-transport entitlement was DENIED by Apple 2026-02-25 (redirected to
        # the *import* entitlement, the opposite capability), and nixpkgs' `usbip`
        # is the Linux CLIENT half only, built from kernel.src.
        # VirtualHere ($49) is the obvious-looking cheap fix and does NOT work: its
        # macOS server excludes HID, audio, video and Bluetooth by Apple policy
        # post-10.15, and a YubiKey's HID interface — the device that prompted the
        # ask — specifically fails.
        # The only working routes LEAVE QEMU: Parallels (~$100, field-proven
        # YubiKey->Linux on Apple Silicon) or UTM (free; PR #7877 merged
        # 2026-09-18 on macOS 27's VZUSBPassthroughDevice, but issue #7914
        # `VZErrorDomain error -6` on any device assign was open at writing).
        # A move keeps the NixOS guest, sshd, the HM profile and the PGP stack, and
        # LOSES `nix run .#nixvm` and the declarative `vmVariant` round-trip.
        # OPERATOR'S DECISION 2026-10-06: keep nixvm as it is, accept no USB.
        # (GPG and SSH specifically need no passthrough.)
        # THE GPU DEVICE IS LOAD-BEARING HEADLESS.
        # `graphics = true` does NOT add a framebuffer — measured in the pinned
        # qemu-vm.nix, which only withholds `-nographic` and reorders the
        # kernel `console=` list (`qemu.consoles`). aarch64 `virt` has no built-in VGA, so
        # without this device the Cocoa window would open BLANK and the
        # break-glass console above would be invisible.
        qemu.options = [ "-device virtio-gpu-pci" ];
        # NOTE: no explicit `-display` flag — QEMU on macOS defaults to a native
        # Cocoa window. On a Linux host you'd add `-display gtk` here instead.
      };

      # ---- WireGuard: ADDED AND REMOVED THE SAME DAY (2026-10-06) ----------
      # It WAS here: `environment.systemPackages = [ pkgs.wireguard-tools ]` plus
      # `boot.kernelModules = [ "wireguard" ]`, tools-only with no conf ever
      # provisioned (the conf-share version was built and reverted earlier the
      # same day). Both lines are gone now that this VM went HEADLESS and its
      # purpose narrowed — operator's call. Nothing replaced them.
      #
      # `boot.kernelModules` and `environment.systemPackages` are not merely
      # emptied, they are ABSENT here: `wireguard` and `wireguard-tools` were the
      # only entries this file contributed. `atkbd` and `loop` still show up in
      # the evaluated `boot.kernelModules` and are UPSTREAM's
      # (nixos/modules/system/boot/kernel.nix) — zero occurrences in this repo —
      # so they were deliberately left alone.
      #
      # WHY SOMEONE WILL WANT TO RE-ADD THIS, and why they should read on first:
      # hosts/macos.nix (§ Brews) deliberately ships NO `wg`/`wg-quick` CLI,
      # because a botched tunnel means no internet on the SOLE client Mac — confs
      # are synced for IMPORT into the GUI app and never run from a shell. That
      # rationale is still live, so "put WireGuard in the VM instead" is the
      # natural next thought. It was tried here and dropped; this is not an
      # oversight and the Mac's posture is not the reason to redo it.
      #
      # KNOCK-ON, recorded honestly: WireGuard was the main thing in this guest
      # that needed a REAL KERNEL — an in-tree module plus NET_ADMIN. With it
      # gone, nothing obviously left here requires a VM rather than a container.
      # The substrate question was settled for the GUI job: hosts/nixos.nix's header.

      # ---- SSH from the Mac: 127.0.0.1:2222 -> guest 22 ------------------------
      # `ssh -p 2222 ismail@localhost` from the Mac. The operator's key is already
      # in the guest (modules/parts/hosts.nix passes operatorSshKey to nixvm) and
      # auth stays KEY-ONLY: modules/nixos/core.nix sets PasswordAuthentication
      # and KbdInteractiveAuthentication false and PermitRootLogin "no", and
      # nothing here relaxes any of them.
      #
      # ALL THREE CHANGES ARE REQUIRED TOGETHER. Each one alone is inert:
      #   1. The forward alone fails on the BIND. QEMU's SLiRP delivers a
      #      hostfwd to the guest's NIC address (10.0.2.15 under user-mode
      #      networking), and core.nix binds sshd to 127.0.0.1 + ::1 only — an
      #      sshd on loopback never sees a packet addressed to the NIC.
      #   2. The widened bind alone fails on the FIREWALL. core.nix sets
      #      `openssh.openFirewall = false` and the base firewall opens no TCP
      #      port globally, so a correctly-bound sshd still gets the SYN dropped.
      #   3. The open port alone forwards nothing — there is no listener on the
      #      Mac without the hostfwd.
      #
      # WHY HERE AND NOT IN core.nix: that module's default is what keeps nixvm's
      # BASE toplevel — the thing `nix flake check` builds, and the thing every
      # `lib.mkNixos` consumer inherits — loopback-only. Its own comment says "do
      # not relax it HERE" for exactly that reason. `virtualisation.vmVariant`
      # applies only to `system.build.vm`, so this reaches the hand-booted QEMU
      # runner and nothing else: not the base config, not `nixpi`, not a consumer.
      #
      # EXPOSURE IS THE MAC'S LOOPBACK ONLY. `host.address = "127.0.0.1"` is
      # emitted verbatim into the qemu arg (`hostfwd=${proto}:${host.address}:…`,
      # qemu-vm.nix), so SLiRP binds that address alone — nothing on the LAN
      # can reach port 2222. Leaving `host.address` at its `""` default would bind
      # every Mac interface, which is NOT what was approved. The widened guest
      # bind is harmless on its own merits too: the guest's only NIC is a SLiRP
      # user-mode device with no route in except this one forward.
      #
      # KNOWN ANNOYANCE — deleting the qcow2 regenerates the guest host key, so
      # the next `ssh -p 2222 localhost` warns REMOTE HOST IDENTIFICATION HAS
      # CHANGED. Fix: `ssh-keygen -R "[localhost]:2222"` to drop the stale entry
      # from ~/.ssh/known_hosts. Deliberately NO Mac-side ~/.ssh/config entry for
      # this host — that is a different layer and was not asked for.
      #
      # upstream option virtualisation.forwardPorts exists -> using it
      # (qemu-vm.nix, with `host.address`). No hand-rolled -netdev/hostfwd.
      virtualisation.forwardPorts = [
        {
          from = "host";
          proto = "tcp";
          host = {
            address = "127.0.0.1";
            port = 2222;
          };
          guest.port = 22;
        }
      ];

      # mkForce on BOTH, because core.nix ASSIGNS both (not mkDefault) — a plain
      # definition here would be a conflict, not an override. `openFirewall` is
      # the upstream knob core.nix itself names as the supported way to control
      # this (its `services.openssh.openFirewall` comment), so it is preferred
      # over hand-adding
      # `networking.firewall.allowedTCPPorts = [ 22 ]`: sshd's own module derives
      # the port list from `cfg.ports`, which stays correct if the port ever moves.
      # IPv4 wildcard ONLY, and deliberately not the `0.0.0.0` + `::` pair nixpi
      # uses: QEMU's SLiRP forwards IPv4 exclusively ("Currently QEMU supports
      # only IPv4 forwarding", qemu-vm.nix forwardPorts description), so a v6
      # bind here would listen for traffic that cannot arrive. Nothing in this
      # guest dials localhost:22 over v6 either. `port` is omitted on purpose —
      # see core.nix's `listenAddresses` comment for the `ListenAddress ::1:22`
      # parse trap that costs.
      services.openssh.listenAddresses = lib.mkForce [
        { addr = "0.0.0.0"; }
      ];
      services.openssh.openFirewall = lib.mkForce true;
    };
}
