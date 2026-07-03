# `nix run .#nixbox-vm` — boot the nixbox qcow2 in QEMU with Apple HVF
# acceleration. No UTM required. User-mode networking with hostfwd 2222→22 for
# direct SSH before the Cloudflare tunnel is active.
#
# This is inherently imperative (it spawns a QEMU process), so it lives in a
# writeShellApplication rather than a NixOS module: build-time shellcheck gates
# it via `nix flake check`, and runtimeInputs give it a hermetic PATH
# (coreutils + qemu) instead of leaning on the caller's environment.
#
# Prerequisites:
#   1. Build qcow2 on an aarch64-linux builder: nix build .#nixbox-image
#   2. Copy to the default disk path (or set NIXBOX_DISK=/path/to/qcow2):
#        cp result/*.qcow2 ~/.local/state/nixbox-vm/nixbox.qcow2
{ pkgs }:

pkgs.writeShellApplication {
  name = "run-nixbox-vm";
  runtimeInputs = [
    pkgs.coreutils # mkdir / cp — hermetic, not the caller's PATH
    pkgs.qemu # qemu-system-aarch64
  ];
  # writeShellApplication injects `set -euo pipefail` and runs shellcheck.
  text = ''
    STATE="''${XDG_STATE_HOME:-$HOME/.local/state}/nixbox-vm"
    DISK="''${NIXBOX_DISK:-$STATE/nixbox.qcow2}"
    VARS="$STATE/OVMF_VARS.fd"

    FIRMWARE_CODE="${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd"
    FIRMWARE_VARS="${pkgs.qemu}/share/qemu/edk2-aarch64-vars.fd"

    if [ ! -f "$FIRMWARE_CODE" ]; then
      echo "error: aarch64 UEFI firmware not found at $FIRMWARE_CODE" >&2
      echo "hint: check that pkgs.qemu ships edk2-aarch64-code.fd on aarch64-darwin" >&2
      exit 1
    fi

    if [ ! -f "$DISK" ]; then
      echo "error: nixbox disk image not found: $DISK" >&2
      echo "" >&2
      echo "Build it (requires an aarch64-linux builder or remote builder):" >&2
      echo "  nix build .#nixbox-image && cp result/*.qcow2 $DISK" >&2
      echo "" >&2
      echo "Or point to an existing qcow2:  NIXBOX_DISK=/path/to/nixbox.qcow2 nix run .#nixbox-vm" >&2
      exit 1
    fi

    mkdir -p "$STATE"

    # Copy UEFI vars on first run so boot-order changes persist across reboots.
    if [ ! -f "$VARS" ] && [ -f "$FIRMWARE_VARS" ]; then
      cp "$FIRMWARE_VARS" "$VARS"
    fi

    # Build the optional pflash-vars flag as an ARRAY so a $VARS path containing
    # spaces stays a single argv token (space-safe + shellcheck-clean, unlike an
    # unquoted string that relied on word-splitting).
    pflash_vars=()
    if [ -f "$VARS" ]; then
      pflash_vars=(-drive "if=pflash,format=raw,file=$VARS")
    fi

    echo "nixbox-vm: booting $DISK" >&2
    echo "  SSH (direct):  ssh -p 2222 izzy@localhost" >&2
    echo "  SSH (tunnel):  ssh izzy@nixbox.kattakath.com  (once tunnel is active)" >&2
    echo "  QEMU monitor:  Ctrl-a c  (then 'quit' to exit)" >&2

    exec qemu-system-aarch64 \
      -machine virt,accel=hvf \
      -cpu host \
      -m "''${NIXBOX_MEMORY:-2048}" \
      -smp "''${NIXBOX_CPUS:-4}" \
      -drive "if=pflash,format=raw,file=$FIRMWARE_CODE,readonly=on" \
      "''${pflash_vars[@]}" \
      -drive "file=$DISK,format=qcow2,if=virtio" \
      -netdev user,id=net0,hostfwd=tcp::2222-:22 \
      -device virtio-net-pci,netdev=net0 \
      -serial mon:stdio \
      -nographic
  '';
}
