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
  # operator (ismailkattakath) — ~/.ssh/id_ed25519.pub; backed up off-machine, kept editable.
  operator = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS";
  # NB: nixpi has NO host-key recipient. Its Cloudflare token is not decrypted
  # on-device (a fresh SD flash rotates the host key, which broke that); the vault
  # below is operator-only and the operator plants the token on the FAT FIRMWARE
  # partition instead — see modules/nixos/firmware-provisioning.nix + nixpi-provision.
  # macos host key (/etc/ssh/ssh_host_ed25519_key.pub).
  macos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBVj8AMmTJYHMe8zJCfvTEHEog8E+FEiE5Fob3uhwiau";
  # nixvm host key (/etc/ssh/ssh_host_ed25519_key.pub). PRE-GENERATED on the Mac and
  # planted at install time via `nixos-anywhere --extra-files`, rather than read off a
  # running VM. That ordering is the whole trick: the recipient here is correct BEFORE
  # nixvm first boots, so agenix can decrypt gh-runner-token-nixvm.age on boot #1 and
  # the CI runner self-registers. Let the VM generate its own key instead and the
  # recipient is stale, agenix cannot decrypt, and the runner silently never starts
  # while the VM otherwise looks perfectly healthy.
  nixvm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII6m9mWQfHBabBEDrKCmWs+n8zldLH9sVAu+nRDwR0vL";
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
  # nixvm self-hosted GitHub Actions runner PAT (github-nix-ci).
  "gh-runner-token-nixvm.age".publicKeys = [
    operator
    nixvm
  ];
}
