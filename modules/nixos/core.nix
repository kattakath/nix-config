# Shared NixOS system configuration applied to every NixOS host.
# Platform-specific hardware lives in hosts/<hostname>.nix.
# User environment lives in modules/shared/home.nix (via Home Manager).
{ pkgs, userName, ... }:
{
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
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      # Keys-only: the SSH endpoint is reachable over the Cloudflare tunnel with
      # no Access/identity layer in front, so it must not accept any password or
      # keyboard-interactive path.
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
  # (The Home-Manager shim in modules/linux/nix-ld.nix stays inert here and only
  # fires for standalone HM on non-NixOS Linux.)
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
}
