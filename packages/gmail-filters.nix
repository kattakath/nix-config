# OPERATOR-ONLY: installed only on the operator's Mac (isMacosHost, modules/home/default.nix).
# `gmail-filters <login|download|diff|test|apply> [gmailctl args]` — Gmail filters and labels
# as gmailctl Jsonnet (ADR-012 § 3 row 3, § 5 step 4). A thin wrapper; gmailctl does the work.
#
# WHERE EACH PIECE LIVES, and why it is split three ways:
#   * The FILTER FILE is DATA (addresses, senders, labels), so it never enters this repo.
#     It is `config.jsonnet` in $GMAIL_FILTERS_DIR (default $XDG_CONFIG_HOME/nix-config/gmail),
#     a directory the operator symlinks to a Drive folder, like the nixpi Wi-Fi roster.
#     gmailctl resolves Jsonnet imports from that directory (its FileImporter's JPaths).
#   * The OAuth CLIENT is the Internal Desktop client the google-workspace-mcp plugin already
#     uses, read from the login Keychain (GMAIL_OAUTH_CLIENT_ID / _SECRET) through
#     `secret exec`. gmailctl only reads a `credentials.json` file, so each run renders one
#     into a private temp dir (umask 077) and deletes it on exit: the Keychain stays the one
#     source of truth, and no copy outlives the run.
#   * The OAuth TOKEN (a refresh token, so a secret) is written by gmailctl itself. It lives
#     0600 in $XDG_STATE_HOME/gmail-filters/token.json — local, never Drive, never the repo.
#     The temp config dir links `token.json` there, so `login` writes it through the link.
#
# gmailctl wants credentials, token and config in ONE `--config` directory. Pointing that
# at Drive would put the secrets in Drive; pointing it at a local dir would put the data
# outside Drive. Hence the temp dir plus `-f`/`-o` for the filter file.
#
# `apply` is gmailctl's own: it prints the diff and asks before it writes anything.
#
# upstream-first: grepped the pinned home-manager modules/ for gmailctl — 0 files, no
# module exists → custom wrapper. The tool itself is nixpkgs' gmailctl (ADR-012 picked
# it; `nix search nixpkgs gmail` also lists haskellPackages.google-mail-filters, an
# unmaintained XML generator with no diff or apply). No package owns "gmailctl config in
# a synced folder, credentials from the macOS Keychain" (same search: no wrapper).
{
  writeShellApplication,
  coreutils,
  gmailctl,
  jq,
}:
let
  run = writeShellApplication {
    name = "gmail-filters-run";
    runtimeInputs = [
      coreutils
      gmailctl
      jq
    ];
    text = ''
      usage() {
        echo "usage: gmail-filters <login|download|diff|test|apply> [gmailctl args]" >&2
        echo "  login     OAuth consent in the browser; stores the token locally (0600)" >&2
        echo "  download  write the live filters to the filter file (refuses to overwrite; --force)" >&2
        echo "  diff      show what apply would change (read-only)" >&2
        echo "  test      run the filter file's own tests (offline)" >&2
        echo "  apply     gmailctl apply: shows the diff and asks before writing" >&2
      }
      verb="''${1:-}"
      [ -n "$verb" ] || { usage; exit 64; }
      shift

      dir="''${GMAIL_FILTERS_DIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/nix-config/gmail}"
      file="$dir/config.jsonnet"
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/gmail-filters"

      umask 077
      mkdir -p "$state"
      chmod 700 "$state"
      cfg=$(mktemp -d "''${TMPDIR:-/tmp}/gmail-filters.XXXXXX")
      trap 'rm -rf "$cfg"' EXIT
      # $ENV, not --arg: an --arg value sits in jq's argv, readable by any local process
      # for the life of the call (ps). jq reads both straight from the environment, so
      # check they are set first (`:` is a builtin: no exec, no argv) — $ENV.X is null, not an error.
      : "''${GMAIL_FILTERS_CLIENT_ID:?}" "''${GMAIL_FILTERS_CLIENT_SECRET:?}"
      jq -n '{
        installed: {
          client_id: $ENV.GMAIL_FILTERS_CLIENT_ID,
          client_secret: $ENV.GMAIL_FILTERS_CLIENT_SECRET,
          auth_uri: "https://accounts.google.com/o/oauth2/auth",
          token_uri: "https://oauth2.googleapis.com/token",
          redirect_uris: ["http://localhost"]
        }
      }' > "$cfg/credentials.json"
      ln -s "$state/token.json" "$cfg/token.json"

      need_dir() {
        if [ ! -d "$dir" ]; then
          echo "gmail-filters: $dir does not exist. Symlink it to the Drive folder that holds config.jsonnet" >&2
          echo "  (or set GMAIL_FILTERS_DIR). See docs/workspace-runbook.md § Gmail filters." >&2
          exit 1
        fi
      }
      need_token() {
        if [ ! -s "$state/token.json" ]; then
          echo "gmail-filters: no OAuth token yet. Run: gmail-filters login" >&2
          exit 1
        fi
      }

      case "$verb" in
        login)
          # Prints the consent URL and waits for the browser's redirect on a local port.
          # init also drops an example config.jsonnet into the temp dir, which is discarded.
          gmailctl --config "$cfg" init "$@"
          ;;
        download)
          need_dir
          need_token
          if [ -e "$file" ] && [ "''${1:-}" != "--force" ]; then
            echo "gmail-filters: $file exists; pass --force to overwrite it with the live filters" >&2
            exit 1
          fi
          [ "''${1:-}" = "--force" ] && shift
          gmailctl --config "$cfg" download -o "$file" "$@"
          ;;
        diff | test | apply)
          need_dir
          [ "$verb" = test ] || need_token
          gmailctl --config "$cfg" "$verb" -f "$file" "$@"
          ;;
        -h | --help | help)
          usage
          ;;
        *)
          usage
          exit 64
          ;;
      esac
    '';
  };
in
writeShellApplication {
  name = "gmail-filters";
  text = ''
    # The client id and secret arrive only through `secret exec`'s environment, never argv —
    # and gmail-filters-run hands them to jq as $ENV, so they stay off argv there too.
    exec secret exec \
      GMAIL_FILTERS_CLIENT_ID=GMAIL_OAUTH_CLIENT_ID \
      GMAIL_FILTERS_CLIENT_SECRET=GMAIL_OAUTH_CLIENT_SECRET \
      -- ${run}/bin/gmail-filters-run "$@"
  '';
}
