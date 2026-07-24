# `remove-secret <KEY>` — delete a secret from the macOS login Keychain and
# unregister it from the set-secret index. A thin, discoverable alias for
# `set-secret --remove <KEY>` (packages/set-secret.nix), symmetric with the
# `set-secret` command so setting and removing are equally first-class.
# macOS-ONLY: the Keychain is macOS-only.
#
# Like set-secret, a companion shell FUNCTION (modules/shared/home.nix) wraps
# this so a `remove-secret KEY` at the prompt ALSO unsets the value from the
# CURRENT shell (a bare binary can't mutate its parent's env). Run bare
# (`nix run .#remove-secret -- KEY`) it only mutates the Keychain. All the real
# logic lives once in set-secret; this just forwards to `--remove`.
{
  writeShellApplication,
  set-secret,
}:
writeShellApplication {
  name = "remove-secret";
  runtimeInputs = [ set-secret ];
  text = ''
    if [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
      echo "usage: remove-secret <KEY>"
      echo "  Deletes KEY from the macOS login Keychain (if present) and unregisters"
      echo "  it from the set-secret index. Alias for 'set-secret --remove <KEY>'."
      echo "  Use the remove-secret shell function to also unset it from the current"
      echo "  shell immediately."
      exit 0
    fi
    exec set-secret --remove "$@"
  '';
}
