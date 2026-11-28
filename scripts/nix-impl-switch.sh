#!/usr/bin/env bash
# nix-impl-switch.sh — move a darwin host between Determinate Nix and upstream Nix
# WITHOUT reinstalling /nix (ADR-018 § 4a, the G1 procedure as code).
#
#   sudo scripts/nix-impl-switch.sh to-upstream    --flake <ref#host> --yes-really
#   sudo scripts/nix-impl-switch.sh to-determinate --flake <ref#host> --yes-really
#
# Since ADR-018 retired the Determinate lane (2026-11-27) this flake has only
# the upstream one, so to-upstream is the path that matters: bootstrap.sh points a
# Mac that still runs Determinate here. to-determinate needs a <ref#host> from
# before that retirement (git history) and the backup this script left behind.
# Without --yes-really it prints the plan and changes nothing (the default is a
# dry run, because this strips the running Nix daemon off a Mac).
#
# What it does, and why each step exists (all measured in a Tart guest, 2026-11-27):
#   to-upstream
#     1. back up Determinate's daemons, binary and /etc/nix files to $BACKUP
#     2. boot out the daemons — nix-darwin aborts while
#        /usr/local/bin/determinate-nixd exists (modules/system/checks.nix)
#     3. install upstream's org.nixos.darwin-store mount daemon: /etc/fstab marks
#        the encrypted store volume `noauto`, and `determinate-nixd init` was what
#        unlocked and mounted it at boot. It reuses the "Nix Store" passphrase
#        already in the System keychain.
#     4. darwin-rebuild switch with NIX_REMOTE=local (no daemon is running yet)
#   to-determinate
#     1. stop upstream's daemon, restore the backup, bootstrap Determinate
#     2. darwin-rebuild switch to the Determinate config
#     3. remove the org.nixos.nix-daemon plist nix-darwin leaves behind
#        ("restoring unmanaged Nix daemon"): it takes the socket, and
#        determinate-nixd then never serves — the step the hand run missed.
#
# A failure after step 2 of to-upstream restores Determinate (the EXIT trap).
set -euo pipefail

BACKUP=/var/root/nix-impl-switch-backup
DET_LABELS=(systems.determinate.nix-store systems.determinate.nix-daemon systems.determinate.nix-installer.nix-hook)
DET_BIN=/usr/local/bin/determinate-nixd
ETC_FILES=(/etc/nix/nix.conf /etc/nix/nix.custom.conf /etc/nix/registry.json /etc/nix/builder_ed25519 /etc/nix/builder_ed25519.pub /etc/determinate/config.json)
STORE_PLIST=/Library/LaunchDaemons/org.nixos.darwin-store.plist
UPSTREAM_DAEMON=/Library/LaunchDaemons/org.nixos.nix-daemon.plist

die() { echo "nix-impl-switch: $*" >&2; exit 1; }
say() { echo "nix-impl-switch: $*" >&2; }

dir=${1:-} ; shift || true
flake="" really=0
while [ $# -gt 0 ]; do
  case $1 in
    --flake) flake=${2:?}; shift 2 ;;
    --yes-really) really=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
case $dir in to-upstream | to-determinate) ;; *) die "usage: $0 to-upstream|to-determinate --flake <ref#host> [--yes-really]" ;; esac
[ -n "$flake" ] || die "--flake <ref#host> is required"
[ "$(uname -s)" = Darwin ] || die "darwin only"
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

run() { if [ "$really" -eq 1 ]; then "$@"; else echo "  would run: $*"; fi; }

# The store volume's UUID, read from the live mount, never hardcoded.
store_uuid() { /usr/sbin/diskutil info /nix | /usr/bin/awk -F': *' '/Volume UUID/ {print $2}'; }

write_store_plist() {
  local uuid; uuid=$(store_uuid)
  [ -n "$uuid" ] || die "cannot read the /nix volume UUID"
  /usr/bin/security find-generic-password -s "Nix Store" /Library/Keychains/System.keychain >/dev/null 2>&1 \
    || die "no \"Nix Store\" item in the System keychain: the store could not be unlocked at boot"
  cat > "$STORE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.nixos.darwin-store</string>
  <key>RunAtLoad</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>/usr/bin/security find-generic-password -s "Nix Store" -w | /usr/sbin/diskutil apfs unlockVolume "$uuid" -mountpoint /nix -stdinpassphrase</string>
  </array>
  <key>StandardErrorPath</key><string>/var/log/darwin-store.log</string>
</dict>
</plist>
PLIST
  chmod 644 "$STORE_PLIST"
}

# The system closure for the TARGET config, built before anything is stopped.
build_target() {
  local nix; nix=$(readlink -f /nix/var/nix/profiles/default/bin/nix)
  "$nix" --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths "${flake%%#*}#darwinConfigurations.${flake#*#}.system"
}

