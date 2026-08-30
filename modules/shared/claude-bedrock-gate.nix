{ pkgs, lib, ... }:
# Gate Claude Code's Bedrock routing on the AWS identity actually being resolvable.
#
# THE TRAP this exists to close. `CLAUDE_CODE_USE_BEDROCK` deliberately lives in
# the macOS login Keychain, not in Nix (nix-personal's `modules/claude-bedrock.nix`
# explains why: a `settings.json` `env` entry would be applied to every session and
# so could never be toggled). Its companions do NOT:
#
#   AWS_REGION / AWS_PROFILE  ← nix-personal claude-bedrock.nix → ~/.claude/settings.json
#   [profile …] / [sso-session …]  ← nix-personal aws-sso.nix → ~/.aws/config
#
# Both of those are store symlinks written by the PRIVATE layer. Activating the
# public `nix-config#macos` directly drops them, while the Keychain entry survives
# untouched — so Bedrock stays selected with no region and no profile, Claude Code
# can reach no model, and `settings.json` is read-only under /nix so it cannot be
# hand-repaired. The agent needed to undo the activation is the thing the
# activation just killed: chicken-and-egg, and the operator has hit it repeatedly.
#
# The `.claude/hooks/pretooluse-bash-guard.js` block only covers activations the
# AI runs. This module covers the other half — a switch typed by hand in a normal
# terminal — by replacing "Bedrock is on iff the variable exists" with "Bedrock is
# on iff the variable exists AND an AWS identity resolves". When it does not, the
# variable is unset for that shell, so Claude Code falls back to its default
# provider and KEEPS WORKING. Degrading to a working provider is the whole point;
# erroring out would just reproduce the outage.
#
# Why this lives in the PUBLIC repo: a gate shipped from nix-personal would be
# dropped by the very activation it defends against. Same reasoning as
# `programs.keychainSecrets` being wired here.
let
  # Offline and CLI-free on purpose: `aws` is not reliably on PATH during shell
  # init, and a network call (`aws sts get-caller-identity`) would tax every new
  # shell. Everything below reads local files only.
  gate = pkgs.writeShellScriptBin "nix-bedrock-gate" ''
    set -u

    JQ='${pkgs.jq}/bin/jq'
    AWS_CONFIG="$HOME/.aws/config"
    AWS_CREDS="$HOME/.aws/credentials"
    SETTINGS="''${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

    quiet=0
    case "''${1:-}" in
      --quiet) quiet=1 ;;
      -h | --help)
        printf 'usage: nix-bedrock-gate [--quiet]\n\n'
        printf 'Exit 0 if Claude Code can actually route to Bedrock; 1 otherwise\n'
        printf '(reason on stdout). Values are never printed.\n'
        exit 0
        ;;
    esac

    # Reason goes to STDOUT so the shell hook can capture it in a $( ) and decide
    # whether a tty is present before showing it.
    fail() {
      [ "$quiet" -eq 1 ] || printf '%s\n' "$*"
      exit 1
    }

    # Resolve a variable the way Claude Code itself will see it: the shell first,
    # then the `env` block of settings.json. Checking ONLY the shell would be
    # wrong — a plain login shell never has AWS_REGION (it is declared solely in
    # settings.json), so a shell-only test reads "missing" on a perfectly healthy
    # machine and would disable Bedrock permanently.
    resolve() {
      eval "__v=\''${$1:-}"
      if [ -z "$__v" ] && [ -r "$SETTINGS" ]; then
        __v=$("$JQ" -r --arg k "$1" '.env[$k] // empty' "$SETTINGS" 2>/dev/null || true)
      fi
      printf '%s' "$__v"
    }

    # Exact, regex-free INI section lookup: brackets are stripped and the name is
    # compared as a STRING, so a section name containing regex metacharacters
    # cannot misfire. Prints the section body; exits 1 if the section is absent.
    section_body() {
      [ -r "$2" ] || return 1
      awk -v want="$1" '
        /^[[:space:]]*\[/ {
          line = $0
          sub(/^[[:space:]]*\[[[:space:]]*/, "", line)
          sub(/[[:space:]]*\][[:space:]]*$/, "", line)
          inblk = (line == want)
          if (inblk) found = 1
          next
        }
        inblk { print }
        END { exit(found ? 0 : 1) }
      ' "$2"
    }

    # ---- 1. region ---------------------------------------------------------
    # Absent is the public-activation signature. Present-but-malformed is the
    # "there is a value, but a wrong one" case the operator asked to rule out.
    region=$(resolve AWS_REGION)
    [ -n "$region" ] || region=$(resolve AWS_DEFAULT_REGION)
    [ -n "$region" ] ||
      fail "AWS_REGION resolves nowhere (not in the shell, not in settings.json) — the private nix-personal layer is not active."
    case "$region" in
      [a-z][a-z]-*-[0-9] | [a-z][a-z]-*-[0-9][0-9]) : ;;
      *) fail "AWS_REGION is set but is not a well-formed AWS region name." ;;
    esac

    # ---- 2. profile (optional) --------------------------------------------
    # An absent AWS_PROFILE is NOT a failure — the SDK falls back to `default`.
    # But whichever profile it lands on still has to be DEFINED, and ~/.aws/config
    # is itself a private-layer store symlink, so this is a second independent
    # detector of the same dropped layer.
    profile=$(resolve AWS_PROFILE)
    if [ -n "$profile" ]; then section="profile $profile"; else section="default"; fi

    body=$(section_body "$section" "$AWS_CONFIG") || body=""
    if [ -z "$body" ] && ! section_body "$section" "$AWS_CREDS" >/dev/null 2>&1; then
      # Static keys in the environment need no profile at all.
      [ -n "''${AWS_ACCESS_KEY_ID:-}" ] ||
        fail "the resolved AWS profile is not defined in ~/.aws/config or ~/.aws/credentials, and no static keys are in the environment."
    fi

    # ---- 3. auth freshness -------------------------------------------------
    # These profiles are SSO, so "authenticated" means an unexpired SSO access
    # token in the cache. Only the TOKEN files carry `accessToken`; the sibling
    # client-REGISTRATION file also has an `expiresAt` (months out) and would
    # otherwise read as permanently valid.
    case "$body" in
      *sso_session* | *sso_start_url*) sso=1 ;;
      *) sso=0 ;;
    esac
    if [ "$sso" -eq 1 ]; then
      now=$(date -u +%Y%m%d%H%M%S)
      # ISO-8601 UTC → the first 14 contiguous digits, so a fractional-seconds
      # suffix (`…:43.806Z`) cannot make the numeric comparison lopsided.
      future() {
        __n=$(printf '%s' "$1" | tr -cd '0-9' | cut -c1-14)
        [ "''${#__n}" -eq 14 ] && [ "$__n" -gt "$now" ]
      }

      fresh=0
      for f in "$HOME"/.aws/sso/cache/*.json; do
        [ -r "$f" ] || continue
        "$JQ" -e 'has("accessToken")' "$f" >/dev/null 2>&1 || continue

        exp=$("$JQ" -r '.expiresAt // empty' "$f" 2>/dev/null || true)
        if [ -n "$exp" ] && future "$exp"; then
          fresh=1
          break
        fi

        # An EXPIRED access token is not a dead session. The cache also holds a
        # `refreshToken`, which lets the SDK mint a new access token with no
        # interactive login for as long as the client REGISTRATION is still valid.
        # Failing on `expiresAt` alone would disable Bedrock on a machine where it
        # works perfectly — these tokens expire every few hours by design.
        rexp=$("$JQ" -r '.registrationExpiresAt // empty' "$f" 2>/dev/null || true)
        if [ -n "$rexp" ] && future "$rexp" && "$JQ" -e 'has("refreshToken")' "$f" >/dev/null 2>&1; then
          fresh=1
          break
        fi
      done
      [ "$fresh" -eq 1 ] ||
        fail "the AWS SSO session is expired with no usable refresh token — run \`aws sso login\`, then open a new shell."
    fi

    [ "$quiet" -eq 1 ] || printf 'Bedrock is usable: region resolves, profile is defined, SSO session is valid.\n'
    exit 0
  '';

  # Runs in every shell, AFTER the Keychain loader has exported the variable.
  gateShell = ''
    # Bedrock is selected by the mere PRESENCE of CLAUDE_CODE_USE_BEDROCK, so `=0`
    # is not an "off" — hence the `+x` test rather than a value test.
    if [ -n "''${CLAUDE_CODE_USE_BEDROCK+x}" ]; then
      if ! __bedrock_reason=$(${gate}/bin/nix-bedrock-gate 2>/dev/null); then
        unset CLAUDE_CODE_USE_BEDROCK
        # Only for a human: a non-interactive shell (BASH_ENV, scripts, launchd)
        # still gets the unset, silently.
        if [ -t 2 ]; then
          printf '\033[33mnix-bedrock-gate: Bedrock OFF for this shell — %s\033[0m\n' "$__bedrock_reason" >&2
        fi
      fi
      unset __bedrock_reason
    fi
  '';
in
# Darwin-only: the Keychain loader that exports the variable is itself darwin-only,
# so on the NixOS hosts there is nothing to gate.
lib.mkIf pkgs.stdenv.isDarwin {
  home.packages = [ gate ];

  # mkOrder 1600 > mkAfter (1500), which is what keychain-secrets uses for its own
  # loader on these exact three options. Ordering is the whole correctness argument:
  # running before the loader would see an unset variable and do nothing at all.
  # All three are needed because Claude Code inherits whichever shell launched it —
  # zsh's `.zshenv` (envExtra) is the only file a NON-interactive zsh reads, and
  # bash splits the same job across profileExtra (login) and bashrcExtra (rest).
  programs.zsh.envExtra = lib.mkOrder 1600 gateShell;
  programs.bash.profileExtra = lib.mkOrder 1600 gateShell;
  programs.bash.bashrcExtra = lib.mkOrder 1600 gateShell;
}
