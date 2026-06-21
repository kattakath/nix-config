let
  userKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
  ];
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
}
