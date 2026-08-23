# agenix rules — declares each committed .age secret and who may decrypt it.
# Consumed ONLY by the `agenix` CLI (agenix -e/-r), never imported into a system
# config. Recipients are SSH public keys directly (age's SSH support, no
# ssh-to-age step). Most secrets here are OPERATOR-ONLY (encrypted to the
# operator's key alone, never decrypted on any host); the `gh-app-*-key`
# entries are the exception — HOST-decrypted at activation, so they also carry
# the `macos` host-key recipient below.
#
# Edit a secret:   nix run github:ryantm/agenix -- -e secrets/<name>.age
# Re-key after changing recipients:  … -- -r
let
  # operator (ismail) — ~/.ssh/id_ed25519.pub; backed up off-machine, kept
  # editable. Single-sourced in ./operator-key.nix (also the fleet's authorizedKeys
  # via flake.nix → core.nix), so a key rotation is one edit there, not four.
  operator = import ./operator-key.nix;
  # macos host key (/etc/ssh/ssh_host_ed25519_key.pub) — re-checked 2026-08-23
  # (revived github-runner module) since the last pinned value here predated a
  # host-key rotation; verify against the live file before reusing this again.
  macos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMh/Us9PkRc8ZegkaoES6/AZNo10Iw8sxGq9uniLpHOK root@macos.local";
in
{
  # nixpi's Cloudflare Tunnel connector token (TUNNEL_TOKEN=…). OPERATOR-ONLY: the
  # operator decrypts it on the Mac to plant on the card's FIRMWARE partition (via
  # `nix run .#nixpi-provision --token`); nixpi never decrypts it on-device (a fresh
  # SD flash rotates the host key — see the firmware-secrets flake).
  "cloudflared-token.age".publicKeys = [
    operator
  ];
  # macos self-hosted GitHub Actions runner's GitHub App private key, for the
  # `dontsell-ai` org (modules/darwin/github-runner.nix, services.macosGithubRunner).
  # 2026-08-23: upgraded from a static PAT to a GitHub App — the App is scoped to
  # ONLY "Organization permissions: Self-hosted runners: Read and write" (not
  # admin:org's much wider bundle), and every registration mints a fresh ~1hr
  # installation token from this key rather than using a long-lived bearer
  # credential directly. Org-level registration — serves every dontsell-ai repo,
  # not just app. Content is the raw .pem downloaded from the App's settings page.
  "gh-app-dontsell-ai-key.age".publicKeys = [
    operator
    macos
  ];
}
