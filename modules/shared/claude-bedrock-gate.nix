{
  pkgs,
  lib,
  config,
  ...
}:
# Claude Code's Bedrock routing: the AWS identity (`local.claudeBedrock`) and the
# runtime gate that makes selecting Bedrock safe when that identity is absent.
#
# WHY CLAUDE_CODE_USE_BEDROCK IS NOT DECLARED HERE — or anywhere in Nix.
# (Moved verbatim from nix-personal's `modules/claude-bedrock.nix`, which this
# module absorbed; the reasoning is the reason the gate below has to exist.)
#
#   CLAUDE_CODE_USE_BEDROCK is deliberately excluded from this module. Claude
#   Code applies settings.json's `env` block to every session, which would
#   shadow/override whatever the shell already exported — so declaring the
#   flag here would make it permanently "on" (or permanently "off") regardless
#   of shell state, defeating the point of a runtime toggle. It must survive
#   reactivation of BOTH `nix-config#macos` and nix-personal's `#macos` without
#   being reset, which rules out anything Nix-managed (activation regenerates
#   settings.json every time). Instead it lives purely in the macOS Keychain,
#   outside any store path, toggled with:
#     secret set CLAUDE_CODE_USE_BEDROCK 1   # enable
#     secret set CLAUDE_CODE_USE_BEDROCK 0   # disable (`secret rm` also works)
#
#   `0` IS a real off-switch since Claude Code 1.0.124 fixed
#   anthropics/claude-code#8063, where every string evaluated truthy. Setting it
#   is nicer than removing it: the handle stays in `secret ls`, so the toggle's
#   existence — and its current state — remain visible.
#   (`local.keychainSecrets` — the loader providing `secret` — is wired in
#   modules/shared/home.nix, so this toggle works whether the host activates
#   public-only or through the private overlay.)
#
#   REGION and PROFILE are static identity, not a toggle, so they're safe to
#   declare in Nix: harmless even when Bedrock is off, since Claude Code only
#   consults them once CLAUDE_CODE_USE_BEDROCK is truthy at runtime.
#
# That is also why `local.claudeBedrock` deliberately has NO `enable` option —
# see the option declarations below.
#
# THE TRAP this gate exists to close. The Keychain flag survives every
# activation. Its companions do NOT:
#
#   AWS_REGION / AWS_PROFILE  ← values from nix-personal via `local.claudeBedrock`,
#     written HERE into ~/.claude/settings.json — and ABSENT BY DEFAULT, because
#     the public repo supplies no region/profile (see the null invariant below).
#   [profile …] / [sso-session …]  ← nix-personal aws-sso.nix → ~/.aws/config
#
# Both of those come from the PRIVATE layer. Activating the public
# `nix-config#macos` directly drops them, while the Keychain entry survives
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
# `local.keychainSecrets` being wired here.
#
# WHERE THE IDENTITY LIVES NOW: ~/.aws/config, owned by the `aws` CLI.
# nix-personal is sunsetting, and with it the only definitions of
# `local.claudeBedrock` and the store-symlinked ~/.aws/config described above.
# The identity is therefore RUNTIME state — exactly like the SSO tokens in
# ~/.aws/sso/cache always were: `aws configure sso` writes the profile, the gate
# reads it, and the shell hook exports that profile's `region`, because Claude
# Code takes the region from the ENVIRONMENT only (anthropics/claude-code#18962).
# This is ADR-003's split (docs/externalization-boundary-adr.md): identity is
# content and may live outside every repo; the gate is governance and stays here.
# The trap above is unchanged — the Keychain flag still outlives a missing file —
# only the source of the companions moved. `adoptAwsConfig` (section (c)) turns a
# leftover store symlink into a real file, so the first activation without the
# private layer cannot delete the operator's profiles.
let
  # Offline and CLI-free on purpose: `aws` is not reliably on PATH during shell
  # init, and a network call (`aws sts get-caller-identity`) would tax every new
  # shell. Everything below reads local files only.
  # `writeShellApplication`, not `writeShellScriptBin`: this is a ~130-line program
  # with jq parsing and several exit paths, and only this builder runs shellcheck
  # at build time (upstream option nixpkgs `writeShellApplication` exists -> using
  # it; pkgs/build-support/trivial-builders/default.nix:268 `name`, :277
  # `excludeShellChecks`, :279 `bashOptions`). `name` keeps the exact basename.
  #
  # It is NOT a launchd unit, so the `nix-*` arg0 carve-out in
  # .claude/rules/launchd-naming.md does not apply — the `nix-` prefix here is
  # only for a legible `home.packages` CLI.
  #
  # bashOptions is narrowed to nounset ON PURPOSE. The default adds errexit and
  # pipefail, and this script signals through its OWN exit codes — the caller
  # reads them (`if ! __bedrock_reason=$(nix-bedrock-gate)`), so errexit would
  # abort at the first non-zero probe instead of letting it return a reason.
  #
  # SC2016 is excluded because it fires on `'.env[$k] // empty'` — `$k` is a JQ
  # variable bound by --arg, not a shell one, so the single quotes are correct and
  # shellcheck cannot know that.
  gate = pkgs.writeShellApplication {
    name = "nix-bedrock-gate";
    bashOptions = [ "nounset" ];
    excludeShellChecks = [ "SC2016" ];
    text = ''

      JQ='${pkgs.jq}/bin/jq'
      AWS_CONFIG="$HOME/.aws/config"
      AWS_CREDS="$HOME/.aws/credentials"
      SETTINGS="''${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

      quiet=0
      mode=check
      case "''${1:-}" in
        --quiet) quiet=1 ;;
        --region)
          quiet=1
          mode=region
          ;;
        -h | --help)
          printf 'usage: nix-bedrock-gate [--quiet | --region]\n\n'
          printf 'Exit 0 if Claude Code can actually route to Bedrock; 1 otherwise\n'
          printf '(reason on stdout). Values are never printed, except that\n'
          printf '--region prints the resolved region for the shell hook to export.\n'
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

      # ---- 1. profile --------------------------------------------------------
      # Resolved FIRST, because the region may live on it. An absent AWS_PROFILE is
      # NOT a failure — the SDK falls back to `default`.
      profile=$(resolve AWS_PROFILE)
      if [ -n "$profile" ]; then section="profile $profile"; else section="default"; fi
      body=$(section_body "$section" "$AWS_CONFIG") || body=""

      # ---- 2. region ---------------------------------------------------------
      # Shell, then settings.json, then the resolved profile's own `region` key in
      # ~/.aws/config — the file `aws configure sso` writes, so that file can be the
      # ONE runtime-owned source. Anchored on the bare key so `sso_region` (the SSO
      # portal's region, not the Bedrock one) can never match. Present-but-malformed
      # is the "there is a value, but a wrong one" case the operator asked to rule out.
      region=$(resolve AWS_REGION)
      [ -n "$region" ] || region=$(resolve AWS_DEFAULT_REGION)
      [ -n "$region" ] || region=$(printf '%s\n' "$body" | awk -F= '
        /^[[:space:]]*region[[:space:]]*=/ { v = $2; gsub(/[[:space:]]/, "", v); print v; exit }
      ')
      if [ -z "$region" ]; then
        # No region AND no profile body almost always means the profile itself is
        # missing — say that, not the downstream symptom.
        [ -n "$body" ] ||
          fail "no AWS region resolves, and the resolved AWS profile is not defined in ~/.aws/config — run \`aws configure sso\`."
        fail "no AWS region resolves (shell, settings.json, or \`region\` on the active profile in ~/.aws/config) — add \`region\` to that profile."
      fi
      case "$region" in
        [a-z][a-z]-*-[0-9] | [a-z][a-z]-*-[0-9][0-9]) : ;;
        *) fail "the resolved AWS region is not a well-formed AWS region name." ;;
      esac
      if [ "$mode" = region ]; then
        printf '%s\n' "$region"
        exit 0
      fi

      # ---- 3. the profile must be DEFINED -------------------------------------
      # Whichever profile the SDK lands on has to exist; since ~/.aws/config is
      # runtime state, "never ran `aws configure sso`" is the common way to miss it.
      if [ -z "$body" ] && ! section_body "$section" "$AWS_CREDS" >/dev/null 2>&1; then
        # Static keys in the environment need no profile at all.
        [ -n "''${AWS_ACCESS_KEY_ID:-}" ] ||
          fail "the resolved AWS profile is not defined in ~/.aws/config or ~/.aws/credentials, and no static keys are in the environment — run \`aws configure sso\`."
      fi

      # ---- 4. auth freshness -------------------------------------------------
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
  };

  # Runs in every shell, AFTER the Keychain loader has exported the variable.
  gateShell = ''
    # Match Claude Code's OWN truthiness set, so this gate is never stricter than
    # the runtime it guards: 1/true/yes/on (lowercased, trimmed) select Bedrock;
    # everything else — including `0` — does not.
    #
    # This used to be a PRESENCE test (`+x`), because anthropics/claude-code#8063
    # had every string evaluating truthy, so `=0` really did mean "on". That was
    # fixed in 1.0.124 ("Fix Bedrock and Vertex environment variables evaluating
    # all strings as truthy") and the issue is closed. Verified behaviourally on
    # 2.1.260 rather than from the changelog: `=0` routes to anthropic.com, `=1`
    # routes to bedrock. A presence test now warns about a value the runtime
    # already ignores.
    case "$(printf '%s' "''${CLAUDE_CODE_USE_BEDROCK:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
      1 | true | yes | on) __bedrock_on=1 ;;
      *) __bedrock_on=0 ;;
    esac
    if [ "$__bedrock_on" -eq 1 ]; then
      if __bedrock_reason=$(${gate}/bin/nix-bedrock-gate 2>/dev/null); then
        # The gate may have found the region only on the ~/.aws/config profile.
        # Claude Code reads it from the environment alone, so export it. A value in
        # settings.json's `env` still wins inside the session — which is why the
        # deprecated `local.claudeBedrock.region` must stay null.
        if [ -z "''${AWS_REGION:-}" ] && [ -z "''${AWS_DEFAULT_REGION:-}" ] &&
          __bedrock_region=$(${gate}/bin/nix-bedrock-gate --region 2>/dev/null); then
          export AWS_REGION="$__bedrock_region"
        fi
        unset __bedrock_region
      else
        unset CLAUDE_CODE_USE_BEDROCK
        # Only for a human: a non-interactive shell (BASH_ENV, scripts, launchd)
        # still gets the unset, silently.
        if [ -t 2 ]; then
          printf '\033[33mnix-bedrock-gate: Bedrock OFF for this shell — %s\033[0m\n' "$__bedrock_reason" >&2
        fi
      fi
      unset __bedrock_reason
    fi
    unset __bedrock_on
  '';
