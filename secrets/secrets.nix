# agenix rules — declares each committed .age secret and who may decrypt it.
# Consumed ONLY by the `agenix` CLI (agenix -e/-r), never imported into a system
# config. A host-decrypted secret is encrypted to its target HOST's SSH host key
# (so the host decrypts at activation with /etc/ssh/ssh_host_ed25519_key) plus the
# OPERATOR's key (so secrets stay editable). The cloudflared token is the exception:
# it is operator-only and never decrypted on-device (see the note below). Recipients
# are SSH public keys directly — agenix uses age's SSH support, no ssh-to-age step.
#
# Edit a secret:   nix run github:ryantm/agenix -- -e secrets/<name>.age
# Re-key after changing recipients:  … -- -r
let
  # operator (ismailkattakath) — ~/.ssh/id_ed25519.pub; backed up off-machine, kept
  # editable. Single-sourced in ./operator-key.nix (also the fleet's authorizedKeys
  # via flake.nix → core.nix), so a key rotation is one edit there, not four.
  operator = import ./operator-key.nix;
  # NB: nixpi has NO host-key recipient. Its Cloudflare token is not decrypted
  # on-device (a fresh SD flash rotates the host key, which broke that); the vault
  # below is operator-only and the operator plants the token on the FAT FIRMWARE
  # partition instead — see modules/nixos/firmware-provisioning.nix + nixpi-provision.
  # macos host key (/etc/ssh/ssh_host_ed25519_key.pub).
  macos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHztHf3AmsM7Yr6xsP0bv96AyGtdolPvfmRw3RHAaFOB";
in
{
  # nixpi's Cloudflare Tunnel connector token (TUNNEL_TOKEN=…). OPERATOR-ONLY: the
  # operator decrypts it on the Mac to plant on the card's FIRMWARE partition (via
  # `nix run .#nixpi-provision --token`); nixpi never decrypts it on-device.
  "cloudflared-token.age".publicKeys = [
    operator
  ];
  # macos self-hosted GitHub Actions runner PAT.
  "gh-runner-token.age".publicKeys = [
    operator
    macos
  ];
}
