# `nixos` — a LONG-LIVED GNOME desktop guest for the Mac, run by UTM's QEMU
# backend (virtio-gpu-gl + virgl). The Mac side (UTM bundle, `nixos-vm` CLI,
# Spotlight launcher) lives in packages/nixos-vm.nix.
#
# WHY UTM AND NOT TART / nixvm (R&D 2026-10-17): under Apple Virtualization a
# Linux guest renders with llvmpipe only and virtio-sound stalls (measured:
# eglinfo -> llvmpipe; host log "VirtioSoundDevice: Bad io message"); nixvm's
# QEMU Cocoa window is 2D virtio-gpu. UTM's QEMU build carries virgl -> ANGLE ->
# Metal: the stock GNOME ISO under it reported a virgl renderer, followed
# window resizes, and played 1080p video cleanly.
#
# LIFECYCLE — SEED, THEN SWITCH. `nixos-vm create` boots a disk image that
# carries only a small SEED variant of this host (`local.nixosGuest.seed`):
# enough to boot, take the operator's key over SSH and answer the guest agent.
# Its first act is then
#   nixos-rebuild switch --flake .#nixos --target-host nixos.local --sudo
# which installs everything else, and that is also how the VM is updated for
# the rest of its life (`--use-remote-sudo` is deprecated in nixos-rebuild-ng).
#
# WHY A SEED (measured 2026-10-17): the full closure is 6.7 GiB, and
# systemd-repart stages it AND writes the raw image in $NIX_BUILD_TOP, which on
# this Mac's Determinate Linux builder is the VM's RAM tmpfs (half the VM's
# RAM) — "No space left on device". Even the seed needed the builder raised
# from 8 to 16 GiB (`memoryBytes` in hosts/macos.nix). Rejected: raising it to
# the ~28-32 GiB the full closure needs on a 36 GB Mac; staging into $out (that is
# virtiofs onto the case-INSENSITIVE Mac store, where the terminfo collision
# modules/nixos/core.nix works around returns); a CI-built 7 GiB release artifact for a once-used bootstrap.
# A seed also changes almost never, so the image is not rebuilt on every
# desktop tweak.
{
  config,
  lib,
  pkgs,
  modulesPath,
  extendModules,
  loginName,
  ...
}:
let
  cfg = config.local.nixosGuest;
  efiArch = config.nixpkgs.hostPlatform.efiArch;

  # The variant the disk image carries. `extendModules` is how nixpkgs builds
  # `virtualisation.vmVariant` (nixos/modules/virtualisation/build-vm.nix) —
  # the same configuration with one more module, evaluated lazily, so only
  # system.build.image ever forces it.
  seed = (extendModules { modules = [ { local.nixosGuest.seed = true; } ]; }).config;
  # Input for `nix-store --load-db` on first boot — see register-nix-paths.
  seedClosureInfo = pkgs.closureInfo { rootPaths = [ seed.system.build.toplevel ]; };
