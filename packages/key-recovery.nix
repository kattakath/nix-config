# Key-recovery kit — `nix run .#key-backup` / `nix run .#key-recover`.
#
# WHY THIS LIVES IN THE FLAKE
# The recovery scripts used to exist only as loose bash in the iCloud folder:
# nothing linted them, nothing evaluated them, and they drifted from the config
# they were supposed to restore. Everything that CAN run under Nix now does, as
# writeShellApplication — which runs shellcheck at BUILD time, so `nix flake
# check` gates both scripts (same trick as the cf-* wrappers).
#
# THE ONE PART THAT CANNOT: ./key-recovery/bootstrap.sh. On a wiped Mac there is
# no Nix, so the thing that installs Nix cannot be run by Nix. It stays plain
# bash, is shellchecked here as a derivation anyway, and `key-backup` publishes
# it into the iCloud kit beside the encrypted key — so the copy on the wiped Mac
# is always the one CI linted. Single source of truth, no drift.
#
# SECURITY POSTURE
#   * The passphrase is read by `age` itself from /dev/tty. It never transits
#     argv, an environment variable, or another process's stdout — which is
#     exactly why the prompt is NOT routed through an osascript dialog.
#   * osascript is used for notifications/confirmations only, never for
#     authentication: privilege escalation goes through sudo (Touch ID, via
#     security.pam.services.sudo_local.touchIdAuth in modules/darwin/core.nix).
#   * Only the ciphertext ever reaches iCloud. MANIFEST holds the operator
#     FINGERPRINT (public, non-secret) so `key-recover` can prove the blob it
#     just decrypted is the key it expected before it uses it.
{
  lib,
  runCommand,
  writeShellApplication,
  age,
  git,
  openssh,
  gnused,
  gnugrep,
  coreutils,
  agenix,
  shellcheck,
  orgName,
  flakeRef,
}:
let
  # The opinionated, single-source location of the kit inside iCloud Drive.
  # "com~apple~CloudDocs" is the iCloud Drive container; this is the only path
  # either script will look in unless told otherwise with --kit.
  kitDir = "$HOME/Library/Mobile Documents/com~apple~CloudDocs/nix-key-recovery";

  blobName = "id_ed25519.age";

  # Shared shell prelude: logging, and the macOS-native UX helpers. Every
  # osascript call degrades to the terminal when there is no GUI session (SSH,
  # CI), so nothing here can wedge a headless run.
  prelude = ''
    say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
    warn() { printf '\033[1;33m    warning: %s\033[0m\n' "$*" >&2; }
    die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

    has_gui() {
      [ -n "''${SSH_TTY:-}" ] && return 1
      /bin/launchctl managername 2>/dev/null | grep -q Aqua
    }
    notify() {
      has_gui || return 0
      /usr/bin/osascript -e "display notification \"$1\" with title \"Nix key recovery\"" \
        >/dev/null 2>&1 || true
    }
    confirm() {
      if has_gui; then
        /usr/bin/osascript -e \
          "display dialog \"$1\" buttons {\"Cancel\", \"Continue\"} default button \"Cancel\" with icon caution" \
          >/dev/null 2>&1 && return 0
        return 1
      fi
      [ -t 0 ] || return 1
      printf '    %s [y/N] ' "$1"
      local reply
      read -r reply
      case "$reply" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
    }

    # iCloud files can be "dataless": the name exists but the bytes have been
    # evicted, so `[ -f ]` passes and the read then stalls or fails. brctl is the
    # supported way to materialise them — this is what iCloud integration should
    # mean, rather than poking at Finder over AppleScript.
    icloud_materialise() { # $1 = path
      [ -e "$1" ] || return 0
      /usr/bin/brctl download "$1" >/dev/null 2>&1 || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$1" ] && return 0
        sleep 1
      done
      [ -s "$1" ] || die "$1 is still not materialised from iCloud (0 bytes). Open it in Finder and wait for the download to finish, then re-run."
    }

    icloud_ready() {
      [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ] \
        || die "iCloud Drive is not available. Sign in to iCloud and enable iCloud Drive, then re-run."
    }

    fingerprint() { # $1 = a private OR public key file -> SHA256:… (public, non-secret)
      ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'
    }
  '';
