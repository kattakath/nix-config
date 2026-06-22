let
  userKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
  ];

  # Host SSH key — PINNED offline (approach b), so a prebuilt image can ship with
  # the matching private key pre-injected at /etc/ssh/ssh_host_ed25519_key. This
  # lets agenix decrypt host-scoped secrets at first-boot activation with ZERO
  # logins and no in-VM rebuild. The private half lives only as ciphertext in
  # secrets/nixbox-hostkey.age (encrypted to userKeys); it is injected into the
  # image's ext4 root post-build (see the nixbox prebake skill). NEVER commit the
  # plaintext private key and NEVER add nixbox-hostkey.age to any host's
  # age.secrets (it is build-time-only material).
  nixbox = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBr/13nhmuy8jClbBf+yPFaiy2j8VELUCVbNaG4fnlGG root@nixbox";
in
{
  "github-token.age".publicKeys = userKeys;
  "hf-token.age".publicKeys = userKeys;
  "claude-code-oauth-token.age".publicKeys = userKeys;
  "aws-bearer-token-bedrock.age".publicKeys = userKeys;
  "dockerhub-username.age".publicKeys = userKeys;
  "dockerhub-token.age".publicKeys = userKeys;
  "cloudflare-api-token.age".publicKeys = userKeys;
  "civitai-api-token.age".publicKeys = userKeys;
  "runpod-api-key.age".publicKeys = userKeys;
  "vast-api-key.age".publicKeys = userKeys;
  "litellm-proxy-api-base.age".publicKeys = userKeys;
  "litellm-proxy-api-key.age".publicKeys = userKeys;
  "gitlab-token.age".publicKeys = userKeys;

  # Build-time only: the pinned host PRIVATE key, encrypted to the personal key
  # so it can be decrypted and injected into the image. Do NOT wire this into
  # any host's age.secrets.
  "nixbox-hostkey.age".publicKeys = userKeys;

  # Host-scoped: both the personal key (so we can re-encrypt) and the pinned host
  # key (so nixbox can decrypt at activation for services.cloudflared).
  "nixbox-tunnel-creds.age".publicKeys = userKeys ++ [ nixbox ];
  "nixrpi-tunnel-creds.age".publicKeys = userKeys;
}
