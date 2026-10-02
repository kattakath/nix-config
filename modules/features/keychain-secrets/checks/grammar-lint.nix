# The ONE gate ./tests/grammar.sh can have.
#
# That script is this capsule's functional test for the index grammar, and its
# own header states why it is not a derivation: the Nix build sandbox has no
# login session and no Keychain, so every assertion in it would fail there for
# reasons unrelated to the code. The operator runs it by hand.
#
# "Cannot be RUN in a derivation" was then read as "cannot be CHECKED", and it is
# not: shellcheck needs no Keychain. Measured 2026-10-02 — of the fifteen tracked
# `.sh` files in this repo, this was one of eleven with no gate at all, and the
# only one of those eleven that nothing else covers either (the four
# `.claude/hooks/tests/*.sh` are RUN by claude-config-lint.yml, a required check).
# So until this file landed, a syntax error here was discoverable only by the
# operator running the test and watching bash refuse it.
#
# SHAPE: `drv-snapshot-lint`'s (modules/parts/checks.nix) — shellcheck over a
# SOURCE PATH LITERAL, so the derivation's inputs are ONE FILE plus stdenv, not
# `self`. Measured on the precedent: its drv lists
# `/nix/store/…-drv-snapshot.sh` as a standalone path, so the drvPath moves only
# when the script moves. That is what keeps a lint gate out of
# `scripts/drv-snapshot.sh`'s EXCLUDE_RE (which is for checks that take `self`
# and therefore churn every commit) and makes this a one-time, named row in the
# acceptance baseline.
#
# `script` is an ARGUMENT, not `../tests/grammar.sh`, for the capsule-invariant
# reason ./module-evaluates.nix states: ast-grep/rules/capsule-must-not-reach-out.yml
# forbids `..` in any path literal under modules/features/**, so a leaf is handed
# what it needs by ./../flake-module.nix rather than reaching up for it.
#
# NOT COVERED: that the test's ASSERTIONS are right, or that it still exercises
# the grammar. shellcheck is a syntax and quoting lint. Running it on a real
# macOS session is still the only test of what it claims to test.
{
  pkgs,
  script,
}:
pkgs.runCommand "keychain-secrets-grammar-lint" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
  shellcheck --shell=bash ${script}
  echo "keychain-secrets tests/grammar.sh is shellcheck-clean" > "$out"
''
