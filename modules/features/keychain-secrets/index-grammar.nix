# The index grammar's shell PARSER halves — ONE copy, interpolated into every CLI
# that reads the index (set-secret, secret, the secrets-* backend), the same way
# ./index-service.nix's name is passed down as `indexService`. The grammar itself
# is THE INDEX GRAMMAR in ./packages/set-secret.nix; three hand-copied parsers were
# how "they MUST agree" stayed a comment. ./checks/grammar-parse.nix runs these
# helpers over a fixture index and fails if any CLI defines its own copy.
#
# The caller's script defines `security`, `account`, `index_service` and the `kc`
# array before using them. module.nix's loader keeps its own `__ss_`-prefixed
# parse: it runs inside the interactive shell, where these names would leak.
''
  read_index() {
    "$security" find-generic-password -a "$account" -s "$index_service" -w "''${kc[@]}" 2>/dev/null || true
  }

  # Index token halves. Split on the FIRST '='; a bare token (no '=') is the
  # legacy self-binding form, where ENV == SERVICE.
  tok_env() { case "$1" in *=*) printf '%s' "''${1%%=*}" ;; *) printf '%s' "$1" ;; esac; }
  tok_service() { case "$1" in *=*) printf '%s' "''${1#*=}" ;; *) printf '%s' "$1" ;; esac; }
''
