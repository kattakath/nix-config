# Shared NixOS system configuration applied to every NixOS host.
# Platform-specific hardware lives in hosts/<hostname>.nix.
# User environment lives in modules/shared/home.nix (via Home Manager).
#
# ZTIA (Cloudflare Access for Infrastructure) SSH trust — OPT-IN, per host.
# `services.openssh-ca-trust.enable` wires `TrustedUserCAKeys` so sshd accepts
# short-lived certificates minted by Cloudflare's hosted SSH CA in place of
# (or alongside, during coexistence) a static key. `nixpi` opts in
# (hosts/nixpi.nix); `nixvm` does NOT — it stays on the static key as a
# LAN/serial-console sandbox, deliberately untouched by this cutover. See
# docs/tunnel-architecture-and-runbook.md for the full rollout order and
# infra/cloudflare/nixpi-ssh.nix for the Cloudflare-side terranix objects.
{
  config,
  lib,
  pkgs,
  userName,
  ...
}:
let
  caCfg = config.services.openssh-ca-trust;
in
{
  options.services.openssh-ca-trust = {
    enable = lib.mkEnableOption "trust Cloudflare's SSH CA for short-lived ZTIA certificates (TrustedUserCAKeys)";

    caKeyFile = lib.mkOption {
      type = lib.types.path;
      default = ../nixos/cloudflare-ssh-ca.pub;
      description = ''
        Path to the committed Cloudflare SSH CA public key
        (modules/nixos/cloudflare-ssh-ca.pub). Safe to commit — it is a public
        key; TrustedUserCAKeys only ever needs the CA's PUBLIC half. Replace
        the placeholder in that file with the real CA public key output by
        `nix run .#cf-ssh-apply`'s companion CA-generation step (see
        docs/tunnel-architecture-and-runbook.md) BEFORE removing the static
        key on any host.
      '';
    };

    removeStaticKey = lib.mkEnableOption ''
      remove the shared static ed25519 authorizedKeys entry on this host,
      making ZTIA short-lived certificates the ONLY way in over the network.
      LOCKOUT-SAFETY: only flip this after verifying an end-to-end ZTIA login
      from an enrolled client — physical console (getty) and LAN mDNS remain
      regardless, but this is the step that actually retires the network key.
      This is the LAST step of the rollout, not the first
    '';
  };

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
      # Static network key — the legacy authentication path. Removed ONLY when
      # a host explicitly opts into `services.openssh-ca-trust.removeStaticKey`
      # (nixpi, at the end of its ZTIA rollout). Every other host (nixvm) keeps
      # this key untouched: it is a LAN/serial-console sandbox, not part of the
      # ZTIA cutover. Physical console access (getty) is never affected by this
      # option either way — it is a break-glass path independent of sshd.
      openssh.authorizedKeys.keys = lib.mkIf (!caCfg.removeStaticKey) [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
      ];
    };

    services.openssh = {
      enable = true;
      settings = {
        # Keys-only: the SSH endpoint is reachable over the Cloudflare tunnel with
        # no Access/identity layer in front (unless openssh-ca-trust is enabled),
        # so it must not accept any password or keyboard-interactive path.
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
      # TrustedUserCAKeys is emitted via extraConfig (no native `settings`
      # field for it) — verify live that NixOS's append-after-`settings`
      # rendering still authenticates correctly on nixpi once applied; flagged
      # as unconfirmed in the ZTIA research (no conflicting AuthorizedKeys*/
      # AuthorizedPrincipals* directive exists here, so it is expected to work,
      # but test end-to-end before flipping removeStaticKey).
      extraConfig = lib.mkIf caCfg.enable ''
        TrustedUserCAKeys ${caCfg.caKeyFile}
      '';
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
  };
}