in
{
  # Declared UNCONDITIONALLY: an `options` attribute may never sit inside a
  # `mkIf`. Only the `config` half below is platform-gated.
  #
  # DEPRECATED, kept only so the sunsetting nix-personal keeps EVALUATING until
  # its last activation: removing the options outright would turn its
  # `local.claudeBedrock.region = …` into an "option does not exist" error on the
  # very activation that migrates it. Setting either now warns. Delete the pair
  # (and section (b)) once no definition remains anywhere.
  #
  # OVERRIDABLE, not extendable — one AWS identity per host, so a `listOf` would
  # misdescribe the shape.
  options.local.claudeBedrock = {
    region = lib.mkOption {
      # `str`, NOT `strMatching`: the gate above already validates the SHAPE at
      # runtime, and doing it twice means a malformed region fails at eval with a
      # type error instead of degrading to a working provider — the exact outcome
      # this whole module exists to avoid.
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "us-east-1";
      description = ''
        DEPRECATED. AWS region pinned into `~/.claude/settings.json`'s `env`
        block. The region now comes from the active profile's `region` key in
        the runtime-owned `~/.aws/config` (`aws configure sso`); a value here
        OVERRIDES that file in every session, so it warns when set.

        Never give it a value in nix-config: a public default would shadow every
        operator's own profile, and would make the gate's "no region resolves"
        detector permanently green.
      '';
    };

    profile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "my-sso-profile";
      description = ''
        DEPRECATED. AWS profile pinned into `~/.claude/settings.json`'s `env`
        block. `null` = leave AWS_PROFILE to the shell, else the SDK's `default`
        profile — select a non-default one at runtime instead (a `[default]`
        profile in `~/.aws/config`, or `secret set AWS_PROFILE <name>`). Warns
        when set; same null invariant as `region`.
      '';
    };

    # There is deliberately NO `enable` option here. CLAUDE_CODE_USE_BEDROCK must
    # stay in the macOS login Keychain (see the header): a Nix-declared
    # `settings.json` `env` entry would apply to EVERY session and permanently
    # kill the runtime toggle. Do not add one.
  };

  config = lib.mkMerge [
    # ---- (a) the gate ------------------------------------------------------
    # Darwin-only: the Keychain loader that exports the variable is itself
    # darwin-only, so on the NixOS hosts there is nothing to gate. The guard is
    # isDarwin ONLY — adding `programs.claude-code.enable` here would newly
    # disable the gate on a darwin host that does not enable claude-code.
    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      home.packages = [ gate ];

      # mkOrder 1600 > mkAfter (1500), which is what keychain-secrets uses for its own
      # loader on these exact three options. Ordering is the whole correctness argument:
      # running before the loader would see an unset variable and do nothing at all.
      # All three are needed because Claude Code inherits whichever shell launched it —
      # zsh's `.zshenv` (envExtra) is the only file a NON-interactive zsh reads, and
      # bash splits the same job across profileExtra (login) and bashrcExtra (rest).
      # Checked by `checks.aarch64-darwin.bedrock-gate-after-loader`.
      programs.zsh.envExtra = lib.mkOrder 1600 gateShell;
      programs.bash.profileExtra = lib.mkOrder 1600 gateShell;
      programs.bash.bashrcExtra = lib.mkOrder 1600 gateShell;
    })

    # ---- (b) the identity --------------------------------------------------
    # Guard carried over verbatim from nix-personal's claude-bedrock.nix: it
    # defends against a home-manager module set that never enables
    # programs.claude-code. It covers the Linux hosts for free, because
    # `programs.claude-code` is itself mkIf isDarwin in modules/shared/home.nix.
    (lib.mkIf config.programs.claude-code.enable {
      # optionalAttrs, never a null passthrough: `null` is INSIDE the json value
      # type, so a null would be emitted as a literal `null` into settings.json
      # rather than omitting the key.
      programs.claude-code.settings.env =
        lib.optionalAttrs (config.local.claudeBedrock.region != null) {
          AWS_REGION = config.local.claudeBedrock.region;
        }
        // lib.optionalAttrs (config.local.claudeBedrock.profile != null) {
          AWS_PROFILE = config.local.claudeBedrock.profile;
        };
    })

    {
      warnings =
        lib.optional
          (config.local.claudeBedrock.region != null || config.local.claudeBedrock.profile != null)
          (
            "local.claudeBedrock.{region,profile} is deprecated: it pins AWS_* into the read-only "
            + "~/.claude/settings.json, overriding the runtime-owned ~/.aws/config. Put `region` on "
            + "the profile (`aws configure sso`) and drop the definition."
          );
    }

    # ---- (c) migration: adopt a store-symlinked ~/.aws/config --------------
    # The day no module declares ~/.aws/config any more (nix-personal's
    # `aws-sso.nix` gone), home-manager's orphan cleanup DELETES the old
    # generation's symlink — and with it every profile, since the content existed
    # only in the store. Upstream has no "stop managing, keep the content" option
    # (pinned home-manager modules/files.nix: `home.file.<name>` offers `force`
    # and `onChange`, and `legacyCleanup` rm's any orphan that "links into a Home
    # Manager generation"). The same cleanup explicitly SKIPS a regular file
    # ("does not link into a Home Manager generation. Skipping delete."), so
    # replacing the link with a real copy just before `linkGeneration` hands the
    # file to its runtime owner, the `aws` CLI, with nothing lost.
    #
    # Gated on "no home.file entry targets it", evaluated in the SAME config: while
    # any layer still manages the path this is absent, so it can never fight
    # `checkLinkTargets` over a file home-manager is about to link. One-shot by
    # construction — after the first run there is no store symlink left to match.
    # Delete this section once nix-personal is gone.
    (lib.mkIf
      (
        pkgs.stdenv.hostPlatform.isDarwin
        && !lib.any (f: f.enable && f.target == ".aws/config") (lib.attrValues config.home.file)
      )
      {
        home.activation.adoptAwsConfig = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
          awsCfg="$HOME/.aws/config"
          hmFiles="$(readlink -e ${builtins.storeDir})/*-home-manager-files/*"
          if [[ -L "$awsCfg" && "$(readlink "$awsCfg")" == $hmFiles ]]; then
            if [[ -r "$awsCfg" ]]; then
              run cp -L $VERBOSE_ARG "$awsCfg" "$awsCfg.adopt"
              run chmod 600 "$awsCfg.adopt"
              run mv -f $VERBOSE_ARG "$awsCfg.adopt" "$awsCfg"
            else
              warnEcho "~/.aws/config links into a dead home-manager generation; run \`aws configure sso\` to recreate it."
            fi
          fi
        '';
      }
    )
  ];
}
