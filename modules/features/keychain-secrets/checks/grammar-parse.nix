# The gate ./grammar-lint.nix cannot be: ../tests/grammar.sh needs a real login
# Keychain, so nothing in `nix flake check` ever RAN the index parser. This does,
# with no Keychain at all.
#
# 1. AGREEMENT — every CLI that reads the index carries each line of
#    ../index-grammar.nix verbatim, and defines `read_index`, `tok_env` and
#    `tok_service` exactly once. A hand-copied parser, edited or not, fails here.
# 2. BEHAVIOUR — the shared helpers, sourced with a stub `security` that prints a
#    fixture index, split every token form THE INDEX GRAMMAR allows
#    (../packages/set-secret.nix), pass a non-default keychain through, and turn
#    an unreadable index into an empty one.
#
# Arguments, not `..` paths, for the capsule-invariant reason ./module-evaluates.nix
# states.
{
  pkgs,
  indexGrammar,
  clis,
}:
let
  grammar = pkgs.writeText "index-grammar.sh" indexGrammar;
  # Answers ONLY the exact index read the helpers issue; anything else is a test failure.
  stub = pkgs.writeShellScript "security-stub" ''
    [ "''${STUB_FAIL:-0}" = 1 ] && exit 44
    want=(find-generic-password -a me -s __idx__ -w ''${STUB_KC:+"$STUB_KC"})
    [ "$*" = "''${want[*]}" ] || { echo "stub: unexpected args: $*" >&2; exit 99; }
    printf '%s' 'LEGACY GITLAB_TOKEN=glab:gitlab.com:token =gh:github.com:pat A=b=c'
  '';
  test = pkgs.writeText "grammar-parse-test.sh" ''
    set -euo pipefail
    security=${stub}
    account=me
    index_service=__idx__
    kc=()
    source ${grammar}

    rows() {
      rest="$(read_index)"
      while [ -n "$rest" ]; do
        t="''${rest%% *}"; rest="''${rest#"$t"}"; rest="''${rest# }"
        [ -n "$t" ] || continue
        printf '%s|%s\n' "$(tok_service "$t")" "$(tok_env "$t")"
      done
    }
    expect='LEGACY|LEGACY
    glab:gitlab.com:token|GITLAB_TOKEN
    gh:github.com:pat|
    b=c|A'
    got="$(rows)"
    [ "$got" = "$expect" ] || { printf 'parse mismatch:\n%s\n--- want ---\n%s\n' "$got" "$expect" >&2; exit 1; }

    kc=(/tmp/throwaway.keychain)
    [ "$(STUB_KC=/tmp/throwaway.keychain read_index)" != "" ] || { echo "kc not passed through" >&2; exit 1; }
    kc=()

    [ "$(STUB_FAIL=1 read_index)" = "" ] || { echo "unreadable index not empty" >&2; exit 1; }
  '';
in
pkgs.runCommand "keychain-secrets-grammar-parse" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
  for bin in ${toString clis}; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -qxF -- "$line" "$bin" || { echo "$bin lacks index-grammar.nix's line: $line" >&2; exit 1; }
    done < ${grammar}
    for fn in read_index tok_env tok_service; do
      n="$(grep -cE "^[[:space:]]*$fn\(\) \{" "$bin" || true)"
      [ "$n" = 1 ] || { echo "$bin defines $fn() $n times; the only copy is index-grammar.nix" >&2; exit 1; }
    done
  done
  shellcheck --shell=bash --external-sources ${test}
  bash ${test}
  echo "keychain-secrets: ${toString (builtins.length clis)} CLIs share one index parser, and it parses the fixture" > "$out"
''
