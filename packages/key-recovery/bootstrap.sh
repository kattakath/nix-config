#!/usr/bin/env bash
#
# key-recovery BOOTSTRAP — the only part of recovery that cannot live behind Nix.
#
# On a freshly reset Mac there is no Nix, no repo and no SSH key, so the thing
# that installs Nix cannot itself be run by Nix. This script is therefore plain
# bash with zero dependencies. It does the irreducible minimum:
#
#   0. clear a leftover "Nix Store" APFS volume + stale /etc entries
#   1. install Determinate Nix (curl CLI installer — NOT the .pkg)
#   2. move the installer's /etc/nix/nix.custom.conf aside (nix-darwin owns it)
#   3. hand off to `nix run <flake>#key-recover`, which does everything else
#
# Everything after step 3 lives in the flake (packages/key-recovery.nix), where
# it is shellcheck-gated by writeShellApplication and evaluated in CI. This file
# is the ONLY thing that has to be copied out-of-band, and `nix run .#key-backup`
# publishes it into the iCloud kit next to the encrypted key — so the copy on a
# wiped Mac is always the one CI linted.
#
# USAGE (from the iCloud recovery kit, after Setup Assistant + iCloud sign-in):
#     ./bootstrap.sh              # recover this Mac
#     ./bootstrap.sh --check      # report state, change NOTHING
#
set -euo pipefail

FLAKE_DEFAULT="github:ismailkattakath/nix-config"
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"

# A leftover "Nix Store" volume holds only APFS metadata (~25 KB); a real store
# is gigabytes. Never delete anything above this without an explicit --force.
STALE_VOLUME_MAX_BYTES=52428800 # 50 MB

FLAKE="$FLAKE_DEFAULT"
CHECK=0
FORCE_CLEAN=0
PASSTHRU=""

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    warning: %s\033[0m\n' "$*" >&2; }
die() {
  printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

# ---- macOS-native UX (osascript). Never used for authentication or secrets: --
# privilege escalation goes through sudo (Touch ID once nix-darwin's PAM config
# is active), and the age passphrase is read by age itself from /dev/tty, so it
# never transits another process's stdout. These are notices and confirmations
# only, and every one of them degrades to the terminal when there is no GUI.
has_gui() { [ -n "${SSH_TTY:-}" ] && return 1; launchctl managername 2>/dev/null | grep -q Aqua; }

notify() { # $1 = message
  has_gui || return 0
  /usr/bin/osascript -e "display notification \"$1\" with title \"Nix key recovery\"" \
    >/dev/null 2>&1 || true
}

confirm() { # $1 = question. GUI dialog if we have one, else a TTY prompt.
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
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

offer_reboot() {
  say "A reboot is required: macOS only re-evaluates the /nix firmlink at boot."
  if confirm "Nix recovery cleared a stale Nix install. Restart this Mac now, then re-run the kit?"; then
    /usr/bin/osascript -e 'tell application "System Events" to restart' >/dev/null 2>&1 && exit 0
    sudo /sbin/shutdown -r now
    exit 0
  fi
  die "Reboot this Mac, then re-run this script."
}

for arg in "$@"; do
  case "$arg" in
    --check | --dry-run) CHECK=1 ;;
    --force-clean-nix-volume) FORCE_CLEAN=1 ;;
    --flake=*) FLAKE="${arg#--flake=}" ;;
    # Anything else is for the stage-2 app (--kit, --redecrypt, --fix-etc, ...).
    *) PASSTHRU="$PASSTHRU $arg" ;;
  esac
done

# ---- helpers ----------------------------------------------------------------

nix_installed() {
  [ -e /nix/var/nix/profiles/default/bin/nix ] || command -v nix >/dev/null 2>&1
}

# Device id of every APFS volume named EXACTLY "Nix Store". Tracks the enclosing
# "+-> Volume diskXsY" header so a name can never be paired with the wrong
# device, and matches the name exactly — "Old Nix Store Backup" is not a hit.
nix_store_devs() {
  diskutil apfs list 2>/dev/null | awk '
    /\+-> Volume /  { dev = $3; next }
    /^[[:space:]]*Name:[[:space:]]/ {
      name = $0
      sub(/^[[:space:]]*Name:[[:space:]]*/, "", name)
      sub(/[[:space:]]*\(Case-[A-Za-z]*sensitive\)[[:space:]]*$/, "", name)
      sub(/[[:space:]]*$/, "", name)
      if (name == "Nix Store" && dev != "") print dev
    }
  ' | sort -u
}

# Bytes consumed, from: "Volume Used Space: 24.6 KB (24576 Bytes) (exactly ...)"
nix_store_bytes() {
  diskutil info "$1" 2>/dev/null | awk -F'[()]' '
    /^[[:space:]]*Volume Used Space:/ { split($2, a, " "); print a[1]; exit }
  '
}

