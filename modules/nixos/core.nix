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
      PasswordAuthentication = false;
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

  programs.nix-ld.enable = true;

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