# nix-darwin removes a service only if it is listed under /run/current-system
# when activation starts (modules/system/launchd.nix), so a lane's own units can
# survive the switch. Measured in the 2026-11-27 rehearsal: nix-store-clean
# stayed loaded next to nh-clean. Sweep the OTHER lane's units, by name only.
sweep_lane_units() {
  local u
  for u in "$@"; do
    [ -e "/run/current-system/Library/LaunchDaemons/$u.plist" ] && continue
    [ -e "/Library/LaunchDaemons/$u.plist" ] || continue
    say "removing leftover $u (not in the active generation)"
    launchctl bootout "system/$u" 2>/dev/null || true
    rm -f "/Library/LaunchDaemons/$u.plist"
  done
}

restore_determinate() {
  say "restoring Determinate from $BACKUP"
  launchctl bootout system/org.nixos.nix-daemon 2>/dev/null || true
  [ -e "$BACKUP/determinate-nixd" ] && mv "$BACKUP/determinate-nixd" "$DET_BIN"
  for f in "${ETC_FILES[@]}"; do
    [ -e "$BACKUP/etc$f" ] || [ -L "$BACKUP/etc$f" ] || continue
    rm -f "$f"; mkdir -p "$(dirname "$f")"; mv "$BACKUP/etc$f" "$f"
  done
  rm -f "$STORE_PLIST" "$UPSTREAM_DAEMON"
  for l in "${DET_LABELS[@]}"; do
    [ -e "$BACKUP/$l.plist" ] && mv "$BACKUP/$l.plist" "/Library/LaunchDaemons/$l.plist"
    launchctl bootstrap system "/Library/LaunchDaemons/$l.plist" 2>/dev/null || true
  done
  # Only EMPTY directories go, so anything not restored stays visible in $BACKUP
  # and blocks the next to-upstream until someone looks.
  find "$BACKUP" -depth -type d -empty -delete 2>/dev/null || true
}

if [ "$dir" = to-upstream ]; then
  [ -x "$DET_BIN" ] || die "Determinate is not installed here ($DET_BIN missing)"
  [ ! -e "$BACKUP" ] || die "$BACKUP exists: a previous switch was not rolled back. Inspect it first."
  say "plan: Determinate -> upstream, store volume $(store_uuid), target $flake"
  sys=$(build_target) || die "the target config does not build; nothing changed"
  say "target system: $sys"
  [ "$really" -eq 1 ] || { say "dry run: pass --yes-really to switch"; run launchctl bootout "system/${DET_LABELS[1]}"; exit 0; }

  mkdir -p "$BACKUP/etc"
  trap 'say "FAILED — rolling back"; restore_determinate' EXIT
  trap 'exit 130' INT TERM # route signals through the EXIT trap
  for l in "${DET_LABELS[@]}"; do
    launchctl bootout "system/$l" 2>/dev/null || true
    mv "/Library/LaunchDaemons/$l.plist" "$BACKUP/"
  done
  mv "$DET_BIN" "$BACKUP/"
  for f in "${ETC_FILES[@]}"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    mkdir -p "$BACKUP/etc$(dirname "$f")"; mv "$f" "$BACKUP/etc$f"
  done
  write_store_plist
  # Rehearsal hook: prove the EXIT trap restores a host with its daemons already gone.
  [ "${NIX_IMPL_SWITCH_INJECT_FAILURE:-}" != after-stop ] || die "injected failure (after-stop)"
  NIX_REMOTE=local "$sys/sw/bin/darwin-rebuild" switch --flake "$flake"
  trap - EXIT
  sweep_lane_units org.nixos.nix-store-clean
  say "done: upstream Nix. Backup kept at $BACKUP for to-determinate. Reboot to prove the store mount."
else
  [ -d "$BACKUP" ] || die "no backup at $BACKUP: nothing to roll back to"
  say "plan: upstream -> Determinate, target $flake"
  [ "$really" -eq 1 ] || { say "dry run: pass --yes-really to switch"; exit 0; }
  restore_determinate
  sleep 5
  "$(readlink -f /nix/var/nix/profiles/system)/sw/bin/darwin-rebuild" switch --flake "$flake"
  # nix-darwin re-creates an unmanaged org.nixos.nix-daemon on the way out; it
  # would hold the socket and keep determinate-nixd from serving.
  launchctl bootout system/org.nixos.nix-daemon 2>/dev/null || true
  rm -f "$UPSTREAM_DAEMON"
  sweep_lane_units org.nixos.nh-clean org.nixos.linux-builder
  launchctl kickstart -k system/systems.determinate.nix-daemon
  rmdir "$BACKUP/etc" 2>/dev/null || true
  say "done: Determinate. Leftovers (if any) in $BACKUP. Reboot to prove it."
fi