# Determinate writes a UUID= fstab entry that does NOT contain "Nix Store"; the
# legacy nix.pkg installer writes LABEL=Nix\040Store. Match the MOUNT POINT so
# both are caught. Used with sed as \,RE,d — a COMMA delimiter, because '|' would
# collide with the alternation and '/' would need the /nix escaped.
FSTAB_NIX_RE='^[[:space:]]*(UUID=|LABEL=)[^[:space:]]+[[:space:]]+/nix[[:space:]]+apfs([[:space:]]|$)'
SYNTHETIC_NIX_RE='^nix([[:space:]]|$)'

# macOS ships /etc/synthetic.conf as 0600 root:wheel, so an unprivileged grep
# exits 2 (permission denied) — which a bare `if grep -q` misreads as "no entry"
# and silently skips the cleanup. Read it with sudo; in --check use `sudo -n` so
# a dry run never prompts, and report "unknown" instead of guessing.
SUDO_READ="sudo"

etc_has_nix() { # $1 = synthetic|fstab -> prints yes | no | unknown
  local f re
  case "$1" in
    synthetic)
      f=/etc/synthetic.conf
      re="$SYNTHETIC_NIX_RE"
      ;;
    fstab)
      f=/etc/fstab
      re="$FSTAB_NIX_RE"
      ;;
    *)
      echo unknown
      return
      ;;
  esac
  [ -f "$f" ] || {
    echo no
    return
  }
  if [ -r "$f" ]; then
    if grep -Eq "$re" "$f"; then echo yes; else echo no; fi
    return
  fi
  if $SUDO_READ cat "$f" 2>/dev/null | grep -Eq "$re"; then
    echo yes
  elif $SUDO_READ true 2>/dev/null; then
    echo no
  else
    echo unknown
  fi
}

backup_etc() { # $1 = path — timestamped, restorable, never clobbers
  local bak
  bak="$1.before-nix-recovery.$(date +%Y%m%d-%H%M%S)"
  sudo cp -p "$1" "$bak"
  echo "    backed up $1 -> $bak"
}

# ---- --check: report, change nothing -----------------------------------------
if [ "$CHECK" -eq 1 ]; then
  say "DRY RUN — reporting state; nothing will be changed."
  SUDO_READ="sudo -n" # never prompt for a password in a dry run

  if nix_installed; then
    echo "  [ok]  Nix is installed — the stale-volume preflight will not run."
  else
    echo "  [note] Nix is NOT installed."
    for dev in $(nix_store_devs); do
      bytes="$(nix_store_bytes "$dev")"
      if [ -z "$bytes" ]; then
        echo "  [WARN] 'Nix Store' volume $dev — size unknown; a real run REFUSES to delete it"
      elif [ "$bytes" -le "$STALE_VOLUME_MAX_BYTES" ]; then
        echo "  [STALE] 'Nix Store' volume $dev ($bytes bytes — empty): a real run deletes it, then reboots"
      else
        echo "  [KEEP]  'Nix Store' volume $dev holds $bytes bytes — a REAL store; never auto-deleted"
      fi
    done
    for f in fstab synthetic; do
      case "$f" in
        synthetic) p=/etc/synthetic.conf ;;
        *) p=/etc/fstab ;;
      esac
      case "$(etc_has_nix "$f")" in
        yes) echo "  [STALE] $p has a nix entry — a real run removes it (backed up first)" ;;
        no) echo "  [ok]  $p has no stale nix entry." ;;
        unknown) echo "  [?]   $p is root-only and sudo is not cached — run 'sudo -v' and re-check." ;;
      esac
    done
  fi
  if [ -e /etc/nix/nix.custom.conf ] && [ ! -L /etc/nix/nix.custom.conf ]; then
    echo "  [STALE] /etc/nix/nix.custom.conf is the installer's stub — a real run moves it aside"
  fi
  echo
  echo "  Then it would hand off to:  nix run $FLAKE#key-recover -- --check"
  if nix_installed; then
    say "Handing off to the flake's key-recover app (dry run)"
    exec /nix/var/nix/profiles/default/bin/nix run "$FLAKE#key-recover" -- --check --kit "$KIT_DIR"
  fi
  exit 0
fi

# ---- real run ----------------------------------------------------------------

say "Caching your admin password once (installer, host key, first switch)"
sudo -v
(while true; do
  sudo -n true
  sleep 50
  kill -0 "$$" 2>/dev/null || exit
done) </dev/null >/dev/null 2>&1 &
SUDO_KEEPALIVE=$!
# Kill the subshell AND its in-flight `sleep`: the sleep inherits our stdout and
# would hold it open for up to 50s after we exit (`bootstrap.sh | tee log` hangs).
trap 'pkill -P "$SUDO_KEEPALIVE" 2>/dev/null || true; kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