in
{
  # ---- nix run .#key-backup ---------------------------------------------------
  # Run this on a HEALTHY Mac, before you wipe it.
  key-backup = writeShellApplication {
    name = "key-backup";
    runtimeInputs = [
      age
      openssh
      coreutils
      gnugrep
    ];
    text = ''
      ${prelude}

      KIT="${kitDir}"
      KEY="$HOME/.ssh/id_ed25519"

      while [ $# -gt 0 ]; do
        case "$1" in
          --kit) KIT="$2"; shift 2 ;;
          --key) KEY="$2"; shift 2 ;;
          -h | --help)
            echo "key-backup [--kit DIR] [--key PATH]"
            echo "  Encrypts your operator SSH key to a passphrase and publishes the"
            echo "  recovery kit to iCloud. Only ciphertext ever leaves this machine."
            exit 0 ;;
          *) die "unknown argument: $1" ;;
        esac
      done

      [ -f "$KEY" ] || die "$KEY not found — nothing to back up."
      icloud_ready

      say "Publishing the recovery kit to $KIT"
      mkdir -p "$KIT"
      chmod 700 "$KIT"

      FP="$(fingerprint "$KEY")"
      [ -n "$FP" ] || die "$KEY is not a usable SSH key."

      # age -p prompts for the passphrase on /dev/tty and asks twice. The
      # passphrase never touches this script — by design.
      say "Encrypting $KEY (you will be asked for a passphrase, twice)"
      age -p -o "$KIT/${blobName}" "$KEY"
      chmod 600 "$KIT/${blobName}"

      # The bootstrap script that a wiped Mac will actually run, straight from
      # the store — i.e. the exact bytes CI shellchecked.
      install -m 755 ${./key-recovery/bootstrap.sh} "$KIT/bootstrap.sh"

      # MANIFEST is deliberately NON-SECRET: a fingerprint is public. It lets
      # key-recover prove the blob decrypted to the key it expected, instead of
      # trusting whatever came back and failing later at agenix time.
      #
      # printf, not a here-doc: inside a Nix indented string the here-doc body is
      # subject to Nix's own dedent, which can silently prepend spaces to every
      # line — and "  operator_fp = ..." would no longer match the ^operator_fp
      # parse in key-recover. printf has no such hazard.
      printf '%s\n' \
        "# Nix key-recovery kit — generated by 'nix run ${flakeRef}#key-backup'" \
        "# Non-secret. The private key is only ever present here as ${blobName}," \
        "# age-encrypted under a passphrase that exists only in your head." \
        "created      = $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "operator_fp  = $FP" \
        "flake        = ${flakeRef}" \
        "recover_with = ./bootstrap.sh" \
        > "$KIT/MANIFEST"
      chmod 644 "$KIT/MANIFEST"

      say "Kit published."
      printf '    %s\n' \
        "$KIT/${blobName}   (passphrase-encrypted private key)" \
        "$KIT/bootstrap.sh  (run this on the wiped Mac)" \
        "$KIT/MANIFEST      (fingerprint $FP)"
      printf '\n%s\n' \
        "    The passphrase lives only in your head / password manager. Do NOT store" \
        "    it anywhere that needs this key to unlock." \
        "" \
        "    After recovery, delete the kit from iCloud and empty 'Recently Deleted'" \
        "    (~30-day retention) — the ciphertext is strong, but it need not linger."
      notify "Recovery kit published to iCloud."
    '';
  };

  # ---- nix run .#key-recover --------------------------------------------------
  # Stage 2. bootstrap.sh execs this once Determinate Nix exists. Safe to run
  # directly on a machine that already has Nix.
  key-recover = writeShellApplication {
    name = "key-recover";
    runtimeInputs = [
      age
      git
      openssh
      gnused
      gnugrep
      coreutils
      agenix
    ];
    text = ''
            ${prelude}

            KIT="${kitDir}"
            REPO_DIR="$HOME/nix-config"
            REPO="git@github.com:${orgName}/nix-config.git"
            CHECK=0
            REDECRYPT=0
            FIX_ETC=0

            export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"

            while [ $# -gt 0 ]; do
              case "$1" in
                --kit) KIT="$2"; shift 2 ;;
                --check | --dry-run) CHECK=1; shift ;;
                --redecrypt) REDECRYPT=1; shift ;;
                --fix-etc) FIX_ETC=1; shift ;;
                -h | --help)
                  echo "key-recover [--kit DIR] [--check] [--redecrypt] [--fix-etc]"
                  exit 0 ;;
                *) die "unknown argument: $1" ;;
              esac
            done

            BLOB="$KIT/${blobName}"
            icloud_ready
            icloud_materialise "$BLOB"
            [ -f "$BLOB" ] || die "no encrypted key at $BLOB — has iCloud finished syncing the kit?"

            # The fingerprint we EXPECT, from the (non-secret) manifest.
            WANT_FP=""
            if [ -f "$KIT/MANIFEST" ]; then
              WANT_FP="$(sed -n 's/^operator_fp *= *//p' "$KIT/MANIFEST" | head -1)"
            fi

            if [ "$CHECK" -eq 1 ]; then
              say "DRY RUN — verifying the kit; nothing will be changed."
              echo "  [ok]  blob: $BLOB ($(wc -c < "$BLOB" | tr -d ' ') bytes)"
              echo "  [ok]  expected operator fingerprint: ''${WANT_FP:-<no MANIFEST>}"
              TMPD="$(mktemp -d)"
              trap 'rm -rf "$TMPD"' EXIT INT TERM
              echo "  Test-decrypting (enter your backup passphrase):"
              if age -d -o "$TMPD/key" "$BLOB"; then
                GOT_FP="$(fingerprint "$TMPD/key")"
                echo "  [ok]  decrypts; fingerprint: $GOT_FP"
                if [ -n "$WANT_FP" ] && [ "$GOT_FP" != "$WANT_FP" ]; then
                  echo "  [FAIL] fingerprint does NOT match MANIFEST — wrong or stale blob."
                  exit 1
                fi
                echo "  [ok]  matches MANIFEST."
              else
                echo "  [FAIL] could not decrypt — wrong passphrase or corrupt blob."
                exit 1
              fi
              exit 0
            fi

            # ---- 1. operator key -----------------------------------------------------
            mkdir -p "$HOME/.ssh"
            chmod 700 "$HOME/.ssh"
            # Re-runs must not re-prompt for the passphrase: a usable key already in
            # place is a no-op. --redecrypt forces it.
            if [ "$REDECRYPT" -ne 1 ] && [ -f "$HOME/.ssh/id_ed25519" ] \
               && ssh-keygen -y -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1; then
              say "Operator key already present — skipping decrypt (--redecrypt forces it)"
            else
              say "Decrypting the operator key -> ~/.ssh/id_ed25519"
              # Never clobber a DIFFERENT key without keeping a copy.
              if [ -f "$HOME/.ssh/id_ed25519" ]; then
                cp -p "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.before-restore"
                echo "    kept the previous key at ~/.ssh/id_ed25519.before-restore"
              fi
              age -d -o "$HOME/.ssh/id_ed25519" "$BLOB"
            fi
            chmod 600 "$HOME/.ssh/id_ed25519"

            # Prove what we hold is what the kit promised, BEFORE agenix depends on it.
            GOT_FP="$(fingerprint "$HOME/.ssh/id_ed25519")"
            if [ -n "$WANT_FP" ] && [ "$GOT_FP" != "$WANT_FP" ]; then
              die "the decrypted key ($GOT_FP) is not the operator key the kit expects ($WANT_FP).
      Wrong passphrase would have failed outright, so this is a STALE or swapped blob."
            fi

            ssh-keygen -y -f "$HOME/.ssh/id_ed25519" > "$HOME/.ssh/id_ed25519.pub"
            chmod 644 "$HOME/.ssh/id_ed25519.pub"
            printf '%s %s\n' "${orgName}@users.noreply.github.com" \
              "$(cat "$HOME/.ssh/id_ed25519.pub")" > "$HOME/.ssh/allowed_signers"
            chmod 600 "$HOME/.ssh/allowed_signers"

            # ---- 2. host key + clone -------------------------------------------------
            say "Ensuring this Mac has an SSH host key"
            sudo ssh-keygen -A
            [ -f /etc/ssh/ssh_host_ed25519_key.pub ] \
              || die "/etc/ssh/ssh_host_ed25519_key.pub missing after ssh-keygen -A — cannot re-key agenix."

            if [ ! -d "$REPO_DIR/.git" ]; then
              say "Cloning $REPO -> $REPO_DIR"
              git clone "$REPO" "$REPO_DIR"
            fi
            cd "$REPO_DIR" || die "cannot cd into $REPO_DIR"

            # ---- 3. agenix re-key ----------------------------------------------------
            # A reinstalled Mac has a NEW host key, so its recipient in secrets.nix must
            # be updated and every secret encrypted to it re-encrypted. The operator key
            # (restored above) is the other recipient, which is what lets agenix decrypt
            # in order to re-key at all.
            say "Re-keying this Mac's agenix secrets to its new host key"
            NEWKEY="$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
            sed -i "s|^  macos = \"ssh-ed25519 [A-Za-z0-9+/=]*\";|  macos = \"$NEWKEY\";|" secrets/secrets.nix
            # That sed is formatting-sensitive. If it silently matched nothing, agenix
            # would re-encrypt to the OLD recipient and the failure would surface much
            # later as an undecryptable secret at activation. Assert instead.
            grep -qF "$NEWKEY" secrets/secrets.nix \
              || die "secrets/secrets.nix was not updated with this Mac's host key.
      The 'macos = \"ssh-ed25519 ...\";' line may have been reformatted. Expected:
          $NEWKEY"

            (cd secrets && agenix -r -i "$HOME/.ssh/id_ed25519")

            # agenix -r re-keys EVERY secret, and age re-encryption emits different
            # bytes each time (fresh ephemeral keys) even when the recipients are
            # identical. Secrets NOT encrypted to `macos` therefore come back "modified"
            # with no semantic change. Drop that churn so the commit is exactly this
            # Mac's re-key. The keep-list is derived from secrets.nix, so adding a
            # secret later needs no edit here.
            KEEP="$(awk '
              /^[[:space:]]*"[^"]+\.age"\.publicKeys[[:space:]]*=/ {
                name = $0
                sub(/^[[:space:]]*"/, "", name); sub(/\.age".*$/, "", name)
                cur = name; inblock = 1; next
              }
              inblock && /^[[:space:]]*macos[[:space:]]*$/ { print cur ".age" }
              inblock && /\]/ { inblock = 0 }
            ' secrets/secrets.nix)"
            for f in secrets/*.age; do
              case " $KEEP " in
                *" $(basename "$f") "*) : ;;
                # `git checkout HEAD --`, not `git checkout --`: a previous run may have
                # already STAGED this churn, and the plain form restores from the index
                # (i.e. the churn), silently keeping it. HEAD is the only fixed point.
                *) git checkout HEAD -- "$f" 2>/dev/null || true ;;
              esac
            done
            git add -A
            say "Re-keyed to this Mac: ''${KEEP:-<none>} (other secrets reverted as no-op churn)"

            # ---- 4. activation -------------------------------------------------------
            # Through the flake's OWN #macos app, so this uses the PINNED nix-darwin
            # from flake.lock. The previous kit called github:LnL7/nix-darwin unpinned,
            # which is exactly how the removal of darwin-rebuild's sudo self-elevation
            # broke a recovery mid-flight. Must run as root: nix-darwin no longer
            # self-elevates. sudo -H, else nix warns that $HOME is not owned by root.
            say "Activating this Mac (darwin-rebuild switch, as root)"
            NIX_BIN=/nix/var/nix/profiles/default/bin/nix
            LOG="$(mktemp)"
            trap 'rm -f "$LOG"' EXIT INT TERM

            activate() { sudo -H "$NIX_BIN" run "$REPO_DIR#macos"; }

            set +e
            activate 2>&1 | tee "$LOG"
            RC=''${PIPESTATUS[0]}
            set -e

            # Gate on the log CONTENTS with a bash case rather than a grep regex: no
            # dialect ambiguity, no external binary, nothing to misfire.
            COLLISION=0
            case "$(cat "$LOG")" in
              *"Unexpected files in /etc"* | *"is in the way"*) COLLISION=1 ;;
            esac

            if [ "$RC" -ne 0 ] && [ "$COLLISION" -eq 1 ]; then
              # nix-darwin refuses to overwrite /etc content it did not write, and names
              # the files. Move them aside (never delete; never touch something already
              # managed by nix-darwin, i.e. a /nix/store symlink) and retry once.
              FILES="$(sed -n 's|^[[:space:]]\{1,\}\(/etc/[^[:space:]]*\)[[:space:]]*$|\1|p' "$LOG" | sort -u)"
              [ -n "$FILES" ] || die "nix-darwin reported an /etc collision but named no files."

              say "nix-darwin will not overwrite these /etc files:"
              for f in $FILES; do printf '      %s\n' "$f"; done
              if [ "$FIX_ETC" -ne 1 ]; then
                confirm "Move these /etc files aside (as .before-nix-darwin) and retry the switch?" \
                  || die "aborted; nothing was moved."
              fi
              for f in $FILES; do
                [ -e "$f" ] || continue
                if [ -L "$f" ] && readlink "$f" | grep -q '^/nix/store/'; then
                  warn "$f is already managed by nix-darwin — leaving it alone"
                  continue
                fi
                sudo mv "$f" "$f.before-nix-darwin.$(date +%Y%m%d-%H%M%S)"
                echo "    moved $f aside"
              done
              say "Retrying the activation"
              set +e
              activate 2>&1 | tee "$LOG"
              RC=''${PIPESTATUS[0]}
              set -e
            fi

            [ "$RC" -eq 0 ] || die "darwin-rebuild switch failed (see output above)."

            # ---- 5. what is left for a human ----------------------------------------
            notify "This Mac is recovered and activated."
            say "Recovered. Remaining steps:"
            # printf, not a here-doc: a here-doc body inside a Nix indented string
            # is subject to Nix's dedent, which can leave the terminator indented
            # (SC1039) or silently prepend spaces to the body.
            printf '\n%s\n' \
              "  # Persist the re-key (signed with your restored key):" \
              "  cd $REPO_DIR && git commit -m 're-key to reinstalled host key' && git push" \
              "" \
              "  # Optional logins:" \
              "  determinate-nixd login     # FlakeHub — native Linux builder" \
              "  gh auth login" \
              "" \
              "  # SECURITY — the kit is a private key in iCloud. Once you are satisfied:" \
              "  rm -rf '$KIT'             # then empty iCloud 'Recently Deleted' (~30 days)"
    '';
  };

  # The bootstrap script as a store artifact, shellchecked as a derivation. It is
  # NOT a writeShellApplication (it must run on a Mac with no Nix at all), so it
  # would otherwise be the one file in this repo nothing lints — which is exactly
  # how it drifted before.
  key-recovery-bootstrap = runCommand "key-recovery-bootstrap" { } ''
    ${lib.getExe shellcheck} --shell=bash --severity=style ${./key-recovery/bootstrap.sh}
    install -Dm755 ${./key-recovery/bootstrap.sh} "$out/bin/key-recovery-bootstrap"
  '';
}
