# Shared NixOS system configuration applied to every NixOS host.
# Platform-specific hardware lives in hosts/<hostname>.nix.
# User environment lives in modules/home/default.nix (via Home Manager).
{
  pkgs,
  lib,
  loginName,
  operatorSshKey,
  ...
}:
let
  retention = import ../_lib/store-retention.nix;
in
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
      # connector, which terminates on-host and dials localhost:22. A host that
      # sets `local.lanRecovery` (modules/nixos/lan-recovery.nix) OPTS OUT of that
      # default — it replaces the bind with the wildcard and opens the port on the
      # named LAN interfaces alone, because on nixpi a dead connector was otherwise
      # a 40-minute physical reflash. nixos keeps loopback-only. Key-only, no
      # password either way. Physical console (getty) is an independent
      # break-glass path.
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
      # PAID ON PURPOSE wherever a host sets `local.lanRecovery` (grep hosts/) — it
      # mkForces the wildcard pair and scopes the open port to the named
      # interfaces — because the alternative measured on nixpi on 2026-10-01 was a
      # dead connector with no way in at all. Do not relax it HERE: this default
      # is what keeps nixos, and every `lib.mkNixos` consumer that does not set
      # it, loopback-only. Both loopback families are bound because `localhost` may
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
        # application (self-hosted app on nixpi.<domain>; who it admits is
        # `nixpi_ssh_operator` in infra/cloudflare/nixpi-tunnel.nix),
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
      # through this list. UDP 5353 (mDNS) lands on it from avahi below:
      # `services.avahi.openFirewall` defaults to true in the pinned nixpkgs
      # (avahi-daemon.nix), so the port is open exactly while avahi is.
      allowedTCPPorts = [ ];
    };

    # mDNS — makes <hostname>.local resolvable on the LAN without a DNS server.
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      settings.publish = {
        disable-publishing = false;
        publish-addresses = true;
        publish-workstation = true;
      };
    };

    # nix-ld gives dynamically-linked, non-Nix binaries (VS Code Server, prebuilt
    # language servers, downloaded toolchains) a glibc loader + a library search
    # path. This native NixOS module OWNS nix-ld on every NixOS host; `libraries`
    # merges with nix-ld's baseLibraries and is exposed via NIX_LD_LIBRARY_PATH.
    programs.nix-ld = {
      enable = true;
      # Shared list — its header names every consumer.
      libraries = import ../_lib/nix-ld-libraries.nix pkgs;
    };

    programs.zsh.enable = true;

    security.sudo.wheelNeedsPassword = false;

    # zram compressed swap — cheap in-RAM overflow so a build/memory spike degrades
    # instead of triggering a hard OOM-kill (swapDevices is empty on these guests).
    # audit finding (2026-07). Applies to all NixOS hosts.
    zramSwap.enable = true;

    # Automatic store GC — the fleet policy in ../_lib/store-retention.nix
    # (keep 3 generations, 3-day window, daily), run by nixpkgs' own
    # `programs.nh.clean` (`nh clean all`: prunes system + per-user profiles AND
    # stale gcroots, then `nix store gc`). It replaced `nix.gc` weekly
    # `--delete-older-than 30d` on 2026-11-27: after nixpi's 2026-11-09 reflash
    # every generation was younger than 30 days, so three runs freed 0 KiB while
    # 8.0 GiB piled up (a manual `nix-collect-garbage -d` freed it). nh's module
    # warns when `nix.gc.automatic` is also on, so `nix.gc` is gone, not merely
    # retuned. `programs.nh.enable` stays OFF on purpose: it would put `nh os
    # switch` on nixpi's PATH, a one-word way to build ON the Pi (Rule 1d); the
    # NixOS clean service needs only `cfg.package` (pinned nixpkgs
    # nixos/modules/programs/nh.nix, no `clean -> enable` assertion there).
    programs.nh.clean = {
      enable = true;
      dates = retention.systemdCalendar;
      extraArgs = "--keep ${toString retention.keep} --keep-since ${retention.keepSince}";
    };
    # Daemon frees store paths mid-build when free space drops below min-free,
    # up to max-free — prevents ENOSPC during large builds.
    nix.settings.min-free = retention.minFree;
    nix.settings.max-free = retention.maxFree;
    # Deduplicate as paths land — "optimise on every activation" without a
    # full-store `nix store optimise` scan inside deploy-rs's confirm window.
    # Re-enabled 2026-11-27 for fleet parity with macos (modules/parts/compose.nix
    # sets the same in its `nix.settings`). It was retired
    # 2026-11-09 as unneeded for space, which is still true (the 2026-11-27
    # manual optimise on nixpi freed only 88.9 MiB); the reason now is one
    # policy across the fleet, at the cost of a hash+link per store write.
    nix.settings.auto-optimise-store = true;
    # Upstream Nix defaults this to false and then BUILDS every
    # allowSubstitutes = false wrapper (boot.json, a system toplevel, deploy-rs's
    # activatable) instead of fetching it. Determinate's nix.conf set it; the
    # darwin side sets the same in modules/parts/compose.nix.
    nix.settings.always-allow-substitutes = true;
    # Flakes only, the same as darwin (modules/darwin/nix.nix): no `nix-channel`
    # and no channel entries in NIX_PATH (nixpkgs nixos/modules/config/
    # nix-channel.nix); `nixpkgs` resolves through the flake registry.
    nix.channel.enable = false;

    # Periodic TRIM, not online `discard` (Determinate best-practices § "Don't mount
    # your Nix store with online discard"). Nothing to set: `services.fstrim.enable`
    # is the pinned nixpkgs default (weekly), and root does not mount with `discard`.

    # THE SYSTEMD INITRD'S `linux` TERMINFO ENTRY IS UNREACHABLE WHEN BUILT ON
    # THE MAC, so drop it. Without this, EVERY build of a systemd-initrd host
    # (nixos's toplevel AND build-vm) dies in
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
    # a per-entry `enable` (confirmed by evaluating nixos:
    # `...contents."/etc/terminfo/l/linux"` has attrs dlopen/enable/source/target/text).
    # Deliberately NOT `lib.mkForce { }` on the whole attrset (other modules
    # contribute ~28 entries, including /init and /lib), and deliberately NOT
    # re-pointed at `l~nix~case~hack~1/linux` — that path is an artefact of THIS
    # filesystem and would not exist on a case-sensitive store.
    #
    # UNGUARDED: systemd stage-1 is the only initrd since nixpkgs removed the scripted
    # one (26.11), and `boot.initrd.systemd.enable` itself is a removed option now, so
    # even reading it throws.
    #
    # COST: the initrd console loses the `linux` terminfo entry. That matters only
    # to a full-screen program on the early-boot console; nothing here runs one.
    # It also reaches every downstream `lib.mkNixos` consumer, whose store may well
    # be case-sensitive — same cost, nothing else.
    # SCOPE: this patches this instance, not the bug class. Every aarch64-linux
    # build on the Mac that resolves a mixed-case store path by literal name is
    # still exposed. The durable fixes are a case-sensitive store volume (reformat)
    # or substituting the closure from CI — neither taken, operator's call 2026-10-06.
    boot.initrd.systemd.contents."/etc/terminfo/l/linux".enable = false;

    environment.systemPackages = with pkgs; [
      git
      curl
    ];

    # Default install-era stateVersion for the NixOS hosts that import this module.
    # mkDefault lets a host pin its own.
    system.stateVersion = lib.mkDefault "24.05";
  };
}
