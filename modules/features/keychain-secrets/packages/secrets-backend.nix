# The WRITE / RECOVERY side of the Keychain store (ADR-004, Phase 2): four operator-invoked
# CLIs that make GCP Secret Manager the durable source of truth and the login Keychain a
# fast local cache. Nothing about the READ side changes — the loader, `secret exec`, Touch ID
# prompts and the index grammar are untouched.
#
#   secrets-status     table: in Keychain? ref? mode? drift vs. latest remote version (hashes)
#   secrets-rehydrate  pull every prefixed secret from Secret Manager into the Keychain
#   secrets-push       push ONE Keychain item to Secret Manager (never bulk)
#   secrets-resolve    print ONE value to stdout — the `mode = "reference"` runtime helper
#
# CONFIG IS READ AT RUNTIME, NOT BAKED. These derivations carry no project id, prefix or
# names, so the flake's perSystem `packages` and the home-manager module install the SAME
# drvs (the capsule's standing rule, see flake-module.nix). The loader exports the knobs
# when `local.keychainSecrets.backend.type != "none"`:
#     SECRETS_BACKEND          none|gcp            (unset ⇒ none: every command is offline)
#     SECRETS_BACKEND_PROJECT  GCP project id      (unset ⇒ `gcloud config get-value project`)
#     SECRETS_BACKEND_PREFIX   secret-id prefix    (unset ⇒ fleet-)
#     SECRETS_REFS_FILE        the local manifest  (unset ⇒ ~/.config/secrets/refs.tsv)
# so the PROJECT ID never has to be a Nix string in this public repo (ADR-004 §8.2).
#
# THE REFERENCE. A Secret Manager id may only contain [A-Za-z0-9_-] (gcloud secrets create
# --help), so `<prefix>/<service>/<account>` cannot be spelled literally. The id is
# sanitize("<prefix><service>") — every other character becomes `_` — and the exact SERVICE,
# ENV binding, account and mode ride on the secret as ANNOTATIONS, which is what rehydrate
# reads back. So the mapping is derivable in both directions and nothing has to be stored to
# make a fresh Mac work. The local manifest (refs.tsv: SERVICE REF MODE ENV, 0600, outside
# Nix and git) is a CACHE of that mapping plus the one thing that is not derivable: an
# operator's explicit override of a ref. `secrets-push --ref` writes such an override.
#
# `mode = "reference"`: the value is NOT cached in the Keychain and NOT exported; the loader
# exports `<ENV>_REF=<ref>` from the manifest instead, and the consuming tool calls
# `secrets-resolve "$<ENV>_REF"` when it actually needs the value. A bare resource name in an
# agent transcript is a pointer, useless without an SSO identity to dereference it.
#
# UPSTREAM FIRST (2026-09-20):
#   * gcloud comes from PATH, not runtimeInputs: the Mac installs the `gcloud-cli` Homebrew
#     cask (hosts/macos.nix) so `gcloud components` works; nixpkgs' google-cloud-sdk is a
#     ~1 GB second copy. A missing gcloud is a clear error, not a silent skip.
#   * The Keychain writer is `set-secret` — the index's SINGLE WRITER — so rehydrate never
#     touches `__set_secret_index__` itself and `-U` already updates an item in place; there
#     is no delete-then-add here because the capsule's writer already solved that.
#   * Community tools considered: `teller` (tellerops) syncs Secret Manager → env/files but
#     not the macOS Keychain and knows nothing of this store's index; `chamber` is SSM-only;
#     `envchain` was already declined in module.nix. Custom, for the Keychain/index half only —
#     the cloud half is plain `gcloud secrets …`.
#
# NEVER RUN BY ACTIVATION. Enforced by ast-grep/rules/activation-must-not-touch-secrets.yml
# and the capsule's `keychain-secrets-backend-inert` check.
{
  writeShellApplication,
  coreutils,
  gnugrep,
  gawk,
  openssl,
  set-secret,
  secret,
}:
let
  common = ''
    security=/usr/bin/security
    account="$(/usr/bin/id -un)"
    index_service="__set_secret_index__"
    kc=()
    if [ -n "''${SET_SECRET_KEYCHAIN:-}" ]; then kc=("$SET_SECRET_KEYCHAIN"); fi

    backend="''${SECRETS_BACKEND:-none}"
    prefix="''${SECRETS_BACKEND_PREFIX:-fleet-}"
    refs="''${SECRETS_REFS_FILE:-''${XDG_CONFIG_HOME:-$HOME/.config}/secrets/refs.tsv}"

    die() { echo "$me: $*" >&2; exit 1; }

    require_backend() {
      if [ "$backend" = none ]; then
        die "no secret backend is configured (local.keychainSecrets.backend.type = \"none\"). The login Keychain is the ONLY copy of your secrets — back it up yourself. Set backend.type = \"gcp\" and re-activate to enable Secret Manager."
      fi
      [ "$backend" = gcp ] || die "backend '$backend' is not implemented (only gcp is)."
      command -v gcloud >/dev/null 2>&1 || die "gcloud is not on PATH (hosts/macos.nix installs the gcloud-cli cask)."
    }
    require_session() {
      gcloud auth print-access-token >/dev/null 2>&1 \
        || die "no active gcloud SSO session. Run:  gcloud auth login   (then retry)"
    }
    project() {
      if [ -n "''${SECRETS_BACKEND_PROJECT:-}" ]; then printf '%s' "$SECRETS_BACKEND_PROJECT"; return; fi
      p="$(gcloud config get-value project 2>/dev/null || true)"
      [ -n "$p" ] || die "no GCP project: set SECRETS_BACKEND_PROJECT (local.keychainSecrets.backend.project) or 'gcloud config set project <id>'."
      printf '%s' "$p"
    }
    # Secret Manager ids: [A-Za-z0-9_-], max 255. Everything else → '_'.
    sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-255; }
    sha() { openssl dgst -sha256 | awk '{print $NF}'; }

    # ---- the index grammar (canonical definition: packages/set-secret.nix) ------------
    read_index() { "$security" find-generic-password -a "$account" -s "$index_service" -w "''${kc[@]}" 2>/dev/null || true; }
    tok_env() { case "$1" in *=*) printf '%s' "''${1%%=*}" ;; *) printf '%s' "$1" ;; esac; }
    tok_service() { case "$1" in *=*) printf '%s' "''${1#*=}" ;; *) printf '%s' "$1" ;; esac; }
    # Emit "SERVICE<TAB>ENV" per indexed item (ENV empty when unbound).
    index_rows() {
      rest="$(read_index)"
      while [ -n "$rest" ]; do
        t="''${rest%% *}"; rest="''${rest#"$t"}"; rest="''${rest# }"
        [ -n "$t" ] || continue
        printf '%s\t%s\n' "$(tok_service "$t")" "$(tok_env "$t")"
      done
    }
    bound_env() { index_rows | awk -F'\t' -v s="$1" '$1==s {print $2; exit}'; }

    # ---- the local manifest: SERVICE  REF  MODE  ENV  (tab-separated, 0600) --------------
    manifest_get() { # manifest_get SERVICE COLUMN(2..4)
      [ -r "$refs" ] || return 0
      awk -F'\t' -v s="$1" -v c="$2" '$1==s {print $c; exit}' "$refs"
    }
    manifest_put() { # manifest_put SERVICE REF MODE ENV — idempotent line replacement
      mkdir -p "$(dirname "$refs")"
      tmp="$(mktemp "$(dirname "$refs")/.refs.XXXXXX")"
      { [ -r "$refs" ] && awk -F'\t' -v s="$1" '$1!=s' "$refs"; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; } | sort > "$tmp"
      chmod 600 "$tmp"; mv "$tmp" "$refs"
    }
    ref_for() { # SERVICE -> full resource name (manifest override, else derived)
      r="$(manifest_get "$1" 2)"
      if [ -n "$r" ]; then printf '%s' "$r"; else printf 'projects/%s/secrets/%s' "$(project)" "$(sanitize "$prefix$1")"; fi
    }
    mode_for() { m="$(manifest_get "$1" 3)"; printf '%s' "''${m:-cached}"; }
    secret_id() { printf '%s' "''${1##*/}"; }
    remote_sha() { # ID -> sha of latest version, or empty when absent
      gcloud --quiet secrets versions access latest --secret="$1" --project="$(project)" 2>/dev/null | tr -d '\n' | sha || true
    }
    # List this store's secret names, or die with gcloud's own first error line (API
    # disabled, no permission, wrong project). `--quiet` so gcloud can never PROMPT
    # ("enable the API?") from inside a script — a prompt is a hang under launchd and a
    # hidden y/N in a log. Measured 2026-09-20: without it, a disabled API prompted and the
    # run then reported "0 written" with exit 0 — a false success.
    list_remote() {
      errf="$(mktemp)"
      if ! gcloud --quiet secrets list --project="$(project)" --filter="name~/secrets/$prefix" --format='value(name)' 2>"$errf"; then
        first="$(grep -m1 -E 'ERROR|not enabled|permission' "$errf" || head -1 "$errf")"; rm -f "$errf"
        die "cannot list secrets in project $(project): $first"
      fi
      rm -f "$errf"
    }
    local_sha() { # SERVICE -> sha of the Keychain value, or empty when absent
      "$security" find-generic-password -a "$account" -s "$1" -w "''${kc[@]}" 2>/dev/null | tr -d '\n' | sha || true
    }
  '';

  mk =
    name: text:
    writeShellApplication {
      inherit name;
      runtimeInputs = [
        coreutils
        gnugrep
        gawk
        openssl
        set-secret
        secret
      ];
      text = ''
        me=${name}
        ${common}
        ${text}
      '';
    };
