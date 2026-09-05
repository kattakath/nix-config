# macvm Tart control-plane (host Mac only) — a thin macvm veneer over the
# extracted nix-tart-macos flake (github.com/kattakath/nix-tart-macos), which
# owns the generic lifecycle, the plug-and-play bootstrap chain, and the
# golden-image bake. Extracted 2026-09-05 because the ecosystem sweep found NO
# existing Tart lifecycle/provisioning flake anywhere (this repo held the only
# tart-guest-agent packaging on GitHub); same adoption pattern as
# vast-provision: pure callPackage on the input's SOURCE path (flake.nix
# § inputs) — the input's own flake outputs are never evaluated.
#
# This veneer pins only the macvm specifics:
#   * VM name "macvm"
#   * host ~/Downloads as the shared-dir default (the guest symlinks its own
#     ~/Downloads onto it — hosts/macvm.nix; ONE shared inbox, rotated
#     host-side only)
#   * identity + fleet flake for the plug-and-play bootstrap
#     (github:kattakath/nix-config#macvm as the operator's login)
#   * legacy MACVM_* env overrides mapped onto the generic TART_VM_* ones
# Disks/IPSWs never enter the Nix store (~/.tart/vms/<name>).
# See docs/macvm-tart-runbook.md.
{
  lib,
  writeShellApplication,
  writeText,
  callPackage,
  tartVmSrc, # nix-tart-macos input source path (threaded from flake.nix)
  loginName,
  fullName,
}:
let
  # packer-plugin-tart is the input's own sibling package (not a nixpkgs attr),
  # so plain callPackage cannot auto-resolve it — pass it explicitly.
  tartVm = callPackage "${tartVmSrc}/packages/tart-vm.nix" {
    packer-plugin-tart = callPackage "${tartVmSrc}/packages/packer-plugin-tart.nix" { };
  };
  vmName = "macvm";

  # Legacy env names stay honored (runbooks + muscle memory predate the
  # extraction); the generic CLI reads TART_VM_*.
  envShim = ''
    export TART_VM_DOWNLOADS="''${MACVM_HOST_DOWNLOADS:-''${TART_VM_DOWNLOADS:-$HOME/Downloads}}"
    export TART_VM_LOG_DIR="''${MACVM_TART_LOG_DIR:-''${TART_VM_LOG_DIR:-$HOME/Library/Logs}}"
    if [ -n "''${MACVM_TART_DISK_GB:-}" ]; then export TART_VM_DISK_GB="$MACVM_TART_DISK_GB"; fi
    if [ -n "''${MACVM_TART_CPUS:-}" ]; then export TART_VM_CPUS="$MACVM_TART_CPUS"; fi
    if [ -n "''${MACVM_TART_MEMORY_MB:-}" ]; then export TART_VM_MEMORY_MB="$MACVM_TART_MEMORY_MB"; fi
    if [ -n "''${MACVM_SSH_IDENTITY:-}" ]; then export TART_VM_SSH_IDENTITY="$MACVM_SSH_IDENTITY"; fi
  '';

  mkAlias =
    sub: extraArgs:
    writeShellApplication {
      name = "macvm-tart-${sub}";
      runtimeInputs = [ tartVm ];
      text = ''
        ${envShim}
        exec tart-vm --vm ${vmName} ${sub} ${extraArgs} "$@"
      '';
    };

  createHelp = writeText "macvm-tart-create-help.txt" ''
    No macvm VM exists yet. Plug-and-play path (one command each):

      nix run .#macvm-tart-bake        # golden image locally from Apple IPSW (trusted, ~45 min once)
        — or —
      nix run .#macvm-tart-pull -- --image ghcr.io/cirruslabs/macos-tahoe-vanilla --digest sha256:...
        — or —
      nix run .#macvm-tart-create      # raw IPSW + manual Setup Assistant (legacy)

    Then: nix run .#macvm-tart-start && nix run .#macvm-tart-bootstrap
    NEVER put IPSW or disk images into the Nix store or this git repo.
  '';
in
{
  # Generic lifecycle, macvm-flavored. `bootstrap` carries the fleet identity:
  # the golden/registry image is operator-neutral; identity injects HERE
  # (creates ${loginName}, installs Determinate Nix, activates the fleet
  # flake's #macvm, rotates the password, prints it once).
  macvm-tart-create = mkAlias "create" "";
  macvm-tart-pull = mkAlias "pull" "";
  macvm-tart-bake = mkAlias "bake" "";
  macvm-tart-start = mkAlias "start" "";
  macvm-tart-stop = mkAlias "stop" "";
  macvm-tart-ip = mkAlias "ip" "";
  macvm-tart-ssh = mkAlias "ssh" "";
  macvm-tart-list = mkAlias "list" "";
  macvm-tart-doctor = mkAlias "doctor" "";
  macvm-tart-bootstrap = mkAlias "bootstrap" "--user ${lib.escapeShellArg loginName} --fullname ${lib.escapeShellArg fullName} --flake github:kattakath/nix-config#macvm";

  # Machine-checkable "does the VM exist" gate (exit 0 / exit 2 + help) —
  # thin over the generic `exists` probe so scripts keep the old contract.
  macvm-tart-ensure = writeShellApplication {
    name = "macvm-tart-ensure";
    runtimeInputs = [ tartVm ];
    text = ''
      if tart-vm --vm ${vmName} exists; then exit 0; fi
      cat ${createHelp} >&2
      exit 2
    '';
  };

  # Historical name kept: prints the (now one-command) guest story.
  macvm-tart-bootstrap-print = writeShellApplication {
    name = "macvm-tart-bootstrap-print";
    text = ''
      cat <<'EOF'
      macvm guest provisioning is plug-and-play now (host-side, no GUI):

        nix run .#macvm-tart-bake        # once per macOS release (or -pull)
        nix run .#macvm-tart-start
        nix run .#macvm-tart-bootstrap   # creates ${loginName}, Nix, activates #macvm

      Legacy manual path (raw IPSW): docs/macvm-tart-runbook.md § Legacy.
      Thereafter (re-activate from host):
        nix run .#macvm-tart-ssh -- nix run --refresh github:kattakath/nix-config#macvm
      EOF
    '';
  };
}
