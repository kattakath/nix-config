#!/usr/bin/env bash
# Build a UTM-importable qcow2 image for nixbox and drop it in dist/.
# Run from the repo root inside the devcontainer; the output lands in the
# workspace bind-mount so it's immediately available on the Mac host.
#
# Usage: ./scripts/build-nixbox-image.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

git add -A

echo "→ building nixbox qcow2 image (takes ~20 min without cache)…"
nix build .#nixosConfigurations.nixbox.config.system.build.images.qemu-efi \
  --print-build-logs

# Extract NixOS version from the built filename for a meaningful name.
SRC=$(readlink -f result/nixos-image-*.qcow2 2>/dev/null \
      || ls result/*.qcow2 2>/dev/null | head -1)
VERSION=$(basename "$SRC" | grep -oP '\d+\.\d+\.\d+\.\w+' | head -1 \
          || echo "$(date +%Y%m%d)")

DEST="$REPO_ROOT/dist/nixbox-aarch64-${VERSION}.qcow2"
mkdir -p "$REPO_ROOT/dist"
cp "$SRC" "$DEST"

echo "✓ image ready: dist/nixbox-aarch64-${VERSION}.qcow2"
echo "  size: $(du -sh "$DEST" | cut -f1)"
echo "  → accessible on Mac at: $DEST"
