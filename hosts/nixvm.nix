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
      # ---- RESOLUTION: 1920x1440. THE MODE LIST IS A FIXED TABLE -----------
      # A GREEN BUILD IS NOT ACCEPTANCE HERE. Only `xrandr` inside a booted
      # guest is; this block has been wrong twice on a green build.
      #
      # WHY AN ARBITRARY NUMBER CANNOT WORK, which is the counter-intuitive part:
      # QEMU's EDID generator carries a HARDCODED 23-ENTRY `modes[]` TABLE
      # (hw/display/edid-generate.c:14-45). `xres`/`yres` do NOT add to it —
      # they only build the single "preferred timing" DTD, from a formula whose
      # own source comment says it will "pull some realistic looking timings out
      # of thin air" (:68-82).
      #
      # AND THAT FORMULA IS ITSELF OUT OF RANGE. Proof from this VM's own log,
      # one boot, both lines present:
      #   (II) Not using mode "1920x1200" (hsync out of range)
      #   (II) Output Virtual-1 using initial mode 1920x1200 +0+0
      # The configured mode survived only because it is ALSO a table entry,
      # where Xorg computes proper VESA timings itself. The DTD was discarded.
      #
      # HENCE THE ASYMMETRY: 2880x1800 FAILED and the LARGER 3840x2160 PASSES,
      # purely because one is in the table and the other is not. It was never
      # about size. Pick from the table or do not pick.
      #
      # THE SYNC CEILING IS NOT QEMU'S AND NOT mkForce-ABLE. Pinned nixpkgs
      # qemu-vm.nix:1510-1512 injects `HorizSync 30-140` / `VertRefresh 50-160`
      # through `services.xserver.monitorSection` at mkVMOverride — PRIORITY 10,
      # higher than mkForce's 50 — so a naive mkForce to widen it loses silently.
      #
      # DECLINED 2026-10-06, OPERATOR'S CALL, recorded so it is not rediscovered:
      # `services.xserver.deviceSection` IS normal-priority at this pin, so
      #   Option "ModeValidation" "NoMaxPClkCheck,AllowNonEdidModes"
      # would disable the gate and unlock arbitrary modes — including 3024x1964,
      # the operator's exact panel, a 1512x982-point window at ~2.1x this area.
      # He declined it today as untested, not as wrong. Take it up knowingly.
      #
      # THE ARITHMETIC. On this Retina panel the Cocoa UI halves the framebuffer
      # for the window (ui/cocoa.m:503) and doubles back for the framebuffer
      # (:564-565), so WINDOW POINTS = GUEST PIXELS / 2 and one guest pixel is
      # one Mac device pixel. His panel is 3024x1964 native = 1512x982 points.
      # 1920x1440 -> 960x720 points: the largest-area table entry that fits.
      # 2560x1080 ties on area and loses on shape — 540pt tall is cramped.
      #
      # DPI STAYS 192 AT BOTH LAYERS — `services.xserver.dpi` in
      # modules/nixos/desktop-vm.nix and the HM `xfconf` Xft/DPI. DO NOT scale
      # them with the resolution. `backingScaleFactor = 2` is fixed by the
      # physical panel, so text size depends on that factor alone and NEVER on
      # the mode; this change is AREA ONLY. The instinct to pick a
      # "proportionate" DPI was wrong twice today.
      #
      # A PERSISTED USER SETTING CAN OVERRIDE ALL OF THIS. XFCE writes
      # ~/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml on the durable
      # qcow2 and xfsettingsd re-applies it at login, keyed by an EDID HASH — so
      # changing xres/yres changes the EDID, changes the hash, and ORPHANS the
      # saved profile. Measured 2026-10-06: that file already pinned
      # `Resolution = 1920x1440` (he had set it by hand), which is why this value
      # was chosen. If a future change to this number appears to do nothing,
      # that file is why.
      resolution = {
        x = 1920;
        y = 1440;
      };
      # THE GUEST CARRIES ITS OWN STORE IMAGE.
      #
      # CORRECTION 2026-10-06 — the reason recorded here until today was WRONG.
      # It said nixpkgs implements every share via virtiofs and that
      # `hostPkgs.virtiofsd` is Linux-only, so NO share can exist on a macOS
      # host. The second half is true; the first is not. At the pinned nixpkgs
      # (44a91898) nixos/modules/virtualisation/qemu-vm.nix:27 reads
      #     useVirtiofs = hostPkgs.stdenv.hostPlatform.isLinux;
      # which is FALSE here, so shares fall back to `-virtfs local,…` 9p (:1309)
      # plus a guest mount with `fsType = "9p"` (:1405). Measured against the
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
      #   `writableStore`      default = cfg.mountHostNixStore   (qemu-vm.nix:720)
      #   `mountHostNixStore`  default = !useNixStoreImage && !useBootLoader (:899)
      # So `useNixStoreImage = true` forces mountHostNixStore false, which drags
      # writableStore to FALSE by inheritance. Confirmed by evaluating this very
      # config before the fix: writableStore = false, mountHostNixStore = false.
      #
      # WHAT THAT COSTS. With writableStore false, /nix/store is a BIND of
      # /nix/.ro-store, an erofs mounted `ro` (:1448-1463, :1464-1469) — and
      # `findmnt /nix/store` in the guest confirmed `erofs ro,relatime`. The
      # nix-daemon then dies on its first write:
      #   unexpected Nix daemon error: error: creating directory
      #   "/nix/store/.links": Read-only file system
      # With it true, the SAME stanza switches to overlayfs —
      # lowerdir=/nix/.ro-store, upperdir=/nix/.rw-store/upper,
      # workdir=/nix/.rw-store/work — and /nix/.rw-store is a tmpfs
      # (writableStoreUseTmpfs defaults true, :731, mount at :1470-1474). So the
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
      #     already worked around below.
      #   * swapping Determinate for upstream nix — upstream's own test proves
      #     the daemon is irrelevant.
      #   * skipping nix during HM activation — home-manager's `activate` calls
      #     `nix-store --realise` and `nix-env --profile --set` unconditionally,
      #     so this is impossible without forking home-manager.
      writableStore = true;

      # NO SHARES AT ALL, and `lib.mkForce` is what keeps it that way: without
      # it upstream's own two defaults come back — `xchg` (/tmp/xchg) and
      # `shared` (/tmp/shared), the NixOS TEST driver's conveniences for passing
      # files between a test script and its guest (qemu-vm.nix:1235-1250). This
      # VM is booted by hand from a QEMU window, runs no test script, and has
      # nothing to exchange.
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
      # `xres`/`yres` ARE REAL PROPERTIES of this device — verified against the
      # exact pinned binary, not assumed:
      #   $ qemu-system-aarch64 -device virtio-gpu-pci,help
      #     xres=<uint32>  -  (default: 1280)
      #     yres=<uint32>  -  (default: 800)
      # Those defaults were the measured guest resolution, which is what proved
      # the device — not Xorg — owns this. See the `resolution` block above for
      # the full three-layer story; this is LAYER 1, and without it the Xorg
      # `Modes` line has no 2880x1800 to select.
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
      # LOSES `nix run .#nixvm`, every QEMU-specific audio/display/clipboard
      # option below, and the declarative `vmVariant` round-trip.
      # OPERATOR'S DECISION 2026-10-06: keep nixvm as it is, accept no USB.
      # (GPG and SSH specifically need no passthrough — see the memory note
      # `nixvm-usb-passthrough-closed` for the agent-socket RemoteForward recipe.)
      qemu.options = [
        "-device virtio-gpu-pci,xres=1920,yres=1440"
        "-chardev qemu-vdagent,id=vdagent0,name=vdagent,clipboard=on"
        "-device virtio-serial-pci"
        "-device virtserialport,chardev=vdagent0,name=com.redhat.spice.0"
        # ---- AUDIO, HOST HALF. The guest half is in desktop-vm.nix ----------
        # BOTH HALVES OR SILENCE. There was no sound card in the guest AT ALL
        # (`/proc/asound/cards` did not exist; only the generic snd/snd_seq/
        # snd_timer modules were loaded), because nothing had ever given QEMU an
        # audio device. Adding the guest's PipeWire stack alone would also be
        # silence — it would have nothing to open.
        #
        # THIS IS THE FOURTH TWO-LAYER FEATURE IN THIS VM, and the pattern is
        # worth naming because each time the config looked complete and built
        # green with one half missing: the CLIPBOARD (host chardev here + guest
        # spice-vdagentd there), the DISPLAY (host xres/yres here + guest
        # dpi/Xft.dpi there), SSH (host forwardPorts here + guest bind and
        # firewall there), and now AUDIO. CHECK BOTH SIDES FIRST.
        #
        # grepped nixos/modules/virtualisation/qemu-vm.nix for audio/soundhw/
        # audiodev — ZERO hits in 1,559 lines -> no upstream option owns QEMU
        # audio -> raw qemu.options justified, same escape hatch and the same
        # additive concatenation as the vdagent lines above.
        #
        # `coreaudio` IS COMPILED IN: `-audiodev help` on the exact pinned
        # binary lists none, coreaudio, dbus, spice, wav. It is the only one of
        # those that reaches the Mac's speakers.
        #
        # WHY virtio-sound-pci AND NOT intel-hda: paravirtualised, and ONE
        # device instead of a controller plus a separate `hda-duplex` codec —
        # which matches every other choice in this list (virtio-gpu-pci,
        # virtio-serial-pci). `-device help` confirms `virtio-sound-pci`
        # (alias `virtio-sound`) exists at 11.1.1. THE NAMED FALLBACK, if
        # `snd_virtio` does not bind in a booted guest, is the legacy pair:
        #   "-device intel-hda" "-device hda-duplex,audiodev=snd0"
        # The guest kernel has CONFIG_SND_VIRTIO=m and CONFIG_SND_HDA_INTEL=m,
        # so either driver is available; only a boot can say which binds.
        "-audiodev coreaudio,id=snd0"
        "-device virtio-sound-pci,audiodev=snd0"
      ];
      # NOTE: no explicit `-display` flag — QEMU on macOS defaults to a native
      # Cocoa window. On a Linux host you'd add `-display gtk` here instead.
    };

    # ---- WireGuard: TOOLS ONLY ----------------------------------------------
    # The CLI is present and nothing else is: no conf is provisioned (no share,
    # no environment.etc, nothing in /etc/wireguard) and nothing autostarts — no
    # systemd unit, no wg-quick service, no activation script touches a tunnel.
    # The operator brings his own file and runs it BY FULL PATH:
    # `sudo wg-quick up /path/to/conf.conf`. The bare-name form does not work
    # here, because wg-quick resolves a bare name against /etc/wireguard and
    # nothing populates it.
    #
    # Lives HERE and not in modules/nixos/desktop-vm.nix because that module is
    # scoped "XFCE desktop + guest integration" and WireGuard is neither — and
    # inside `virtualisation.vmVariant` it reaches nothing else: this file is
    # imported only by nixvm's own mkNixos call and the vmVariant layer applies
    # only to `system.build.vm`, so neither `nixpi` nor `macos` nor even nixvm's
    # base toplevel sees it. macos stays GUI-only with no wg CLI on purpose
    # (hosts/macos.nix, § Brews).
    #
    # The kernel module is listed because we are NOT using NixOS's wg-quick
    # unit, which is what would otherwise `modprobe wireguard` defensively.
    # The guest kernel is 6.x, so `wireguard` is in-tree.
    environment.systemPackages = [ pkgs.wireguard-tools ];
    boot.kernelModules = [ "wireguard" ];

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
    # qemu-vm.nix:1264), so SLiRP binds that address alone — nothing on the LAN
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
    # (qemu-vm.nix:632, host.address at :659). No hand-rolled -netdev/hostfwd.
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
    # this (its comment at :52-57), so it is preferred over hand-adding
    # `networking.firewall.allowedTCPPorts = [ 22 ]`: sshd's own module derives
    # the port list from `cfg.ports`, which stays correct if the port ever moves.
    # IPv4 wildcard ONLY, and deliberately not the `0.0.0.0` + `::` pair nixpi
    # uses: QEMU's SLiRP forwards IPv4 exclusively ("Currently QEMU supports
    # only IPv4 forwarding", qemu-vm.nix forwardPorts description), so a v6
    # bind here would listen for traffic that cannot arrive. Nothing in this
    # guest dials localhost:22 over v6 either. `port` is omitted on purpose —
    # see core.nix:73-82 for the `ListenAddress ::1:22` parse trap that costs.
    services.openssh.listenAddresses = lib.mkForce [
      { addr = "0.0.0.0"; }
    ];
    services.openssh.openFirewall = lib.mkForce true;

    # ---- polkit: wheel acts unchallenged, MIRRORING sudo --------------------
    # THIRD instance of the credential-prompt class documented in
    # modules/nixos/desktop-vm.nix — and the one handled DIFFERENTLY. XFCE
    # installs `polkit_gnome` as the polkit authentication agent
    # (nixos/modules/services/x11/desktop-managers/xfce.nix:126-127), so a
    # privileged desktop action pops a password dialog. This VM's account has
    # NO password, so that dialog is another dead end.
    #
    # THE DISTINCTION WORTH LEARNING, across all three instances:
    #   xfce4-screensaver -> turned OFF. A missing locker just never locks.
    #   gnome-keyring     -> turned OFF **and** its consumer pinned
    #                        (chromium --password-store=basic), because
    #                        Chromium auto-detects and the prompt would return.
    #                        Chromium itself was removed 2026-10-06; the keyring
    #                        stays off regardless, see that file.
    #   polkit            -> LEFT ON, told not to challenge. Removing an auth
    #                        agent does NOT make privileged actions work — it
    #                        makes them FAIL SILENTLY, with no dialog and no
    #                        error the operator can act on. "Disable it" is the
    #                        wrong reflex for an authorisation component.
    #
    # upstream option security.polkit.extraConfig exists -> using it
    # (nixos/modules/security/polkit.nix:65, types.lines, rendered into
    # /etc/polkit-1/rules.d/10-nixos.rules at :182).
    #
    # A NARROWER OPTION EXISTS AND IS THE WRONG AXIS: `adminIdentities` (:86)
    # already defaults to `[ "unix-group:wheel" ]` and feeds
    # `polkit.addAdminRule` (:178-180). It declares WHO COUNTS as an
    # administrator, not whether they must authenticate — so wheel is already
    # the admin identity here, which is precisely why the agent challenges the
    # operator. No upstream option expresses "authorise without authenticating";
    # a JS rule returning YES is polkit's own documented mechanism for it
    # (the option's example shows the same shape).
    #
    # COST, stated plainly: any process running as the operator's user in this
    # VM can take privileged desktop actions unchallenged. That is ALREADY true
    # of `sudo` here — `security.sudo.wheelNeedsPassword = false`
    # (modules/nixos/core.nix) — so the two paths now MATCH instead of one
    # being open and the other being an unanswerable prompt. Not a new hole;
    # a consistent one.
    #
    # DELIBERATELY VM-ONLY. It lives in this host's `vmVariant`, not in
    # modules/nixos/core.nix and not in desktop-vm.nix: the same rule on
    # `nixpi` (an internet-facing live server) or on `macos` would be a REAL
    # weakening, and desktop-vm.nix is a reusable module whose other consumers
    # must not silently inherit a security posture chosen for a disposable VM.
    # `polkit_gnome` stays installed — this removes its need to ask, not the
    # agent that asks.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.isInGroup("wheel")) { return polkit.Result.YES; }
      });
    '';
  };
}
