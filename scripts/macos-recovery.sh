#!/usr/bin/env bash
#
# macOS post-reset recovery for the nix-config fleet — one command instead of a
# dozen paste-lines. NOT unattended: it will prompt for your admin password and
# (at the end) for optional tool logins. Everything else runs itself. Safe to
# re-run (idempotent: skips steps already done).
#
# RUN IT AFTER:
#   1. macOS Setup Assistant is finished (user account created).
#   2. The KEYVAULT backup drive is plugged in and UNLOCKED (Finder mounts it at
#      /Volumes/KEYVAULT).
# Then:  bash /Volumes/KEYVAULT/macos-recovery.sh      (or from a repo checkout)
#
# WHAT IT DOES (this header is the runbook):
#   restore id_ed25519 → install Determinate Nix → derive the sops age key →
#   clone the repo → re-key secrets/macos.yaml to THIS Mac's new host key →
#   darwin-rebuild switch. It stops and tells you the interactive leftovers
#   (FlakeHub / gh / claude logins, git push).
#
# The manual bits it can't do (by design): Setup Assistant, unlocking the
# encrypted USB, your sudo password, and OAuth logins.

set -euo pipefail

# ---- config (the only lines to edit if identity changes) --------------------
HANDLE="ismailkattakath"
EMAIL="ismail@kattakath.com"
REPO="git@github.com:${HANDLE}/nix-config.git"   # SSH remote → id_ed25519 auth, no gh/token needed
REPO_DIR="$HOME/${HANDLE}/nix-config"
KEYVAULT="/Volumes/KEYVAULT"
AGE_KEY="$HOME/.config/sops/age/keys.txt"

# nix-provided git so we never trip the Xcode Command-Line-Tools GUI prompt on a
# fresh Mac; accept-new host key so the first github.com SSH connection is silent.
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
git() { command nix run nixpkgs#git -- "$@"; }
ssh_to_age() { command nix run nixpkgs#ssh-to-age -- "$@"; }

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. preflight -----------------------------------------------------------
[ -f "$KEYVAULT/ssh/id_ed25519" ] \
  || die "KEYVAULT not mounted, or key missing at $KEYVAULT/ssh/id_ed25519 — plug in and unlock the drive."
say "Caching your admin password once (used for the installer, host key, and first switch)"
sudo -v
# keep sudo alive in the background while the script runs
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &

# ---- 1. restore the operator key -------------------------------------------
say "Restoring ~/.ssh/id_ed25519 from KEYVAULT"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp "$KEYVAULT/ssh/id_ed25519" ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub && chmod 644 ~/.ssh/id_ed25519.pub
# rebuild the git commit-signature allow-list (email + this key) so local
# verification works too — trivially regenerable, hence not worth backing up.
printf '%s %s\n' "$EMAIL" "$(cat ~/.ssh/id_ed25519.pub)" > ~/.ssh/allowed_signers
chmod 600 ~/.ssh/allowed_signers

# ---- 2. install Determinate Nix (CLI installer) -----------------------------
if [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  say "Installing Determinate Nix (CLI installer)"
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm
fi
# make nix usable in THIS shell
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
command -v nix >/dev/null || die "nix not on PATH after install — open a new terminal and re-run."

# ---- 3. sops age key (prefer the backed-up file, else derive from the key) ---
say "Restoring the sops age key"
mkdir -p "$(dirname "$AGE_KEY")"
if [ -f "$KEYVAULT/sops-age/keys.txt" ]; then
  cp "$KEYVAULT/sops-age/keys.txt" "$AGE_KEY"
else
  ssh_to_age -private-key -i ~/.ssh/id_ed25519 > "$AGE_KEY"   # derived from id_ed25519
fi
chmod 600 "$AGE_KEY"

# ---- 4. host key + clone ----------------------------------------------------
say "Ensuring this Mac has an SSH host key"
sudo ssh-keygen -A
if [ ! -d "$REPO_DIR/.git" ]; then
  say "Cloning $REPO → $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO" "$REPO_DIR"
fi
cd "$REPO_DIR"

# ---- 5. re-key secrets/macos.yaml to THIS Mac's (new) host key --------------
# The old host key wasn't backed up (minimal backup), so the reinstalled Mac has
# a new one. Your operator key can still DECRYPT macos.yaml, so we re-encrypt it
# to the new host key + operator. If the host key was somehow restored/unchanged
# this is a harmless no-op.
say "Re-keying secrets/macos.yaml to this Mac's host key"
NEW=$(ssh_to_age < /etc/ssh/ssh_host_ed25519_key.pub)
nix run nixpkgs#gnused -- -i "s|\(&macos \)age1[0-9a-z]\{1,\}|\1${NEW}|" .sops.yaml
SOPS_AGE_KEY_FILE="$AGE_KEY" nix run nixpkgs#sops -- updatekeys -y secrets/macos.yaml
git add -A

# ---- 6. first activation ----------------------------------------------------
say "Activating the macos config (darwin-rebuild switch) — this is the big one"
echo "    If it aborts on an /etc file collision (shells/bashrc) or the Homebrew"
echo "    bootstrap, follow its hint (usually a one-line 'mv') and re-run this script."
nix run "github:LnL7/nix-darwin#darwin-rebuild" -- switch --flake ".#macos"
# once the macos-activate app (PR #134) is on main you can instead: nix run .#macos

# ---- 7. what's left (interactive, optional) ---------------------------------
say "Base system is up. Remaining interactive steps (do as needed):"
cat <<EOF

  # Persist the re-key so the repo matches this Mac (uses your restored SSH key):
  cd "$REPO_DIR" && git commit -m "macos, sops: re-key secrets/macos.yaml to reinstalled host key" && git push

  # FlakeHub login — only needed for the native Linux builder (dtr.mn/features):
  determinate-nixd login

  # Other tool logins as needed:
  gh auth login        # only if you prefer HTTPS git / gh workflows
  claude               # then /login

Git commit signing already works (your id_ed25519 is the signing key).
EOF