in
{
  secrets-status = mk "secrets-status" ''
    usage() {
      printf '%s\n' \
        "usage: secrets-status [--offline]" \
        "  One row per registered Keychain secret: present locally? its Secret Manager ref," \
        "  mode (cached|reference) and DRIFT against the latest remote version — compared by" \
        "  sha256, never by printing. With no backend configured (or --offline) no network is" \
        "  touched and DRIFT reads n/a. Remote secrets under the prefix that are not in the" \
        "  index are listed as remote-only." >&2
    }
    offline=0
    case "''${1:-}" in -h|--help) usage; exit 0 ;; --offline) offline=1 ;; "") ;; *) usage; exit 64 ;; esac
    online=0
    if [ "$backend" = gcp ] && [ "$offline" -eq 0 ]; then
      require_backend; require_session; online=1
      remote_names="$(list_remote)" # loud on API-disabled / no-permission; never prompts
    fi
    printf '%-34s %-22s %-8s %-9s %-10s %s\n' SERVICE ENV KEYCHAIN MODE DRIFT REF
    seen=" "
    while IFS=$'\t' read -r svc env; do
      [ -n "$svc" ] || continue
      seen="$seen$svc "
      mode="$(mode_for "$svc")"
      lsha="$(local_sha "$svc")"
      if [ -n "$lsha" ]; then kcs=present; else kcs=MISSING; fi
      if [ "$backend" = none ]; then ref="-"; drift="n/a"
      else
        ref="$(ref_for "$svc")"
        if [ "$online" -eq 1 ]; then
          rsha="$(remote_sha "$(secret_id "$ref")")"
          if [ -z "$rsha" ]; then drift="remote-missing"
          elif [ "$mode" = reference ]; then drift="reference"
          elif [ -z "$lsha" ]; then drift="local-missing"
          elif [ "$rsha" = "$lsha" ]; then drift="in-sync"
          else drift="DRIFT"; fi
        else drift="n/a (offline)"; fi
      fi
      printf '%-34s %-22s %-8s %-9s %-10s %s\n' "$svc" "''${env:--}" "$kcs" "$mode" "$drift" "$ref"
    done < <(index_rows)
    if [ "$online" -eq 1 ]; then
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        s="$(gcloud --quiet secrets describe "$(secret_id "$name")" --project="$(project)" --format='value(annotations.service)' 2>/dev/null || true)"
        case "$seen" in *" $s "*) ;; *) printf '%-34s %-22s %-8s %-9s %-10s %s\n' "''${s:-?}" "-" "-" "-" "remote-only" "$name" ;; esac
      done <<<"$remote_names"
    fi
  '';

  secrets-rehydrate = mk "secrets-rehydrate" ''
    usage() {
      printf '%s\n' \
        "usage: secrets-rehydrate [--dry-run]" \
        "  Repopulate the login Keychain from Secret Manager: every secret under the prefix" \
        "  that carries this store's annotations is written back through set-secret (the" \
        "  index's single writer), so bindings and the index are restored too. Idempotent:" \
        "  an item whose Keychain value already matches is skipped. reference-mode secrets" \
        "  are NOT cached — only their ref lands in the manifest. Needs an active gcloud SSO" \
        "  session; fails loudly without one. Never run by activation." >&2
    }
    dry=0
    case "''${1:-}" in -h|--help) usage; exit 0 ;; --dry-run) dry=1 ;; "") ;; *) usage; exit 64 ;; esac
    require_backend; require_session
    proj="$(project)"
    names="$(list_remote)" # dies loudly on API-disabled / no-permission; never prompts
    n_new=0; n_same=0; n_ref=0; n_skip=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      id="$(secret_id "$name")"
      # ';' separator, not the default tab: tab is IFS whitespace, so an EMPTY env
      # annotation would collapse and shift `mode` into `env`.
      IFS=';' read -r svc env mode <<<"$(gcloud --quiet secrets describe "$id" --project="$proj" \
        --format='value[separator=";"](annotations.service,annotations.env,annotations.mode)' 2>/dev/null)"
      if [ -z "$svc" ]; then echo "$me: skip $id (no 'service' annotation — not written by secrets-push)" >&2; n_skip=$((n_skip+1)); continue; fi
      mode="''${mode:-cached}"
      if [ "$mode" = reference ]; then
        [ "$dry" -eq 1 ] || manifest_put "$svc" "$name" reference "$env"
        echo "$me: $svc -> reference only ($name)"; n_ref=$((n_ref+1)); continue
      fi
      rsha="$(remote_sha "$id")"
      if [ -z "$rsha" ]; then echo "$me: skip $id (no accessible version)" >&2; n_skip=$((n_skip+1)); continue; fi
      if [ "$rsha" = "$(local_sha "$svc")" ]; then
        [ "$dry" -eq 1 ] || manifest_put "$svc" "$name" cached "$env"
        n_same=$((n_same+1)); continue
      fi
      if [ "$dry" -eq 1 ]; then echo "$me: would write $svc (env=''${env:--})"; n_new=$((n_new+1)); continue; fi
      # Value travels over a PIPE into set-secret's stdin path — never argv, never a file.
      if [ -n "$env" ]; then flag=(--env "$env"); else flag=(--no-export); fi
      gcloud --quiet secrets versions access latest --secret="$id" --project="$proj" | set-secret "''${flag[@]}" "$svc" >/dev/null
      manifest_put "$svc" "$name" cached "$env"
      echo "$me: wrote $svc -> \$''${env:--}"
      n_new=$((n_new+1))
    done <<<"$names"
    echo "$me: done — $n_new written, $n_same already current, $n_ref reference-only, $n_skip skipped$( [ "$dry" -eq 1 ] && printf ' (dry run)' )"
    echo "$me: open a new shell (or 'secret load') to see restored bindings."
  '';

  secrets-push = mk "secrets-push" ''
    usage() {
      printf '%s\n' \
        "usage: secrets-push <SERVICE> [<ACCOUNT>] [--mode cached|reference] [--ref REF]" \
        "  Push ONE Keychain item to Secret Manager (create the secret if needed, add a version" \
        "  only when the value changed). Records SERVICE / ENV binding / ACCOUNT / MODE as" \
        "  annotations so rehydrate can map it back, and caches the ref in the local manifest." \
        "  --mode reference also unbinds the item so the value stops being ambient; consumers" \
        "  then read \$<ENV>_REF and call secrets-resolve. Never bulk. Never run by activation." >&2
    }
    mode=""; ref=""; svc=""; acct=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -h|--help) usage; exit 0 ;;
        --mode) mode="''${2:-}"; shift 2 ;;
        --ref) ref="''${2:-}"; shift 2 ;;
        --*) usage; exit 64 ;;
        *) if [ -z "$svc" ]; then svc="$1"; elif [ -z "$acct" ]; then acct="$1"; else usage; exit 64; fi; shift ;;
      esac
    done
    [ -n "$svc" ] || { usage; exit 64; }
    acct="''${acct:-$account}"
    require_backend; require_session
    proj="$(project)"
    env="$(bound_env "$svc")"
    mode="''${mode:-$(mode_for "$svc")}"
    case "$mode" in cached|reference) ;; *) die "--mode must be cached or reference" ;; esac
    ref="''${ref:-$(ref_for "$svc")}"
    id="$(secret_id "$ref")"
    if ! value="$("$security" find-generic-password -a "$acct" -s "$svc" -w "''${kc[@]}" 2>/dev/null)"; then
      die "no Keychain item '$svc' for account '$acct'."
    fi
    ann="service=$svc,account=$acct,mode=$mode''${env:+,env=$env}"
    if gcloud --quiet secrets describe "$id" --project="$proj" >/dev/null 2>&1; then
      gcloud --quiet secrets update "$id" --project="$proj" --update-annotations="$ann" >/dev/null
    else
      gcloud --quiet secrets create "$id" --project="$proj" --replication-policy=automatic --set-annotations="$ann" >/dev/null
      echo "$me: created $ref"
    fi
    if [ "$(printf '%s' "$value" | tr -d '\n' | sha)" = "$(remote_sha "$id")" ]; then
      echo "$me: $svc already current in $ref"
    else
      printf '%s' "$value" | gcloud --quiet secrets versions add "$id" --project="$proj" --data-file=- >/dev/null
      echo "$me: added a version of $svc to $ref (len=''${#value})"
    fi
    value=""
    manifest_put "$svc" "$ref" "$mode" "$env"
    if [ "$mode" = reference ] && [ -n "$env" ]; then
      secret unbind "$svc" >/dev/null
      echo "$me: $svc is reference-mode — unbound from \$$env; new shells get \$''${env}_REF=$ref"
    fi
  '';

  secrets-resolve = mk "secrets-resolve" ''
    if [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ] || [ -z "''${1:-}" ]; then
      printf '%s\n' \
        "usage: secrets-resolve <REF|SECRET_ID|SERVICE>" \
        "  Print the latest value of ONE Secret Manager secret to stdout — nothing else, no" \
        "  trailing status line. The runtime helper for mode = \"reference\": a tool reads" \
        "  \$<ENV>_REF and calls this when it actually needs the value. Accepts a full" \
        "  projects/<p>/secrets/<id> ref, a bare id, or a registered SERVICE (resolved via" \
        "  the manifest / the derivation rule)." >&2
      exit 64
    fi
    require_backend; require_session
    case "$1" in
      projects/*) id="$(secret_id "$1")"; proj="$(printf '%s' "$1" | cut -d/ -f2)" ;;
      *) if index_rows | awk -F'\t' -v s="$1" '$1==s {f=1} END {exit !f}'; then r="$(ref_for "$1")"; id="$(secret_id "$r")"; proj="$(printf '%s' "$r" | cut -d/ -f2)"; else id="$1"; proj="$(project)"; fi ;;
    esac
    exec gcloud --quiet secrets versions access latest --secret="$id" --project="$proj"
  '';
}
