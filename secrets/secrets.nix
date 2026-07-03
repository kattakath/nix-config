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

  # Host-scoped tunnel creds: personal key (so we can re-encrypt) + the host key
  # (so the host decrypts at activation for services.cloudflared).
  "nixarm-tunnel-creds.age".publicKeys = userKeys ++ [ nixarm ];
  "nixrpi-tunnel-creds.age".publicKeys = userKeys;
}
