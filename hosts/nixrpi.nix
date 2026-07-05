# NixOS host for Raspberry Pi 4 (aarch64-linux).
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixrpi.config.system.build.sdImage
{
  lib,
  secretsDir,
  ...
}:
{
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

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  networking.useDHCP = true;

  # Cloudflare Tunnel — REMOTELY-MANAGED (token) connector. The tunnel, its
  # public-hostname ingress (nixrpi.kattakath.com → ssh://localhost:22) and the
  # proxied CNAME live in the Cloudflare account (provisioned once by
  # scripts/cf-one-provision.sh). This host only carries the connector token
  # (one line `TUNNEL_TOKEN=…`) via agenix; modules/nixos/cloudflared.nix
  # (imported globally) runs the hardened systemd unit at boot — no login.
  #
  # nixrpi is DURABLE hardware → use approach (a): post-boot rekey, NOT prebake.
  # nixrpi-tunnel-token.age ships encrypted only to the personal key (correct
  # pre-first-boot). After the Pi's first boot, add its own
  # /etc/ssh/ssh_host_ed25519_key.pub as a recipient in secrets/secrets.nix and
  # re-encrypt — run the agenix-host-rekey skill. The Pi's own first-boot key is
  # a unique per-host identity, so no key pinning/injection is needed.
  #
  # HAZARD: SSH host keys double as age identities — rotating/reimaging the Pi's
  # /etc/ssh key silently breaks decryption of every host-scoped .age; re-run
  # agenix-host-rekey after any host-key change.

  raspberry-pi-nix = {
    board = "bcm2711";
  };

  age.secrets."nixrpi-tunnel-token".file = "${secretsDir}/nixrpi-tunnel-token.age";

  # LiteLLM stack — native Postgres + the official DB-capable LiteLLM image as a
  # podman oci-container + a DEDICATED cloudflared connector for the `litellm`
  # tunnel (litellm.kattakath.com, fronted by Cloudflare Access). See
  # modules/nixos/litellm-host.nix. The proxy binds 127.0.0.1:4000 (--network=host)
  # and the connector reaches it over that loopback origin (the tunnel ingress in
  # infra/cloudflare/litellm.nix points at http://localhost:4000).
  #
  # SECRETS (both encrypted to the PERSONAL key only, pre-first-boot — the SD image
  # builds fine without the Pi host key). After the Pi's first boot, add its own
  # /etc/ssh/ssh_host_ed25519_key.pub as a recipient in secrets/secrets.nix and
  # re-encrypt BOTH (run the agenix-host-rekey skill), so the connector + container
  # can decrypt at activation:
  #   - litellm-tunnel-token.age : one line `TUNNEL_TOKEN=…` (dedicated tunnel).
  #   - litellm-env.age          : the SECRET env only (OPENAI_API_KEY,
  #                                LITELLM_MASTER_KEY, GOOGLE_CLIENT_SECRET). The
  #                                non-secret env is inline in the module.
  # Until rekeyed both secrets are inert at eval; the module is no-op-safe on a
  # host that hasn't declared/decrypted them.
  services.litellm-host.enable = true;
  age.secrets."litellm-tunnel-token".file = "${secretsDir}/litellm-tunnel-token.age";
  age.secrets."litellm-env".file = "${secretsDir}/litellm-env.age";

  # Public landing page (Caddy static site on loopback:8787). Served immediately;
  # exposure needs a SEPARATE, DEDICATED "landing" tunnel — provision it and its
  # token per the runbook in infra/cloudflare/landing.nix, then uncomment the
  # secret below (the connector is a no-op until it exists). To move the page to a
  # different host, relocate these two lines.
  services.landing-page.enable = true;
  # age.secrets."landing-tunnel-token".file = "${secretsDir}/landing-tunnel-token.age";

  system.stateVersion = "24.05";
}