in
{
  imports = [
    # virtio blk/net/gpu/console + 9p and virtiofs in the initrd. The same
    # profile nixos-generate-config adds for any QEMU guest, and the one
    # mitchellh/nixos-config's UTM machine imports.
    "${modulesPath}/profiles/qemu-guest.nix"
    "${modulesPath}/image/repart.nix"
    ../modules/nixos/lan-recovery.nix
  ];

  options.local.nixosGuest.seed = lib.mkEnableOption ''
    the minimal bootstrap variant carried by the disk image: boot, SSH and the
    guest agent only. Set ONLY by the extendModules call that builds the image —
    the real host never sets it
  '';

  config = lib.mkMerge [
    # ======== EVERY variant — what the seed needs to boot and be reached ========
    {
      networking.hostName = "nixos";
      system.stateVersion = "26.11";
      time.timeZone = "America/Toronto";

      # ---- Reachability from the Mac -----------------------------------------
      # modules/nixos/core.nix binds sshd to LOOPBACK ONLY and opens no port,
      # which would leave this guest unreachable over UTM's shared network.
      # local.lanRecovery is the fleet's existing, posture-checked way to widen
      # exactly that, scoped per interface — reused rather than a second
      # hand-rolled override.
      #
      # Classic `eth0` naming because lanRecovery.interfaces must NAME the NIC,
      # and predictable names are hypervisor-specific (Tart gave enp0s1,
      # mitchellh's UTM machine enp0s10); a wrong guess fails open — the port
      # silently never opens.
      networking.usePredictableInterfaceNames = false;
      local.lanRecovery = {
        enable = true;
        interfaces = [ "eth0" ];
      };
      # QEMU guest agent: what `utmctl ip-address` and `utmctl exec` talk to.
      services.qemuGuest.enable = true;

      # ---- Boot + disk ---------------------------------------------------------
      # systemd-boot owns the ESP from the first `nixos-rebuild switch` on.
      # canTouchEfiVariables stays false: UTM's firmware boots the removable
      # path (\EFI\BOOT\BOOTAA64.EFI), so nothing needs an NVRAM entry.
      boot.loader.systemd-boot = {
        enable = true;
        # Some VM firmware only supports console mode 0 ("error switching
        # console mode" otherwise) — mitchellh/nixos-config's VMs set the same.
        consoleMode = "0";
      };
      boot.loader.efi.canTouchEfiVariables = false;

      fileSystems."/" = {
        device = "/dev/disk/by-partlabel/nixos";
        fsType = "ext4";
        # growPartition grows the GPT partition, autoResize the ext4 inside it:
        # the image is built minimal and `nixos-vm create` resizes the qcow2 to
        # 64 GiB. Same pair nixpkgs' own qemu-efi disk image (disk-image.nix)
        # sets.
        autoResize = true;
      };
      boot.growPartition = true;
      fileSystems."/boot" = {
        device = "/dev/disk/by-partlabel/ESP";
        fsType = "vfat";
        options = [ "umask=0077" ];
      };

      # Makes the image a REBUILDABLE NixOS host rather than an appliance: load
      # the store paths into the Nix database, tag /etc/NIXOS and create the
      # system profile that nixos-rebuild expects, once. The same construct
      # nixpkgs' sd-image module uses (its register-nix-paths service) — which
      # is how nixpi, also never installed by an installer, takes
      # `nixos-rebuild` updates.
      # ✅ grepped nixpkgs nixos/modules for register-nix-paths — only inline
      # copies (sd-image, qemu-vm, vm-base, lxc/docker/iso/netboot), none
      # importable for a repart image → custom.
      systemd.services.register-nix-paths = {
        description = "Register Nix store paths from the disk image";
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = "/nix-path-registration";
        };
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "shutdown.target"
          "nix-daemon.socket"
          "nix-daemon.service"
        ];
        after = [ "local-fs.target" ];
        conflicts = [ "shutdown.target" ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration
          touch /etc/NIXOS
          ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
          rm -f /nix-path-registration
        '';
      };
    }

    # ======== The seed only ========
    (lib.mkIf cfg.seed {
      # The shared Home Manager profile is 820 MiB of the seed's 1.9 GiB
      # closure (measured), and the seed needs none of it: the first switch
      # brings it. Staging must fit the builder's RAM tmpfs twice over (copied
      # tree + the raw image being written).
      home-manager.users = lib.mkForce { };
    })

    # ======== The real host only — everything the seed leaves to the first switch ========
    (lib.mkIf (!cfg.seed) {
      # ---- Desktop -------------------------------------------------------------
      # GNOME 50 is Wayland-only: the pinned gdm module removed the
      # `services.displayManager.gdm.wayland` switch ("no longer supported with
      # GNOME 50"), so there is no X11 session to fall back to.
      services.displayManager.gdm = {
        enable = true;
        # Do not suspend the login screen of a VM that is reached over SSH.
        autoSuspend = false;
      };
      services.desktopManager.gnome.enable = true;
      services.displayManager.autoLogin = {
        enable = true;
        user = loginName;
      };

      # Clipboard both ways + dynamic resolution (UTM's docs require the SPICE
      # agent for both on the QEMU backend). The NixOS graphical ISO enables
      # these two guest services too, which is the configuration the smoke
      # test ran.
      services.spice-vdagentd.enable = true;
      # …but that module starts only the system DAEMON. The per-session CLIENT
      # (`spice-vdagent`, which does the clipboard and resize work) ships an XDG
      # autostart entry marked `X-systemd-skip=true` + `X-GNOME-Autostart-Phase`,
      # i.e. "gnome-session starts this, not systemd" — and GNOME 50's
      # gnome-session no longer does (measured on first boot: "App
      # spice-vdagent.desktop sets X-GNOME-Autostart-Phase, but gnome-session no
      # longer manages session services", and no client process). So nobody
      # started it. A user unit on graphical-session.target is how GNOME 50
      # runs session services; `-x` keeps it in the foreground for systemd.
      #
      # ORDERED AFTER THE SHELL, not just graphical-session.target: started that
      # early, the agent found the monitor but never received a resize, so the
      # guest stayed at 1280x800 under a full-screen Retina window (measured
      # 2026-10-17); `systemctl --user restart spice-vdagent` once the session
      # was up made resizes flow at once. That is mutter issue 1856 (autologin
      # + Wayland: spice-vdagent misses mutter's DisplayConfig). In GNOME 50 the
      # shell is `org.gnome.Shell@user.service`, and
      # gnome-session-initialized.target is reached after it.
      # ✅ services.spice-vdagentd starts only the system daemon, and the package
      # ships an XDG autostart entry but no systemd user unit → custom.
      systemd.user.services.spice-vdagent = {
        description = "SPICE session agent (clipboard, dynamic resolution)";
        wantedBy = [ "gnome-session-initialized.target" ];
        partOf = [ "graphical-session.target" ];
        after = [
          "graphical-session.target"
          "org.gnome.Shell@user.service"
          "gnome-session-initialized.target"
        ];
        serviceConfig = {
          ExecStart = "${pkgs.spice-vdagent}/bin/spice-vdagent -x";
          Restart = "on-failure";
        };
      };

      # THE ACCOUNT HAS NO PASSWORD (modules/nixos/core.nix: keys-only), so
      # nothing here may demand one — the class of dead-end prompt nixvm's
      # deleted XFCE desktop hit (see the hosts/nixvm.nix header). GNOME turns
      # these on by default:
      #   gnome-keyring -> an autologin session never unlocks it, so apps that
      #                    use the Secret Service ask for a password that does
      #                    not exist;
      #   initial-setup -> a first-run wizard for an account already set up.
      services.gnome.gnome-keyring.enable = false;
      services.gnome.gnome-initial-setup.enable = false;
      # polkit: wheel acts unchallenged, MIRRORING `security.sudo.
      # wheelNeedsPassword = false` in core.nix. Removing the auth agent instead
      # would make privileged desktop actions fail silently. Host-local on
      # purpose — the same rule on nixpi would be a real weakening.
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (subject.isInGroup("wheel")) { return polkit.Result.YES; }
        });
      '';

      # System DEFAULTS, not enforced settings: the user database stays first in
      # the profile (`enableUserDb` defaults to true), so anything changed in
      # GNOME Settings wins and a rebuild does not fight it.
      programs.dconf.profiles.user.databases = [
        {
          settings = {
            "org/gnome/desktop/interface" = {
              color-scheme = "prefer-dark";
              # NO `scaling-factor` here, on purpose. A forced 2 assumed a
              # Retina-PIXEL framebuffer (true under Tart); UTM with
              # NativeResolution = false hands the guest the window's size in
              # macOS POINTS instead (full screen on this Mac: 1440x900), so 2x
              # turned it into a 720x450 desktop, and a forced 4K mode to
              # compensate gave a double mouse pointer (operator-tested
              # 2026-10-17). Unset (0 = automatic), mutter picks 1x for that
              # size — the 1440x900 @ 100% the operator settled on.
            };
            # Natural scrolling to match the Mac. UTM's pointer may enumerate as
            # a mouse, which GNOME defaults to traditional scrolling, so set
            # both. (UTM's own "Invert scrolling" pref stays OFF — two flips
            # cancel.)
            "org/gnome/desktop/peripherals/mouse".natural-scroll = true;
            "org/gnome/desktop/peripherals/touchpad".natural-scroll = true;
            # No lock, no blanking, no idle suspend: the Mac's lock screen
            # guards it.
            "org/gnome/desktop/screensaver".lock-enabled = false;
            "org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 0;
            "org/gnome/settings-daemon/plugins/power".sleep-inactive-ac-type = "nothing";
            # ONE desktop: no dynamic workspaces (operator's call, 2026-10-17).
            # Still a default — Settings -> Multitasking can change it back.
            "org/gnome/mutter".dynamic-workspaces = false;
            # dconf needs the GVariant type spelled out: num-workspaces is `i`.
            "org/gnome/desktop/wm/preferences".num-workspaces = lib.gvariant.mkInt32 1;
            # The dock, in this order (operator's pick). Desktop-file IDs as the
            # guest's share/applications names them.
            "org/gnome/shell".favorite-apps = [
              "firefox.desktop"
              "tor-browser.desktop"
              "org.gnome.Console.desktop"
              "org.gnome.Settings.desktop"
            ];
          };
        }
      ];

      # ---- Applications ----------------------------------------------------------
      # The STOCK Firefox, not `programs.firefox`: that module re-wraps Firefox
      # with its own prefs/policies, which is a fresh local build — and the
      # wrapper's `cp` EPERMs on this Mac's Determinate Linux builder (measured
      # here: "cp: setting permissions for …/bin/firefox: Permission denied";
      # the builder bug in docs/map/hosts.md). pkgs.firefox substitutes from
      # cache.nixos.org, so nothing is built. No policy is set, so the module
      # would add nothing but that build.
      xdg.mime.defaultApplications = {
        "text/html" = "firefox.desktop";
        "x-scheme-handler/http" = "firefox.desktop";
        "x-scheme-handler/https" = "firefox.desktop";
      };
      # Tor Browser on aarch64 exists only on the ALPHA channel; the overlay and
      # every reason for it live once, in modules/_lib/tor-browser-alpha.nix.
      # Browser decision (2026-10-17): Firefox + this alpha — tested in the
      # guest and KEPT. Brave alone was the fallback had the alpha failed.
      nixpkgs.overlays = [ (import ../modules/_lib/tor-browser-alpha.nix) ];

      # GNOME Web would be a second browser nobody chose; GNOME Tour is the
      # first-login welcome window (seen on the first boot), the same first-run
      # class as gnome-initial-setup above.
      environment.gnome.excludePackages = [
        pkgs.epiphany
        pkgs.gnome-tour
      ];

      # gpg + its agent only — no key is ever imported here; PGP work stays on
      # the Mac (pgp-ops) and text crosses over the shared clipboard.
      # pinentry-gnome3 is the graphical-desktop default.
      #
      # NO GUI. `gpa` was here and SEGFAULTS on launch (measured 2026-10-17:
      # SIGSEGV in gpa_context_class_init -> g_signal_new, inside GLib's type
      # check, before any window) — the same "crashes on launch" hosts/macos.nix
      # records for it on aarch64-darwin. Seahorse needs gnome-keyring (off
      # here, no-password account) and Kleopatra drags in KDE, so none replaces
      # it until a GUI is actually wanted in this VM.
      programs.gnupg.agent.enable = true;

      # Security keys arrive by UTM USB passthrough (UTM prompts on plug-in).
      # FIDO2/WebAuthn needs no extra rule: systemd ships 60-fido-id.rules,
      # which tags FIDO tokens for the logged-in user. pcscd + the gnupg ccid
      # rules cover the smartcard/PIV/OpenPGP-card side.
      services.pcscd.enable = true;
      hardware.gpgSmartcards.enable = true;

      environment.systemPackages = with pkgs; [
        firefox
        tor-browser
        yubikey-manager
        # No wireguard-tools: WireGuard needs nothing installed here.
        # NetworkManager 1.58 speaks it natively (no VPN plugin in the closure)
        # and GNOME Settings -> VPN offers "WireGuard" and "Import from file…"
        # on its own — verified on this guest, 2026-10-17. Configs are imported
        # by hand, so no key ever enters Nix.
      ];

      # ---- Shared folder: Mac ~/Shared -> /mnt/host (and ~/Shared) -------------
      # UTM's VirtFS (9p, mount tag `share`, security_model=mapped-xattr).
      # Options follow UTM's Linux guest docs; automount + nofail so a VM
      # started without the share configured still boots.
      #
      # TWO LAYERS, because the raw 9p mount was READ-ONLY in practice
      # (measured 2026-10-17): Mac files surface with the Mac's uid 501, the
      # guest user is uid 1000, so every write hit "permission denied". UTM's
      # Linux guest docs name bindfs for exactly this uid remap. The raw mount
      # sits out of the way; bindfs re-presents it owned by the operator, and
      # the real write still lands on the Mac as the Mac user (QEMU's process).
      fileSystems."/mnt/.utm-share" = {
        device = "share";
        fsType = "9p";
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "nofail"
          "x-systemd.automount"
        ];
      };
      fileSystems."/mnt/host" = {
        device = "/mnt/.utm-share";
        fsType = "fuse.bindfs";
        depends = [ "/mnt/.utm-share" ];
        options = [
          "force-user=${loginName}"
          "force-group=users"
          # A root-owned FUSE mount is invisible to other users without it.
          "allow_other"
          "nofail"
          "x-systemd.automount"
        ];
      };
      # No system.fsPackages entry: the pinned nixpkgs adds pkgs.bindfs itself
      # for any "fuse.bindfs" fsType (nixpkgs nixos/modules/tasks/filesystems/bindfs.nix).
      # ~/Shared in the guest too, so Files shows it in the home folder exactly
      # where the Mac keeps it.
      systemd.tmpfiles.rules = [
        "L+ ${config.users.users.${loginName}.home}/Shared - - - - /mnt/host"
      ];

      # ---- The disk image (built from the SEED variant above) ------------------
      # upstream-first: grepped nixpkgs/nixos/modules/image for qemu/qcow2/efi
      # images. `image.modules.qemu-efi` (virtualisation/disk-image.nix) is the
      # off-the-shelf one, but it builds through make-disk-image ->
      # vmTools.runInLinuxVM, which requires the `kvm` system feature — and this
      # Mac's Determinate Linux builder advertises none. image.repart builds
      # with fakeroot (image/repart-image.nix), so it is the one that builds
      # here.
      #
      # FIRST BOOT, before systemd-boot has ever been installed: the ESP carries
      # the systemd-boot binary at the removable path plus the seed's Unified
      # Kernel Image (Boot Loader Spec type #2), which systemd-boot finds with
      # no loader entries at all. This is the layout of nixpkgs' own
      # appliance-repart-image test; that test's image is NOT rebuildable —
      # register-nix-paths above is what changes that.
      image.repart = {
        # Opt-in since the 26.11 module (its whole config is `mkIf cfg.enable`).
        enable = true;
        name = "nixos";
        # nixpkgs' appliance test: "OVMF does not work with the default repart
        # sector size of 4096". UTM's QEMU firmware is EDK2 as well.
        sectorSize = 512;
        partitions = {
          # Attribute order is partition order: the ESP first, root LAST,
          # because growpart can only grow the final partition into new space.
          "10-esp" = {
            contents = {
              "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
                "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
              "/EFI/Linux/${seed.system.boot.loader.ukiFile}".source =
                "${seed.system.build.uki}/${seed.system.boot.loader.ukiFile}";
            };
            repartConfig = {
              Type = "esp";
              Format = "vfat";
              Label = "ESP";
              # Room for many generations of kernel + initrd once systemd-boot
              # manages this partition (a long-lived host keeps several).
              SizeMinBytes = "1G";
            };
          };
          "20-root" = {
            storePaths = [ seed.system.build.toplevel ];
            contents."/nix-path-registration".source = "${seedClosureInfo}/registration";
            repartConfig = {
              Type = "root";
              Format = "ext4";
              Label = "nixos";
              # An explicit size, NOT `Minimize = "guess"`: the guess came out
              # too small for the seed ("mkfs.ext4: No space left on device
              # while populating file system", measured). Root grows to fill the
              # 64 GiB qcow2 on first boot anyway (growPartition + autoResize).
              SizeMinBytes = "3G";
            };
          };
        };
      };
    })
  ];
}
