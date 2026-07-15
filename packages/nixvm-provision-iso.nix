# nixvm installer-ISO provisioner — the macOS-side, all-Nix companion to the
# nixvm-qemu-provision skill. Downloads the PREBUILT nixvm installer ISO from the
# rolling installer-latest GitHub release and lays down the QEMU system disk + EDK2
# NVRAM store the launchd daemon (modules/darwin/nixvm-qemu.nix) boots from — so a
# (re)install needs NEITHER Docker Desktop NOR a Determinate Linux builder on the Mac
# (which is what building `.#nixvm-installer-iso` locally would otherwise require).
#
#   nix run .#nixvm-provision-iso   — download ISO + create disk.qcow2 + seed efivars
#
# Returns a single `writeShellApplication` (shellcheck'd at `nix flake check`), wired
# as a flake app in flake.nix. Design notes mirror packages/nixpi-provision.nix:
#   * nix-provided tools (gh, qemu-img, coreutils) come via runtimeInputs; the EDK2
#     firmware template is referenced by its qemu store path (house style).
#   * The disk + efivars land where the daemon expects them (default /var/lib/nixvm).
#     The disk is GUARDED — this never silently clobbers an installed VM.
#   * This is only the acquire+prep step. The operator still: (1) pre-generates the
#     SSH host key + re-keys agenix, (2) boots the ISO under QEMU + runs nixos-anywhere,
#     (3) resets NVRAM + re-bootstraps the daemon. See the skill + docs/nixvm-qemu-runbook.md.
{
  writeShellApplication,
  coreutils,
  gh,
  qemu,
}:
writeShellApplication {
  name = "nixvm-provision-iso";
  runtimeInputs = [
    coreutils
    gh
    qemu
  ];
  text = ''
    # Prep a nixvm (re)install on this Mac WITHOUT building the ISO locally:
    #   1. download the prebuilt installer ISO from the installer-latest release
    #   2. create the empty qcow2 system disk (guarded — never clobber an installed VM)
    #   3. seed the EDK2 NVRAM store from the pristine template
    dir="/var/lib/nixvm"
    iso=""
    size="128G"
    force=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dir) dir="''${2:?}"; shift 2 ;;
        --iso) iso="''${2:?}"; shift 2 ;;
        --size) size="''${2:?}"; shift 2 ;;
        --force) force=1; shift ;;
        -h | --help) echo "usage: nixvm-provision-iso [--dir DIR] [--iso FILE.iso] [--size 128G] [--force]"; exit 0 ;;
        *) echo "nixvm-provision-iso: unknown argument: $1" >&2; exit 1 ;;
      esac
    done

    if [ ! -d "$dir" ]; then
      echo "nixvm-provision-iso: $dir does not exist — activate the macos config first" >&2
      echo "  (services.nixvm-qemu creates it), or pass --dir to a writable location." >&2
      exit 1
    fi
    if [ ! -w "$dir" ]; then
      echo "nixvm-provision-iso: $dir is not writable by $(id -un)." >&2
      exit 1
    fi

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    # 1. ISO: --iso wins; else download the prebuilt asset from installer-latest.
    if [ -z "$iso" ]; then
      echo "nixvm-provision-iso: downloading the prebuilt nixvm ISO (installer-latest release)…"
      # The ISO asset is nixos-minimal-<label>-aarch64-linux.iso; the nixpi image on
      # the same release is *.img.zst, so this .iso glob uniquely selects the ISO.
      gh release download installer-latest -R kattakath/nix-config \
        -p 'nixos-minimal-*.iso' -D "$tmp" --clobber
      set -- "$tmp"/nixos-minimal-*.iso
      iso="$1"
      [ -f "$iso" ] || { echo "nixvm-provision-iso: no ISO asset found on installer-latest." >&2; exit 1; }
    fi
    [ -f "$iso" ] || { echo "nixvm-provision-iso: ISO not found: $iso" >&2; exit 1; }
    if [ "$iso" != "$dir/nixvm-installer.iso" ]; then
      cp -f "$iso" "$dir/nixvm-installer.iso"
    fi
    echo "nixvm-provision-iso: ISO at $dir/nixvm-installer.iso"

    # 2. System disk. GUARD: never silently clobber an installed VM's disk.
    if [ -e "$dir/disk.qcow2" ] && [ -z "$force" ]; then
      echo "nixvm-provision-iso: $dir/disk.qcow2 already exists — refusing to overwrite an" >&2
      echo "  installed VM. Stop the daemon (sudo launchctl bootout system/org.nixos.nixvm-qemu)" >&2
      echo "  and pass --force to recreate a blank disk." >&2
      exit 1
    fi
    qemu-img create -f qcow2 "$dir/disk.qcow2" "$size"

    # 3. EDK2 NVRAM store from the pristine template (writable copy). Note the
    # asymmetric name: CODE is edk2-aarch64-code.fd, the VARS template is edk2-ARM-vars.fd.
    cp -f "${qemu}/share/qemu/edk2-arm-vars.fd" "$dir/efivars.fd"
    chmod u+w "$dir/efivars.fd"

    echo "nixvm-provision-iso: done. $dir now has nixvm-installer.iso, disk.qcow2, efivars.fd."
    echo "Next (see the nixvm-qemu-provision skill):"
    echo "  1. Pre-generate the SSH host key + re-key agenix (secrets/secrets.nix nixvm=…)."
    echo "  2. Boot the ISO under QEMU headless (hostfwd tcp::2222-:22), plant root's key."
    echo "  3. nixos-anywhere --flake .#nixvm --build-on remote --extra-files <dir> --target-host root@localhost --ssh-port 2222"
    echo "  4. Reset efivars + re-bootstrap the launchd daemon (disk-only, no ISO)."
  '';
}
