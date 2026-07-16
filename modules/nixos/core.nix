# Shared NixOS system configuration applied to every NixOS host.
# Platform-specific hardware lives in hosts/<hostname>.nix.
# User environment lives in modules/shared/home.nix (via Home Manager).
{
  pkgs,
  lib,
  userName,
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
        userName
      ];
    };

    users.users.${userName} = {
      isNormalUser = true;
      shell = pkgs.zsh;
      extraGroups = [ "wheel" ];
      # The operator's SSH public key — the network login credential. sshd is
      # reachable over the Cloudflare tunnel (nixpi) or the LAN (nixvm); key-only,
      # no password (settings below). Physical console (getty) is an independent
      # break-glass path.
      openssh.authorizedKeys.keys = [ operatorSshKey ];
    };

    services.openssh = {
      enable = true;
      settings = {
        # Keys-only: the SSH endpoint is reachable over the Cloudflare tunnel
        # (nixpi) with no identity layer in front, so it must never accept a
        # password or keyboard-interactive path — the operator key is the boundary.
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
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
    # UTM audit finding (2026-07). Applies to all NixOS hosts.
    zramSwap.enable = true;

    # Automatic store GC + on-the-fly reclaim — these NixOS hosts double as
    # self-hosted CI runners (building e.g. nixpi SD images), so the store must
    # self-trim or it fills the disk. UTM audit follow-up (2026-07).
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
