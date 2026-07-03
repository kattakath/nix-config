let
  userKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
  ];

  # Host SSH key — PINNED offline (approach b), so a prebuilt image can ship with
  # the matching private key pre-injected at /etc/ssh/ssh_host_ed25519_key. This
  # lets agenix decrypt host-scoped secrets at first-boot activation with ZERO
  # logins and no in-VM rebuild. The private half lives only as ciphertext in
  # secrets/nixarm-hostkey.age (encrypted to userKeys); it is injected into the
  # image's ext4 root post-build (see the nixarm-prebake-hostkey skill). NEVER
  # commit the plaintext private key and NEVER add nixarm-hostkey.age to any
  # host's age.secrets (it is build-time-only material).
  nixarm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBr/13nhmuy8jClbBf+yPFaiy2j8VELUCVbNaG4fnlGG root@nixarm";
in
{
  # agenix manages ONLY system/cloudflared host-scoped secrets. Personal tokens
  # are intentionally NOT here — they live in the macOS login Keychain (raw env
  # vars, exported by host-local ~/.zprofile) or via one-time CLI logins
  # (gh/hf/docker/claude). Dropped from agenix to avoid version-control churn on
  # rotation. See secrets/README.

  # Build-time only: the pinned host PRIVATE key, encrypted to the personal key
  # so it can be decrypted and injected into the image. Do NOT wire this into
  # any host's age.secrets.
  "nixarm-hostkey.age".publicKeys = userKeys;

  # Host-scoped cloudflared CONNECTOR TOKEN (remotely-managed tunnel): one line
  # `TUNNEL_TOKEN=…`, decrypted at boot and handed to the hardened
  # cloudflared-connector unit via EnvironmentFile (modules/nixos/cloudflared.nix).
  # Recipients: the personal key (so we can re-encrypt/rotate) + the host key (so
  # the host itself decrypts at activation). nixarm PINS its host key offline
  # (prebake), so its token is encrypted to that pinned key now. nixrpi is DURABLE
  # hardware — pre-first-boot its token is encrypted to the personal key only, and
  # the Pi's own /etc/ssh host key is added as a recipient post-boot via the
  # agenix-host-rekey skill. nixrpi-tunnel-token.age does not exist until nixrpi is
  # provisioned; a missing .age is inert at eval and only matters at activation.
  "nixarm-tunnel-token.age".publicKeys = userKeys ++ [ nixarm ];
  "nixrpi-tunnel-token.age".publicKeys = userKeys;

  # nixamd: CF tunnel + DNS reserved now, token encrypted to the personal key
  # only (no real host / host key yet). hosts/nixamd.nix keeps tunnelReady=false
  # so the connector stays inert; when nixamd becomes a real host, add its
  # /etc/ssh host key here and re-encrypt (agenix-host-rekey), then flip the flag.
  "nixamd-tunnel-token.age".publicKeys = userKeys;
}
