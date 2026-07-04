let
  userKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
  ];
  # nixarm first-boot host key (agenix-host-rekey): recipient for host-scoped
  # secrets so the host itself can decrypt at activation.
  nixarm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHYPpSbmVt442jdPPCix1D9wuUhVgt2qhUXloDOntPSy root@nixarm";
  # nixamd first-boot host key (agenix-host-rekey 2026-07-04): recipient for
  # host-scoped secrets so the host itself can decrypt at activation.
  nixamd = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH3O+WDH0QvQSLS7WtRHtZl3m2av/AtD0fcjjtLYLGoG root@nixamd";
in
{
  # agenix manages ONLY system/cloudflared host-scoped secrets. Personal tokens
  # are intentionally NOT here — they live in the macOS login Keychain (raw env
  # vars, exported by host-local ~/.zprofile) or via one-time CLI logins
  # (gh/hf/docker/claude). Dropped from agenix to avoid version-control churn on
  # rotation. See secrets/README.

  # Host-scoped cloudflared CONNECTOR TOKEN (remotely-managed tunnel): one line
  # `TUNNEL_TOKEN=…`, decrypted at boot and handed to the hardened
  # cloudflared-connector unit via EnvironmentFile (modules/nixos/cloudflared.nix).
  #
  # UNIFORM MODEL — all three NixOS hosts (nixarm/nixrpi/nixamd) follow the SAME
  # flow. Pre-first-boot, each token is encrypted to the PERSONAL key ONLY (so we
  # can re-encrypt/rotate); there is NO pinned host key baked into any image. After
  # a host's first boot, add its own generated /etc/ssh/ssh_host_ed25519_key.pub as
  # a recipient and re-encrypt the token (run the agenix-host-rekey skill), so the
  # host itself can decrypt at activation. A `<host>-tunnel-token.age` that isn't
  # yet host-rekeyed is inert at eval — it only matters at activation.
  "nixarm-tunnel-token.age".publicKeys = userKeys ++ [ nixarm ];
  "nixrpi-tunnel-token.age".publicKeys = userKeys;

  # nixamd: CF tunnel + DNS reserved, token re-encrypted to BOTH the personal key
  # and nixamd's live host key (agenix-host-rekey 2026-07-04). hosts/nixamd.nix
  # tunnelReady=true; connector activates at boot.
  "nixamd-tunnel-token.age".publicKeys = userKeys ++ [ nixamd ];

  # GitHub Actions self-hosted runner token for nixarm (fine-grained PAT,
  # one raw token line — NO KEY=VALUE wrapper). Encrypted to the personal key
  # pre-first-boot; re-encrypt to nixarm's host key after first boot
  # (agenix-host-rekey) so the runner service can decrypt at activation.
  "nixarm-github-runner-token.age".publicKeys = userKeys ++ [ nixarm ];
}
