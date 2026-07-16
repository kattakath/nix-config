# Single source of truth for the OPERATOR's ed25519 SSH PUBLIC key — the sole
# network login credential across the fleet AND the agenix "keep editable"
# recipient. This is a PUBLIC key (safe to commit; publishing it grants nothing),
# so the secret-free nixpi sdImage and nixvm installer ISO embed it freely.
#
# Imported as a plain string (this file evaluates to the bare key) by every
# consumer, so rotating the key touches ONE file instead of four in lockstep:
#   flake.nix                  → operatorSshKey → mkNixos specialArgs
#   modules/nixos/core.nix     → users.users.<op>.openssh.authorizedKeys.keys
#   hosts/nixvm-installer.nix  → the installer ISO's nixos authorizedKeys
#   secrets/secrets.nix        → the `operator` agenix recipient
"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VALx6Y6OERWlWWvudcTUEO29BMFl3bbGwoVSTGsS"