# 0. Stale "Nix Store" volume + /etc entries from a previous/partial install.
# A macOS reset wipes the OS but can leave the volume and its /etc/synthetic.conf
# + /etc/fstab entries behind; the installer then dies mounting /nix and the
# receipt write fails "Read-only file system".
#
# Guarding on "Nix is not installed" is NOT sufficient on its own: a healthy
# store that merely failed to MOUNT this boot looks identical. So a volume is
# deleted only when it is provably empty AND confirmed (or --force-clean-nix-volume).
if ! nix_installed; then
  NEED_REBOOT=0
  for dev in $(nix_store_devs); do
    bytes="$(nix_store_bytes "$dev")"
    [ -n "$bytes" ] || die "found 'Nix Store' volume $dev but cannot read its size; refusing to delete.
Inspect: diskutil info $dev  — then re-run with --force-clean-nix-volume if it really is a leftover."

    if [ "$bytes" -gt "$STALE_VOLUME_MAX_BYTES" ] && [ "$FORCE_CLEAN" -ne 1 ]; then
      die "'Nix Store' volume $dev holds $bytes bytes — that is a REAL Nix store, not a leftover.
Nix is not on PATH, but the store is probably just unmounted:
    sudo diskutil mount $dev
To delete it anyway (DESTRUCTIVE): --force-clean-nix-volume"
    fi

    say "Leftover 'Nix Store' APFS volume $dev ($bytes bytes) — from a previous/partial install"
    if [ "$FORCE_CLEAN" -ne 1 ]; then
      confirm "Delete the leftover APFS volume $dev ($bytes bytes)? This is DESTRUCTIVE." \
        || die "aborted at your request; nothing was changed."
    fi

    if command -v nix-installer >/dev/null 2>&1; then
      sudo nix-installer uninstall --no-confirm 2>/dev/null || true
    elif [ -x /nix/nix-installer ]; then
      sudo /nix/nix-installer uninstall --no-confirm 2>/dev/null || true
    fi
    if nix_store_devs | grep -qx "$dev"; then
      say "  deleting APFS volume $dev"
      sudo diskutil apfs deleteVolume "$dev" \
        || die "could not delete $dev — remove it in Disk Utility and re-run."
    fi
    NEED_REBOOT=1
  done

  if [ "$(etc_has_nix synthetic)" = yes ]; then
    say "Removing the stale /nix entry from /etc/synthetic.conf"
    backup_etc /etc/synthetic.conf
    sudo sed -i '' -E "\\,$SYNTHETIC_NIX_RE,d" /etc/synthetic.conf
    [ -s /etc/synthetic.conf ] || sudo rm -f /etc/synthetic.conf
    NEED_REBOOT=1
  fi
  if [ "$(etc_has_nix fstab)" = yes ]; then
    say "Removing the stale /nix entry from /etc/fstab"
    backup_etc /etc/fstab
    sudo sed -i '' -E "\\,$FSTAB_NIX_RE,d" /etc/fstab
    [ -s /etc/fstab ] || sudo rm -f /etc/fstab
  fi

  # Only a volume delete or a synthetic.conf change needs a reboot; an
  # fstab-only cleanup does not.
  [ "$NEED_REBOOT" -eq 1 ] && offer_reboot
fi

# 1. Determinate Nix — curl CLI installer, deliberately NOT the .pkg.
if [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  say "Installing Determinate Nix (curl CLI installer)"
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm
fi
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
command -v nix >/dev/null || die "nix not on PATH after install — open a new terminal and re-run."

# 2. Pre-empt the one /etc collision this setup hits EVERY time.
# The Determinate installer writes /etc/nix/nix.custom.conf (a comment-only
# stub). This flake sets determinateNix.customSettings (the Cachix substituters),
# which makes nix-darwin own that exact path — and nix-darwin refuses to
# overwrite /etc content it did not write ("Unexpected files in /etc, aborting
# activation"). Deterministic, so clear it up front instead of reacting to a
# failed switch. A file already managed by nix-darwin is a /nix/store symlink
# and is left alone, which keeps this idempotent.
if [ -e /etc/nix/nix.custom.conf ] && [ ! -L /etc/nix/nix.custom.conf ]; then
  say "Moving the installer's /etc/nix/nix.custom.conf aside (nix-darwin will own that path)"
  NCC_BAK="/etc/nix/nix.custom.conf.before-nix-darwin.$(date +%Y%m%d-%H%M%S)"
  sudo mv /etc/nix/nix.custom.conf "$NCC_BAK"
  echo "    moved -> $NCC_BAK  (original content preserved)"
fi

# 3. Hand off to the flake. Everything from here (decrypt, clone, agenix re-key,
# darwin-rebuild) is a writeShellApplication in packages/key-recovery.nix, which
# is lint-gated at build time and evaluated by CI, unlike this file.
# The repo is public, so this needs no key — the key is what it restores.
say "Handing off to $FLAKE#key-recover"
notify "Nix installed. Restoring your key and activating the system…"
# shellcheck disable=SC2086 # deliberate word-splitting: PASSTHRU is a flag list
exec nix run "$FLAKE#key-recover" -- --kit "$KIT_DIR" $PASSTHRU
