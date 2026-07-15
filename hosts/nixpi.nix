# NixOS host for Raspberry Pi 4 (aarch64-linux) — the fleet's LIVE server.
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
#
# SSH ACCESS: over the Cloudflare Tunnel connector below (remotely-managed,
# token-based — no port-forward, no public IP). mDNS (nixpi.local) also works
# on the LAN. The connector token is planted on the SD card's FAT FIRMWARE
# partition (re-planted by the operator after each flash — macOS can write FAT;
# see docs/nixpi-sd-flashing-runbook.md) and copied into a root-only /run file by
# a oneshot before the connector starts. This deliberately does NOT use agenix:
# agenix binds the token to nixpi's SSH host key, but a fresh SD flash mints a new
# host key, so the agenix ciphertext stops decrypting and the tunnel dies — and
# with SSH being cert-only over that tunnel, unrecoverably (the reflash lockout).
# The connector unit retries on failure (Restart=on-failure) so a token refresh
# self-heals.
#
# ZTIA CUTOVER (Cloudflare Access for Infrastructure — short-lived SSH certs):
# COMPLETE. `services.openssh-ca-trust.enable = true` below makes sshd trust
# Cloudflare's hosted SSH CA (modules/nixos/core.nix, TrustedUserCAKeys pointed
# at the committed modules/nixos/cloudflare-ssh-ca.pub), and
# `removeStaticKey = true` drops the legacy static key so network SSH is
# cert-only. This was flipped on ONLY after an end-to-end ZTIA login was
# verified from the enrolled macos WARP client (2026-07-08) — see the
# LOCKOUT-SAFETY comment on the option in modules/nixos/core.nix and the rollout
# order in docs/tunnel-architecture-and-runbook.md. Physical console (getty) is
# unaffected and remains the break-glass path.
# `nixvm` does NOT import this option — it stays on the static key.
{
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
  # connector token is delivered from the SD card's FAT FIRMWARE partition, NOT
  # via agenix. WHY NOT agenix: agenix encrypts the token to nixpi's SSH HOST key,
  # but a NixOS SD image ships no host key, so every fresh flash mints a brand-new
  # random one — after which the agenix ciphertext no longer decrypts and the
  # tunnel never comes up. Network SSH is cert-only OVER that same tunnel, so a
  # dead tunnel means no remote way back in (exactly the reflash lockout we hit).
  # A token file on the FIRMWARE partition sidesteps the host-key coupling: macOS
  # can write that FAT partition, so the operator re-plants the token after each
  # flash (see docs/nixpi-sd-flashing-runbook.md) and the connector comes up on
  # first boot regardless of the freshly-generated host key.
  #
  # The FAT mount is world-readable, so a oneshot copies the token off it into a
  # root-only /run file (0600) BEFORE the connector starts; the connector reads
  # that as its EnvironmentFile (so the secret is never world-readable at rest on
  # the running system, and never on argv / in the store).
  services.cloudflared-connector.enable = true;
  services.cloudflared-connector.tokenFile = "/run/cloudflared-token";

  systemd.services.cloudflared-token-install = {
    description = "Install the Cloudflare connector token from the FIRMWARE partition";
    # Ordered before + pulled in by the connector, and gated on /boot/firmware
    # being mounted (a stage-2 systemd mount, so this all runs well after the FAT
    # partition is available — unlike agenix, which runs pre-systemd).
    before = [ "cloudflared-connector.service" ];
    requiredBy = [ "cloudflared-connector.service" ];
    unitConfig.RequiresMountsFor = "/boot/firmware";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # The planted file holds a single line `TUNNEL_TOKEN=<token>` (the same shape
    # agenix produced). Copied to a root-only 0600 file the connector consumes.
    script = ''
      src=/boot/firmware/cloudflared-token
      dst=/run/cloudflared-token
      if [ -f "$src" ]; then
        install -m600 "$src" "$dst"
      else
        echo "cloudflared-token-install: $src not found — plant a file containing" >&2
        echo "  TUNNEL_TOKEN=<token> on the FIRMWARE partition (see the flashing runbook)." >&2
        exit 1
      fi
    '';
  };

  # ZTIA: trust Cloudflare's SSH CA for short-lived certificates AND drop the
  # legacy static key, making network SSH cert-only. End-to-end ZTIA login was
  # verified 2026-07-08 (WARP -> Cloudflare -> tunnel -> nixpi, authenticated by
  # the CA-signed short-lived cert with NO local key offered), so per the rollout
  # order in docs/tunnel-architecture-and-runbook.md this final step is now safe.
  # Physical console (getty) is unaffected and remains the break-glass path.
  services.openssh-ca-trust.enable = true;
  services.openssh-ca-trust.removeStaticKey = true;

  # Local reverse-proxy/router, sitting behind the tunnel. Today it serves only
  # the public kattakath.com static landing page; future services front new
  # virtualHosts entries here rather than a new tunnel per-service.
  services.caddy-proxy = {
    enable = true;
    virtualHosts."kattakath.com".root = ../packages/landing;
  };

  system.stateVersion = "24.05";
}
