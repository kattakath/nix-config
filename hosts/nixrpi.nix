# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
#
# SSH ACCESS: via mDNS (nixrpi.local) directly — no Cloudflare SSH tunnel needed.
# Service tokens (LiteLLM tunnel, landing tunnel) live at /etc/secrets/ — place
# manually after provisioning. The connector units retry on failure (Restart=on-failure)
# so dropping files in after first boot self-heals without a rebuild.
{
  lib,
  ...
}:
{
  imports = [
    ../modules/nixos/cloudflared.nix
    ../modules/nixos/litellm-host.nix
    ../modules/nixos/landing.nix
  ];

  networking.hostName = "nixrpi";

  # nixpkgs enables systemd stage-1 by default (boot.initrd.systemd.enable), and
  # its TPM2 support (nixos/modules/system/boot/systemd/tpm2.nix) forces the
  # `tpm-tis` + `tpm-crb` kernel modules into boot.initrd.availableKernelModules.
  # The raspberry-pi-nix `linux-rpi` kernel builds neither as a loadable module,
  # and makeModulesClosure treats availableKernelModules as REQUIRED root modules
  # (boot.initrd.allowMissingModules defaults false) — so the missing module is a
  # FATAL `modprobe: Module tpm-crb not found`, failing linux-rpi-*-modules-shrunk.
  # The Pi 4 has no TPM, so disable initrd TPM2 support at the source (removes
  # both modules). nixarm is untouched: it never imports this profile, and its
  # generic kernel builds the full TPM stack anyway.
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

  # SSH via mDNS (nixrpi.local) — no Cloudflare tunnel connector needed for SSH.
  # Enable this and provision a token at /etc/secrets/cloudflared-token if a
  # dedicated SSH tunnel is ever added.
  services.cloudflared-connector.enable = false;

  # LiteLLM stack — native Postgres + the official DB-capable LiteLLM image as a
  # podman oci-container + a DEDICATED cloudflared connector for the `litellm`
  # tunnel (litellm.kattakath.com, fronted by Cloudflare Access). See
  # modules/nixos/litellm-host.nix. The proxy binds 127.0.0.1:4000 (--network=host)
  # and the connector reaches it over that loopback origin (the tunnel ingress in
  # infra/cloudflare/litellm.nix points at http://localhost:4000).
  #
  # SECRETS: place files manually after first boot — do NOT commit to git.
  #   /etc/secrets/litellm-tunnel-token  — one line: TUNNEL_TOKEN=<token>
  #   /etc/secrets/litellm-env           — KEY=VALUE pairs: OPENAI_API_KEY,
  #                                        LITELLM_MASTER_KEY, GOOGLE_CLIENT_SECRET
  # Both units retry on failure so placing files after first boot self-heals.
  services.litellm-host.enable = true;

  # Public landing page (Caddy static site on loopback:8787). Served immediately;
  # exposure needs a SEPARATE, DEDICATED "landing" tunnel — provision it and place
  # its token at /etc/secrets/landing-tunnel-token (one line: TUNNEL_TOKEN=<token>)
  # per the runbook in infra/cloudflare/landing.nix. The connector retries until
  # the file appears — no rebuild needed. To move the page to a different host,
  # relocate these lines.
  services.landing-page.enable = true;

  system.stateVersion = "24.05";
}
