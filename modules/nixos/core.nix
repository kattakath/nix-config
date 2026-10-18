# Shared NixOS system configuration applied to every NixOS host.
# Platform-specific hardware lives in hosts/<hostname>.nix.
# User environment lives in modules/home/default.nix (via Home Manager).
{
  config,
  pkgs,
  lib,
  loginName,
  operatorSshKey,
  ...
}:
{
  config = {
    # The ONE NixOS definition — this module is in mkNixos's base list, so every
    # NixOS host (and its vmVariant / seed extendModules) inherits it. Needed for
    # e.g. `claude-code` in the shared Home Manager profile (useGlobalPkgs).
    nixpkgs.config.allowUnfree = true;

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        loginName
      ];
    };

    users.users.${loginName} = {
      isNormalUser = true;
      shell = pkgs.zsh;
      extraGroups = [ "wheel" ];
      # The operator's SSH public key — the network login credential. sshd binds
      # LOOPBACK ONLY by default on every host this module configures (see
      # listenAddresses below), so the only network route in is the tunnel
      # connector, which terminates on-host and dials localhost:22. nixpi OPTS OUT
      # of that default — `local.lanRecovery` (modules/nixos/lan-recovery.nix)
      # replaces the bind with the wildcard and opens the port on its two LAN
      # interfaces alone, because a dead connector was otherwise a 40-minute
      # physical reflash. nixvm keeps loopback-only. Key-only, no password either
      # way. Physical console (getty) is an independent break-glass path.
      #
      # `lib.optional`, not a bare list: `mkNixos` defaults `operatorSshKey` to
      # null so a downstream consumer does not silently inherit the operator's
      # login credential (see the parameter's note in modules/parts/compose.nix).
      # A null here means "no key was granted", which leaves the account
      # key-only with no keys — unreachable over the network, console only —
      # rather than `[ null ]`, which is a type error at build time.
      openssh.authorizedKeys.keys = lib.optional (operatorSshKey != null) operatorSshKey;
    };

    # Pinned for nixpi by `nixpi-security-posture` (modules/parts/checks.nix):
    # relaxing any line in this block fails `nix flake check`.
    services.openssh = {
      enable = true;

      # sshd's own module opens its ports in the firewall by default
      # (nixpkgs nixos/modules/services/networking/ssh/sshd.nix:874 —
      # `allowedTCPPorts = optionals cfg.openFirewall cfg.ports`, option at :312).
      # Clearing allowedTCPPorts below is NOT enough on its own: this option is
      # what actually keeps 22 shut, and it is the upstream-supported knob rather
      # than a mkForce fight with the module.
      openFirewall = false;

      # LOOPBACK ONLY — the DEFAULT for every host here, so sshd is reachable
      # exclusively through the Cloudflare Tunnel, which terminates ON this host
      # and dials localhost:22. Binding the wildcard leaves port 22 answering on
      # the LAN, where the Access application in front of nixpi.<domain> is NOT
      # consulted and no Access log is produced: an edge-only identity layer that
      # anything on the same network segment can walk around. That cost is now
      # PAID ON PURPOSE on nixpi — `local.lanRecovery` mkForces the wildcard pair
      # and scopes the open port to end0/wlan0 — because the alternative measured
      # on 2026-10-01 was a dead connector with no way in at all. Do not relax it
      # HERE: this default is what keeps nixvm, and every `lib.mkNixos` consumer,
      # loopback-only. Both loopback families are bound because `localhost` may
      # resolve to ::1 first.
      # Break-glass if both the tunnel and the LAN are down: the console (getty).
      # `port` is deliberately OMITTED so both entries inherit `Port 22` above.
      # Setting it here emits `ListenAddress ::1:22`, and nixpkgs does NOT bracket
      # the address (nixos/modules/services/networking/ssh/sshd.nix:899-902 renders
      # a bare `${addr}:${port}`). OpenSSH then reads an unbracketed argument with
      # two or more colons as a whole IPv6 address, so `::1:22` parses as the
      # address `::0.1.0.34` and the bind fails with EADDRNOTAVAIL. sshd survives
      # (a failed bind is fatal only if EVERY bind fails), so the breakage is
      # silent: v4 loopback works and v6 is simply absent. Measured with
      # `sshd -G`:  ListenAddress ::1:22 -> [::0.1.0.34]:22
      #             ListenAddress ::1    -> [::1]:22
      listenAddresses = [
        { addr = "127.0.0.1"; }
        { addr = "::1"; }
      ];

      settings = {
        # Keys-only: the SSH endpoint is fronted by a Cloudflare Access
        # application (self-hosted app on nixpi.<domain>, operator email only),
        # but Access enforces at the EDGE — cloudflared proxies raw TCP to
        # localhost:22, so the origin can verify no JWT. The operator key stays
        # the origin-side boundary and must never accept a password or
        # keyboard-interactive path.
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # Also pinned by `nixpi-security-posture`, which gates the port-RANGE,
    # per-interface and trusted-interface paths into the same accept rule.
    networking.firewall = {
      enable = true;
      # Port 22 is deliberately NOT opened HERE, and this list is the GLOBAL one:
      # firewall-iptables.nix:160-165 renders the `default` pseudo-interface with
      # no `-i`, so a port added here answers on every interface the host has.
      # nixpi's LAN recovery path therefore goes through
      # `networking.firewall.interfaces.<iface>` instead (lan-recovery.nix), never
      # through this list.
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ 5353 ]; # mDNS
    };

    # mDNS — makes <hostname>.local resolvable on the LAN without a DNS server.
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
      };
    };

    # nix-ld gives dynamically-linked, non-Nix binaries (VS Code Server, prebuilt
    # language servers, downloaded toolchains) a glibc loader + a library search
    # path. This native NixOS module OWNS nix-ld on every NixOS host; `libraries`
    # merges with nix-ld's baseLibraries and is exposed via NIX_LD_LIBRARY_PATH.
    programs.nix-ld = {
      enable = true;
      # Shared list — same set the HM shim and the devcontainer image use.
      libraries = import ../_lib/nix-ld-libraries.nix pkgs;
    };

    programs.zsh.enable = true;

    security.sudo.wheelNeedsPassword = false;

    # zram compressed swap — cheap in-RAM overflow so a build/memory spike degrades
    # instead of triggering a hard OOM-kill (swapDevices is empty on these guests).
    # audit finding (2026-07). Applies to all NixOS hosts.
    zramSwap.enable = true;

    # ONE garbage collector, not two (2026-09-21). determinate-nixd runs on the
    # NixOS hosts now (modules/parts/compose.nix) and its collector defaults to
    # `automatic`, which targets ">= 30 GB free" and goes "urgent" under 5 % —
    # Determinate's best-practices page says never to pair it with a timer. On
    # nixpi's SD card that 30 GB target may be unreachable, so the automatic
    # collector could churn writes on low-endurance flash forever. Keep the
    # proven weekly timer below and switch nixd's off. UPSTREAM FIRST: the
    # determinate nixosModule exposes no `garbageCollector` option (only
    # `enable` + `edgeCacheSubstituters`, modules/nixos.nix in the pinned input)
    # and writes /etc/determinate/config.json only when edgeCacheSubstituters is
    # set, so this plain environment.etc entry is the documented knob
    # (https://docs.determinate.systems/determinate-nix/determinate-nixd/). It
    # COLLIDES with the module's own write if edgeCacheSubstituters is ever set —
    # merge the two then.
    environment.etc."determinate/config.json".text = builtins.toJSON {
      garbageCollector.strategy = "disabled";
    };

    # Automatic store GC + on-the-fly reclaim — a long-lived host (nixpi's SD
    # card) must self-trim or the store fills the disk. audit follow-up (2026-07).
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    # Daemon frees store paths mid-build when free space drops below min-free,
    # up to max-free — prevents ENOSPC during large builds.
    nix.settings.min-free = 3 * 1024 * 1024 * 1024; # 3 GiB
    nix.settings.max-free = 10 * 1024 * 1024 * 1024; # 10 GiB

    # Periodic TRIM instead of online `discard` (Determinate best-practices § "Don't
    # mount your Nix store with online discard"): a weekly fstrim reclaims freed
    # blocks in one batch, where a `discard` mount option would issue one
    # synchronous request per freed extent during every GC. Neither root (the SD
    # image's ext4) nor /mnt/storage mounts with `discard`, so this is the missing
    # half. Upstream option: services.fstrim (nixos/modules/services/misc/fstrim.nix),
    # default interval weekly.
    services.fstrim.enable = true;

    # THE SYSTEMD INITRD'S `linux` TERMINFO ENTRY IS UNREACHABLE WHEN BUILT ON
    # THE MAC, so drop it. Without this, EVERY build of a systemd-initrd host
    # (nixvm's toplevel AND build-vm, nixos's toplevel AND seed image) dies in
    # `initrd-linux-*` with:
    #   Error: failed to get symlink metadata for ".../ncurses-*/share/terminfo/l/linux"
    #
    # HERE, not in hosts/: the cause is the BUILD host's store, not any target
    # VM, so it belongs where every NixOS target built on this Mac is composed.
    #
    # Three facts compose into that, and none of them is a nixpkgs bug:
    #   1. The Mac's "Nix Store" APFS volume is CASE-INSENSITIVE, so ncurses'
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
    # a per-entry `enable` (confirmed by evaluating nixvm:
    # `...contents."/etc/terminfo/l/linux"` has attrs dlopen/enable/source/target/text).
    # Deliberately NOT `lib.mkForce { }` on the whole attrset (other modules
    # contribute ~28 entries, including /init and /lib), and deliberately NOT
    # re-pointed at `l~nix~case~hack~1/linux` — that path is an artefact of THIS
    # filesystem and would not exist on a case-sensitive store.
    #
    # GUARDED on systemd stage-1 because only that initrd reads `contents`: nixpi
    # forces the SCRIPTED initrd (hosts/nixpi.nix), so there the guard is false and
    # its value stays upstream's `true` — a no-op either way, but an honest one.
    #
    # COST: the initrd console loses the `linux` terminfo entry. That matters only
    # to a full-screen program on the early-boot console; nothing here runs one.
    # It also reaches every downstream `lib.mkNixos` consumer, whose store may well
    # be case-sensitive — same cost, nothing else.
    # SCOPE: this patches this instance, not the bug class. Every aarch64-linux
    # build on the Mac that resolves a mixed-case store path by literal name is
    # still exposed. The durable fixes are a case-sensitive store volume (reformat)
    # or substituting the closure from CI — neither taken, operator's call 2026-10-06.
    boot.initrd.systemd.contents."/etc/terminfo/l/linux".enable =
      lib.mkIf config.boot.initrd.systemd.enable false;

    environment.systemPackages = with pkgs; [
      git
      curl
    ];

    # Shared install-era stateVersion for every NixOS host (both import this
    # module). mkDefault lets a future host pin a different one if ever needed.
    system.stateVersion = lib.mkDefault "24.05";
  };
}
