# Shared NixOS system configuration applied to every NixOS host.
# Platform-specific hardware lives in hosts/<hostname>.nix.
# User environment lives in modules/shared/home.nix (via Home Manager).
{ pkgs, username, ... }:
{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      username
    ];
  };

  users.users.${username} = {
    isNormalUser = true;
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

  # agenix uses the host SSH key to decrypt system-level secrets at activation.
  # After first boot: add the host's public key to secrets/secrets.nix and
  # re-encrypt any system secrets (e.g. *-tunnel-creds.age) to that key.
  #
  # HAZARD: this SSH host key IS the age decryption identity for every
  # host-scoped secret. Rotating/replacing it (reinstall, reimage, manual
  # rotation) silently breaks decryption of all of them at next activation —
  # re-run the agenix-host-rekey skill for the host after any host-key change.
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    git
    curl
  ];
}
