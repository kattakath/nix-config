# The Keychain SERVICE name of the secret index — the one item that lists every
# registered secret (grammar: ./packages/set-secret.nix). ONE binding: the entry
# file and ./module.nix both `import` it and pass it DOWN to every package as
# `indexService`, and ./checks/grammar-lint.nix asserts ./tests/grammar.sh (plain
# bash, so it cannot take a Nix argument) spells the same name.
#
# Changing it ORPHANS every operator's existing index: the CLIs would read an
# empty index under the new name while the old item still holds the real list.
"__set_secret_index__"
