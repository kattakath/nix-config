# `secret <command> …` — the primary, discoverable interface to the macOS
# login-Keychain secret store, in the modern noun-verb CLI shape (git/docker/op
# style). Verbs:
#   secret set  <KEY> [VALUE]   store/rotate (hidden prompt if no VALUE)
#   secret get  <KEY>           print one value on demand (lazy read)
#   secret rm   <KEY>           delete + unregister
#   secret list                 list every registered KEY (from the index)
#   secret load                 reload secrets into the CURRENT shell — SHELL-FUNCTION ONLY
#   secret <KEY>                shorthand for `secret get <KEY>`
#
# `set-secret` / `remove-secret` remain as thin back-compat aliases. The MUTATING
# verbs (set/rm) forward to `set-secret` so the Keychain/index logic lives in ONE
# place; get/list are simple reads done here. macOS-ONLY (the Keychain is
# macOS-only). A companion shell FUNCTION (modules/shared/home.nix) wraps this so
# set/rm/load also update the CURRENT shell's environment — a bare binary cannot
# mutate its parent's env, and `load` is therefore function-only.
{
  writeShellApplication,
  set-secret,
}:
writeShellApplication {
  name = "secret";
  runtimeInputs = [ set-secret ];
  text = ''
    security=/usr/bin/security
    account="$(/usr/bin/id -un)"
    index_service="__set_secret_index__"

    # Usage via printf (not a heredoc): a heredoc terminator inside a Nix
    # indented string is fragile under formatter reindentation.
    usage() {
      printf '%s\n' \
        "usage: secret <command> [args]" \
        "  secret set  <KEY> [VALUE]   store/rotate a secret (hidden prompt if no VALUE)" \
        "  secret get  <KEY>           print a secret's value (lazy read)" \
        "  secret rm   <KEY>           delete a secret and unregister it" \
        "  secret list                 list every registered secret name" \
        "  secret load                 reload secrets into the current shell (shell function only)" \
        "  secret <KEY>                shorthand for 'secret get <KEY>'" \
        "aliases: set-secret == 'secret set'  -  remove-secret == 'secret rm'" >&2
    }

    cmd="''${1:-}"
    case "$cmd" in
      -h | --help)
        usage
        exit 0
        ;;
      "")
        usage
        exit 1
        ;;
      set)
        shift
        exec set-secret "$@"
        ;;
      rm | remove | unset)
        shift
        if [ -z "''${1:-}" ]; then
          echo "secret: rm needs <KEY>. usage: secret rm <KEY>" >&2
          exit 1
        fi
        exec set-secret --remove "$1"
        ;;
      get)
        shift
        if [ -z "''${1:-}" ]; then
          echo "secret: get needs <KEY>. usage: secret get <KEY>" >&2
          exit 1
        fi
        "$security" find-generic-password -a "$account" -s "$1" -w 2>/dev/null
        ;;
      list)
        # Print each registered KEY on its own line. Peel the space-separated
        # index with POSIX parameter expansion (no unquoted word-split, so the
        # linter stays happy under writeShellApplication's `set -euo pipefail`).
        index="$("$security" find-generic-password -a "$account" -s "$index_service" -w 2>/dev/null || true)"
        rest="$index"
        while [ -n "$rest" ]; do
          k="''${rest%% *}"
          rest="''${rest#"$k"}"
          rest="''${rest# }"
          [ -n "$k" ] && echo "$k"
        done
        ;;
      load)
        echo "secret load: only works via the shell function (it must mutate the current shell)." >&2
        echo "  Open a new shell, or run: source ~/.config/secrets/loader.sh" >&2
        exit 1
        ;;
      *)
        # Bare `secret KEY` — treat an unknown first word as a get target. (A
        # secret literally named after a verb needs the explicit `secret get set`.)
        "$security" find-generic-password -a "$account" -s "$cmd" -w 2>/dev/null
        ;;
    esac
  '';
}
