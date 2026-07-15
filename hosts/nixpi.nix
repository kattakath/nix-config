# NixOS host for Raspberry Pi 4 (aarch64-linux) — the fleet's LIVE server.
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
#
# SSH ACCESS: over the Cloudflare Tunnel connector below (remotely-managed,
# token-based — no port-forward, no public IP). mDNS (nixpi.local) also works
# on the LAN. Wi-Fi is provisioned the same way as the token (a wpa_supplicant.conf
# planted on the FIRMWARE partition — see the wifi block below), so a headless nixpi
# reaches nixpi.kattakath.com over the tunnel from first boot with no LAN cable,
# keyboard, or monitor. The connector token is planted on the SD card's FAT FIRMWARE
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
  pkgs,
  ...
}:
{
  imports = [
    ../modules/nixos/cloudflared.nix
    ../modules/nixos/caddy-proxy.nix
    ../modules/nixos/firmware-provisioning.nix
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

  # SSH over the Cloudflare Tunnel — loginless, token-based connector. Both the
  # connector token AND the Wi-Fi credentials are delivered from the SD card's FAT
  # FIRMWARE partition via `services.firmwareProvisioning`
  # (modules/nixos/firmware-provisioning.nix), NOT agenix. WHY NOT agenix: it
  # encrypts to nixpi's SSH HOST key, but a fresh SD flash mints a new host key, so
  # the ciphertext stops decrypting and the tunnel dies — and with SSH being
  # cert-only OVER that tunnel, unrecoverably (the reflash lockout). A file on the
  # macOS-writable FAT partition is immune to host-key rotation; the operator
  # re-plants it per flash (the `nixpi-provision` flake app — see
  # docs/nixpi-sd-flashing-runbook.md). Each planted file is copied into a root-only
  # /run file before its consumer starts, so the secret is never world-readable at
  # rest, on argv, or in the store.
  services.cloudflared-connector.enable = true;
  services.cloudflared-connector.tokenFile = "/run/cloudflared-token";

  services.firmwareProvisioning.files = {
    # Connector token (`TUNNEL_TOKEN=<token>`). REQUIRED — the connector cannot start
    # without it, so the install unit fails (and blocks the connector) if it is absent.
    cloudflared-token = {
      source = "cloudflared-token";
      target = "/run/cloudflared-token";
      required = true;
      before = [ "cloudflared-connector.service" ];
      requiredBy = [ "cloudflared-connector.service" ];
    };
    # Wi-Fi so a headless nixpi (no LAN/keyboard/monitor) associates and reaches
    # nixpi.kattakath.com from first boot. Plant a standard wpa_supplicant.conf that
    # carries `country=` (the Pi 4 radio is rfkill-blocked without a regulatory
    # domain) and a `network={ ssid=…; psk=… }` block. OPTIONAL: absent ⇒ the units
    # skip cleanly, leaving LAN-only (eth0 stays DHCP as a fallback). The Pi 4
    # brcmfmac driver + 43455 firmware/NVRAM already ship in the closure; only the
    # credentials are planted.
    wifi = {
      source = "wpa_supplicant.conf";
      target = "/run/wpa_supplicant-firmware.conf";
      before = [ "wpa_supplicant-firmware.service" ];
      postInstall = "${pkgs.util-linux}/bin/rfkill unblock wifi || true";
    };
  };

  # Wi-Fi consumer: associate wlan0 from the planted config; dhcpcd (networking.useDHCP)
  # then leases it. Skips cleanly (ConditionPathExists) when no config was planted.
  systemd.services.wpa_supplicant-firmware = {
    description = "wpa_supplicant on wlan0 (config planted on FIRMWARE)";
    after = [ "firmware-file-wifi.service" ];
    wants = [ "firmware-file-wifi.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/run/wpa_supplicant-firmware.conf";
    serviceConfig = {
      ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -c /run/wpa_supplicant-firmware.conf -i wlan0";
      Restart = "on-failure";
      RestartSec = 5;
    };
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
