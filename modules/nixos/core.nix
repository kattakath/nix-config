# Shared NixOS system configuration applied to every NixOS host.
# Platform-specific hardware lives in hosts/<hostname>.nix.
# User environment lives in modules/shared/home.nix (via Home Manager).
{
  pkgs,
  lib,
  loginName,
  operatorSshKey,
  ...
}:
{
  config = {
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
      # LOOPBACK ONLY on every host this module configures (see listenAddresses
      # below), so there is no LAN path on nixpi OR nixvm: the only network route
      # in is the tunnel connector, which terminates on-host and dials
      # localhost:22. Key-only, no password. Physical console (getty) is an
      # independent break-glass path.
      openssh.authorizedKeys.keys = [ operatorSshKey ];
    };

    services.openssh = {
      enable = true;

      # sshd's own module opens its ports in the firewall by default
      # (nixpkgs nixos/modules/services/networking/ssh/sshd.nix:874 —
      # `allowedTCPPorts = optionals cfg.openFirewall cfg.ports`, option at :312).
      # Clearing allowedTCPPorts below is NOT enough on its own: this option is
      # what actually keeps 22 shut, and it is the upstream-supported knob rather
      # than a mkForce fight with the module.
      openFirewall = false;

      # LOOPBACK ONLY — sshd is reachable exclusively through the Cloudflare
      # Tunnel, which terminates ON this host and dials localhost:22. Binding
      # the wildcard address would leave port 22 answering on the LAN, where
      # the Access application in front of nixpi.<domain> is NOT consulted and
      # no Access log is produced: an edge-only identity layer that anything on
      # the same network segment can simply walk around. Both loopback families
      # are bound because `localhost` may resolve to ::1 first.
      # Break-glass if the tunnel is ever down: the physical console (getty).
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

    networking.firewall = {
      enable = true;
      # Port 22 is deliberately NOT opened: sshd binds loopback only (above) and
      # the tunnel connector reaches it from on-host. Opening it would re-expose
      # the Access bypass that listenAddresses closes.
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
      libraries = import ../shared/nix-ld-libraries.nix pkgs;
    };

    programs.zsh.enable = true;

    security.sudo.wheelNeedsPassword = false;

    # zram compressed swap — cheap in-RAM overflow so a build/memory spike degrades
    # instead of triggering a hard OOM-kill (swapDevices is empty on these guests).
    # audit finding (2026-07). Applies to all NixOS hosts.
    zramSwap.enable = true;

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

    environment.systemPackages = with pkgs; [
      git
      curl
    ];

    # Shared install-era stateVersion for every NixOS host (both import this
    # module). mkDefault lets a future host pin a different one if ever needed.
    system.stateVersion = lib.mkDefault "24.05";
  };
}
