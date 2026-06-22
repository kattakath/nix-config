let
  userKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
  ];

  # Host SSH keys (from /etc/ssh/ssh_host_ed25519_key.pub on first boot).
  # System-level secrets must be encrypted to the host key so agenix can decrypt
  # them at activation (age.identityPaths = /etc/ssh/ssh_host_ed25519_key).
  nixbox = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8vllaJpgw3RoP9dmV4pY1sgXUqX41wEREmxbF40OGa";
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

  # Host-scoped: both the personal key (so we can re-encrypt) and the host key
  # (so nixbox can decrypt at activation for services.cloudflared).
  "nixbox-tunnel-creds.age".publicKeys = userKeys ++ [ nixbox ];
  "nixrpi-tunnel-creds.age".publicKeys = userKeys;
}
