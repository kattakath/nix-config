#!/usr/bin/env bash
# provision-bootstrap.sh — Vast.ai PROVISIONING_SCRIPT entrypoint.
#
# Fetched anonymously by the vastai base image at first boot (see
# docs/vastai-template-provisioning.md). Clones a provisioning repo — PUBLIC or
# PRIVATE — at a pinned ref and execs its entrypoint. Private repos authenticate
# with a read-only token injected as a Vast ACCOUNT-level env var
# (GITLAB_TOKEN / GH_TOKEN), never baked into the (fetchable) template. This
# script itself carries NO secrets, so it is safe to serve from a public URL.
#
# Template env (all non-secret; set by `vast-template-apply`):
#   PROVISION_HOST        github.com | gitlab.com   (default github.com)
#   PROVISION_REPO        owner/repo                (required)
#   PROVISION_REF         commit SHA or branch      (default main)
#   PROVISION_ENTRYPOINT  path within the repo      (default provision.sh)
#   PROVISION_DIR         checkout dir              (default /workspace/provision)
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

host="${PROVISION_HOST:-github.com}"
repo="${PROVISION_REPO:-}"
ref="${PROVISION_REF:-main}"
entry="${PROVISION_ENTRYPOINT:-provision.sh}"
dest="${PROVISION_DIR:-/workspace/provision}"

if [ -z "$repo" ]; then
  echo "provision-bootstrap: PROVISION_REPO is required." >&2
  exit 1
fi

# Read-only token for this forge (empty => anonymous clone, i.e. a public repo).
case "$host" in
  gitlab.com) TOK="${GITLAB_TOKEN:-}" ;;
  github.com) TOK="${GH_TOKEN:-}" ;;
  *) TOK="" ;;
esac
export TOK

echo "provision-bootstrap: cloning ${host}/${repo}@${ref} -> ${dest}"
rm -rf "$dest"
# Token via a credential helper that reads $TOK from the environment — so it is
# never in argv, the remote URL, or (on failure) the error output. An empty $TOK
# yields an anonymous clone, which is exactly right for a public repo.
# shellcheck disable=SC2016
git -c credential.helper='!f(){ echo username=oauth2; echo "password=$TOK"; }; f' \
    -c credential.useHttpPath=false \
    clone --quiet "https://${host}/${repo}.git" "$dest"
git -C "$dest" checkout --quiet "$ref"
unset TOK

cd "$dest"
if [ ! -f "$entry" ]; then
  echo "provision-bootstrap: entrypoint '$entry' not found in ${repo}@${ref}." >&2
  exit 1
fi
echo "provision-bootstrap: running $entry"
exec bash "$entry"
