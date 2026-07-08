# NixOS host for Raspberry Pi 4 (aarch64-linux) — the fleet's LIVE server.
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
#
# SSH ACCESS: over the Cloudflare Tunnel connector below (remotely-managed,
# token-based — no port-forward, no public IP). mDNS (nixpi.local) also works
# on the LAN. The connector token is delivered by sops-nix (encrypted in
# ../secrets/nixpi.yaml, committed to git, decrypted at activation with nixpi's
# own SSH host key) — no hand-placed /etc/secrets file. The connector unit
# retries on failure (Restart=on-failure) so a token refresh self-heals.
#
# ZTIA CUTOVER (Cloudflare Access for Infrastructure — short-lived SSH certs):
# `services.openssh-ca-trust.enable = true` below makes sshd trust Cloudflare's
# hosted SSH CA (modules/nixos/core.nix, TrustedUserCAKeys pointed at the
# committed modules/nixos/cloudflare-ssh-ca.pub). `removeStaticKey` is left
# OFF here deliberately — see the LOCKOUT-SAFETY comment on that option in
# modules/nixos/core.nix and the rollout order in
# docs/tunnel-architecture-and-runbook.md. Flip it to true ONLY after an
# end-to-end ZTIA login has been verified from an enrolled client; physical
# console (getty) is unaffected either way and remains the break-glass path.
# `nixvm` does NOT import this option — it stays on the static key.
{
  config,
  lib,
  ...
}:
{
  imports = [
    ../modules/nixos/cloudflared.nix
    ../modules/nixos/caddy-proxy.nix
  ];

  networking.hostName = "nixpi";

  # nixpkgs enables systemd stage-1 by default (boot.initrd.systemd.enable), and
  # its TPM2 support (nixos/modules/system/boot/systemd/tpm2.nix) forces the
  # `tpm-tis` + `tpm-crb` kernel modules into boot.initrd.availableKernelModules.
  # The raspberry-pi-nix `linux-rpi` kernel builds neither as a loadable module,
  # and makeModulesClosure treats availableKernelModules as REQUIRED root modules
  # (boot.initrd.allowMissingModules defaults false) — so the missing module is a
  # FATAL `modprobe: Module tpm-crb not found`, failing linux-rpi-*-modules-shrunk.
  # The Pi 4 has no TPM, so disable initrd TPM2 support at the source (removes
  # both modules).
  boot.initrd.systemd.tpm2.enable = lib.mkForce false;

  # CONFIRMED BOOT FIX: use the SCRIPTED (bash) initrd, not systemd-initrd.
  # nixpkgs enables systemd stage-1 (boot.initrd.systemd.enable) by default, but on
  # the raspberry-pi-nix `linux-rpi` kernel it HANGS stage-1 mounting the real root
  # at /sysroot (the Pi never reaches stage-2 / a login). The classic scripted
  # initrd mounts /sysroot and hands off reliably on this kernel, so force it off.
  # mkForce because nixpkgs sets the default to true; keep this OFF forever — a
  # config that reintroduces systemd-initrd will not reboot on this hardware.
  boot.initrd.systemd.enable = lib.mkForce false;

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  networking.useDHCP = true;

  raspberry-pi-nix = {
    board = "bcm2711";
  };

  # SSH over the Cloudflare Tunnel — loginless, token-based connector. The
  # connector token is now delivered by sops-nix (committed encrypted in
  # ../secrets/nixpi.yaml, decrypted at activation with nixpi's own SSH host key)
  # instead of a hand-placed /etc/secrets file — see below.
  services.cloudflared-connector.enable = true;
  services.cloudflared-connector.tokenFile = config.sops.secrets."cloudflared-token".path;

  # sops-nix: decrypt ../secrets/nixpi.yaml at activation using this host's SSH
  # host key (converted to an age identity at runtime). The `cloudflared-token`
  # secret materialises at /run/secrets/cloudflared-token (root-only, mode 0400)
  # as `TUNNEL_TOKEN=<token>`, consumed as the connector unit's EnvironmentFile.
  # Editing: `sops secrets/nixpi.yaml` from the devShell (recipients in .sops.yaml).
  sops = {
    defaultSopsFile = ../secrets/nixpi.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."cloudflared-token" = {
      # Restart the connector when the token changes (e.g. tunnel re-provisioned).
      restartUnits = [ "cloudflared-connector.service" ];
    };
  };

  # ZTIA: trust Cloudflare's SSH CA for short-lived certificates. Coexists
  # with the static key above until the CA-cert path is verified end-to-end —
  # see the header comment and docs/tunnel-architecture-and-runbook.md.
  # removeStaticKey stays false (default) until then; this is the LAST step,
  # not this one.
  services.openssh-ca-trust.enable = true;

  # Local reverse-proxy/router, sitting behind the tunnel. Today it serves only
  # the public kattakath.com static landing page; future services front new
  # virtualHosts entries here rather than a new tunnel per-service.
  services.caddy-proxy = {
    enable = true;
    virtualHosts."kattakath.com".root = ../packages/landing;
  };

  system.stateVersion = "24.05";
}
