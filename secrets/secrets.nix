# agenix rules — declares each committed .age secret and who may decrypt it.
# Consumed ONLY by the `agenix` CLI (agenix -e/-r), never imported into a system
# config. agenix here is an OPERATOR-ONLY VAULT: the only secret is encrypted to the
# operator's key alone and is never decrypted on any host — no host-key recipients,
# nothing host-decrypted at activation. Recipients are SSH public keys directly
# (age's SSH support, no ssh-to-age step).
#
# Edit a secret:   nix run github:ryantm/agenix -- -e secrets/<name>.age
# Re-key after changing recipients:  … -- -r
let
  # operator (ismailkattakath) — ~/.ssh/id_ed25519.pub; backed up off-machine, kept
  # editable. Single-sourced in ./operator-key.nix (also the fleet's authorizedKeys
  # via flake.nix → core.nix), so a key rotation is one edit there, not four.
  operator = import ./operator-key.nix;
in
{
  # nixpi's Cloudflare Tunnel connector token (TUNNEL_TOKEN=…). OPERATOR-ONLY: the
  # operator decrypts it on the Mac to plant on the card's FIRMWARE partition (via
  # `nix run .#nixpi-provision --token`); nixpi never decrypts it on-device (a fresh
  # SD flash rotates the host key — see modules/nixos/firmware-provisioning.nix).
  "cloudflared-token.age".publicKeys = [
    operator
  ];
}
