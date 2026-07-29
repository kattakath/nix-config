# Single source of truth for the OPERATOR's ed25519 SSH PUBLIC key — the sole
# network login credential across the fleet AND the agenix "keep editable"
# recipient. This is a PUBLIC key (safe to commit; publishing it grants nothing),
# so the secret-free nixpi sdImage embeds it freely.
#
# Imported as a plain string (this file evaluates to the bare key) by every
# consumer, so rotating the key touches ONE file instead of several in lockstep:
#   flake.nix                  → operatorSshKey → mkNixos specialArgs + HM
#   modules/nixos/core.nix     → users.users.<op>.openssh.authorizedKeys.keys
#   modules/shared/home.nix    → ~/.ssh/allowed_signers (git SSH signature trust)
#   secrets/secrets.nix        → the `operator` agenix recipient
#
# After rotation also re-register the pubkey on GitHub as a *Signing* key
# (`gh ssh-key add --type signing …`) — Authentication alone does not verify commits.
"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzKz1KIVlsRD4uxpG0QgM2SCy4pI+fwjf57U12AH2vY"
