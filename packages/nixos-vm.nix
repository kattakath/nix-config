# `nixos-vm` — create and drive the long-lived `nixos` guest as a UTM (QEMU
# backend) virtual machine on the macos host.
#
#   nixos-vm create [--image FILE.raw] [--flake PATH]  one-time: seed disk → boot → first switch
#   nixos-vm switch [--flake PATH]                     nixos-rebuild switch over ssh (the update path)
#   nixos-vm start | stop | status                     thin `utmctl` wrappers, by UUID
#   nixos-vm ssh [ARGS…]                               ssh nixos.local
#   nixos-vm destroy --yes                             utmctl delete + remove the bundle
#
# WHY the image is resolved at RUNTIME, not baked into this script: a store path
# of the aarch64-linux image in the script text would make `nix flake check`'s
# darwin leg BUILD the whole guest (no Linux builder there) and drag a
# multi-GB image into the macos closure via home.packages — the exact reason
# modules/parts/packages.nix keeps `nixvmRunner` out of `packages`. Resolving it
# in `create` (the `nixpi-flash` "build, or --image" precedent in
# packages/nixpi-provision.nix) keeps this a tiny pure-darwin package that is
# safe in `packages`, in the flake check, and on PATH for the Spotlight launcher.
#
# WHY SEED + SWITCH: the image is a small SEED system (boots, sshd, operator
# key), and the desktop arrives by the first `nixos-rebuild switch`. The full
# ~6.7 GiB closure cannot be staged into a disk image on this Mac's Determinate
# Linux builder, whose /build is the builder VM's RAM tmpfs (~3.9 GiB).
#
# WHERE THE FLAKE COMES FROM: `--flake PATH`, else $NIXOS_VM_FLAKE, else the
# checkout /etc/nix-darwin/flake.nix links to. That link IS
# `operatorFlakeRelPath` (modules/parts/hosts.nix) materialised under the
# operator's runtime $HOME, so reading it re-uses the one derivation of the
# path instead of re-deriving org/repo here — a second copy would drift on a
# rename, and modules/home/ (which also builds this package) is not handed
# orgName/repoName at all. Like `activate`, it is the MAIN checkout's current
# branch, never a worktree's.
#
# WHY a real file and not a store symlink for config.plist: UTM rewrites the
# bundle's config.plist when settings change in its GUI; a read-only store
# symlink would fail that write.
#
# WHY qcow2: UTM passes NO `format=` to QEMU, so QEMU probes the disk, and a
# probed raw image gets block-0 writes restricted (measured 2026-10-17) — the
# guest could not write its own partition table. Converting once to qcow2
# removes the probe ambiguity.
#
# UPSTREAM-FIRST (.claude/rules/upstream-first.md):
#   ✅ grepped nix-darwin (4cff07de) and home-manager (c58f54c7) modules/ for
#      `\butm\b|utmctl` — 0 hits in both → no option exists → custom, because
#      UTM is a Homebrew cask with no declarative VM surface anywhere in the pins.
#   ✅ TOOL AXIS: nixpkgs ships only `utm` itself (pkgs/by-name/ut/utm — the
#      app, already installed here via the cask), nothing that declares a VM.
#      `ciderale/nixos-utm` owns "NixOS guest in UTM" → not using it, because it
#      targets UTM's APPLE Virtualization backend (no virtio-gpu-gl/virgl, the
#      reason the QEMU backend was chosen in the 2026-10-17 GUI-VM R&D) and its
#      README now redirects to nixos-lima. Retire this when a maintained tool
#      emits QEMU-backend UTM bundles from a NixOS config.
#
# The shared folder is NOT in config.plist — UTM keeps it in its own registry as
# a security-scoped bookmark — so `create` sets it via UTM's AppleScript
# dictionary: `update registry … with {POSIX file …}` (UTM v5.0.8
# Scripting/UTM.sdef, command "update registry", code UTMrUpDt / param UpRg).
# The guest sees it as the VirtFS (9p) mount tag `share`.
{
  lib,
  formats,
  writeShellApplication,
  coreutils,
  qemu-utils,
  nixos-rebuild-ng,
}:
let
  # FIXED identity — generated once with uuidgen / a locally-administered MAC
  # (02: prefix), so a destroy+create keeps the same UTM id, the same DHCP
  # lease and the same mDNS host, and `start`/`stop` never need a lookup.
  vmUuid = "DE70830D-3374-4940-A811-E4377375BC04";
  driveUuid = "DED22E6C-A22E-4255-8F19-DDF01B18CCC9";
  macAddress = "02:6a:67:1d:ef:c4";
  diskName = "nixos.qcow2";
  diskSize = "64G";

  # pkgs.formats.plist → lib.generators.toPlist { escape = true; }
  # (nixpkgs/pkgs/pkgs-lib/formats/plist/default.nix at the root pin). Key set reproduces the
  # hand-made bundle measured to boot under UTM 5.0.8; every key but
  # PS2Controller is a CodingKey in UTM v5.0.8 Configuration/ (that one is
  # ignored by 5.0.8's decoder and kept for newer UTMs).
  configPlist = (formats.plist { }).generate "config.plist" {
    Backend = "QEMU";
    ConfigurationVersion = 4;
    Display = [
      {
        DownscalingFilter = "Linear";
        DynamicResolution = true;
        Hardware = "virtio-gpu-gl-pci";
        # UTM's "Retina Mode". It makes UTM request the window size in PIXELS
        # rather than points and draw at the screen's backing scale (UTM
        # VMDisplayQemuMetalWindowController.swift, updateGuestResolution).
        # Operator-tested 2026-10-17: at the same 1440x900 @ 100% guest
        # settings it looks better than with it off. The guest config sets no
        # scaling-factor (hosts/nixos.nix says why), so this is the one knob.
        NativeResolution = true;
        UpscalingFilter = "Nearest";
      }
    ];
    Drive = [
      {
        Identifier = driveUuid;
        ImageName = diskName;
        ImageType = "Disk";
        Interface = "VirtIO";
        InterfaceVersion = 1;
        ReadOnly = false;
      }
    ];
    Information = {
      Icon = "linux";
      IconCustom = false;
      Name = "nixos";
      UUID = vmUuid;
    };
    Input = {
      MaximumUsbShare = 3;
      UsbBusSupport = "3.0"; # a STRING enum in UTM, not a number
      UsbSharing = true;
    };
    Network = [
      {
        Hardware = "virtio-net-pci";
        IsolateFromHost = false;
        MacAddress = macAddress;
        Mode = "Shared";
        PortForward = [ ];
      }
    ];
    QEMU = {
      AdditionalArguments = [ ];
      BalloonDevice = false;
      DebugLog = false;
      Hypervisor = true;
      PS2Controller = false;
      RNGDevice = true;
      RTCLocalTime = false;
      TPMDevice = false;
      TSO = false;
      UEFIBoot = true;
    };
    Serial = [ ];
    Sharing = {
      ClipboardSharing = true;
      DirectoryShareMode = "VirtFS";
      DirectoryShareReadOnly = false;
    };
    Sound = [ { Hardware = "intel-hda"; } ];
    System = {
      Architecture = "aarch64";
      CPU = "default";
      CPUCount = 8;
      CPUFlagsAdd = [ ];
      CPUFlagsRemove = [ ];
      ForceMulticore = false;
      JITCacheSize = 0;
      MemorySize = 8192;
      Target = "virt";
    };
  };
in
writeShellApplication {
  name = "nixos-vm";
  # qemu-utils, not qemu: only qemu-img is needed, and this package is BUILT by
  # the flake's darwin package set. nixos-rebuild-ng from nixpkgs so `switch`
  # never depends on what the Mac happens to have. macOS binaries go by
  # absolute path below, because Nix shadows BSD tools on PATH; `nix` comes
  # from the user's PATH (Determinate's, with its builder config).
  runtimeInputs = [
    coreutils
    qemu-utils
    nixos-rebuild-ng
  ];
  meta = {
    description = "Create and drive the long-lived nixos UTM guest: nixos-vm create|switch|start|stop|status|ssh|destroy --yes";
    platforms = lib.platforms.darwin;
  };
  text = ''
    set -euo pipefail

    uuid=${lib.escapeShellArg vmUuid}
    host=nixos.local
    utmctl=/Applications/UTM.app/Contents/MacOS/utmctl
    bundle="''${XDG_DATA_HOME:-$HOME/.local/share}/utm/nixos.utm"
    share_dir="$HOME/Shared"
    flake="''${NIXOS_VM_FLAKE:-}"

    die() { echo "nixos-vm: $*" >&2; exit 1; }

    need_utm() {
      [ -x "$utmctl" ] || die "UTM is not installed at /Applications/UTM.app (it is a cask in hosts/macos.nix — activate first)."
    }

    # printf, not a heredoc: Nix strips the indented string's common indent, which
    # would leave an indented EOF terminator that bash never matches.
    usage() {
      printf '%s\n' \
        "usage: nixos-vm <command>" \
        "" \
        "  create [--image FILE.raw] [--flake PATH]" \
        "                One-time. Build (or take) the small SEED image, convert it to" \
        "                qcow2, grow it to ${diskSize}, write the UTM bundle at" \
        "                $bundle, register it, share $share_dir" \
        "                (guest tag: share), boot it, wait for ssh, then run the first" \
        "                'switch' (copies ~6.7 GiB — minutes). Refuses if the bundle exists." \
        "  switch [--flake PATH]" \
        "                nixos-rebuild switch --flake PATH#nixos --target-host $host --sudo." \
        "  start | stop | status" \
        "                utmctl on the VM's fixed UUID ($uuid)." \
        "  restart       Cold restart (stop, wait, start). Use this, NOT Restart inside" \
        "                GNOME: an in-guest reboot hangs on a black screen." \
        "  ssh [ARGS...] ssh $host (guest user = your Mac login name)." \
        "  destroy --yes Stop, unregister from UTM and DELETE the bundle and its disk." \
        "  help          This text." \
        "" \
        "PATH: --flake, else \$NIXOS_VM_FLAKE, else the checkout /etc/nix-darwin/flake.nix" \
        "links to (the main checkout's CURRENT branch, as with 'activate')."
    }

    # Resolve $flake once. Guard the empty case: `dirname ""` is `.`, which
    # would silently make the build CWD-dependent.
    resolve_flake() {
      if [ -z "$flake" ]; then
        local resolved
        resolved=$(readlink -f /etc/nix-darwin/flake.nix 2>/dev/null || true)
        [ -n "$resolved" ] || die "cannot locate the nix-config checkout via /etc/nix-darwin/flake.nix; pass --flake PATH or set NIXOS_VM_FLAKE."
        flake=$(dirname "$resolved")
      fi
      [ -f "$flake/flake.nix" ] || die "no flake.nix in '$flake'."
    }

    # The image derivation's $out holds exactly ONE raw file (nixpkgs
    # image/repart-image.nix moves `''${baseName}*` into $out; its name is
    # config.image.filePath). Glob it rather than baking the name in, and fail
    # loudly if that shape ever changes (e.g. compression → .raw.zst).
    find_raw() {
      local out="$1" raws=()
      shopt -s nullglob
      raws=("$out"/*.raw)
      shopt -u nullglob
      [ "''${#raws[@]}" -eq 1 ] || die "expected exactly one *.raw in $out, found ''${#raws[@]}."
      printf '%s\n' "''${raws[0]}"
    }

    cmd_switch() {
      resolve_flake
      echo "nixos-vm: nixos-rebuild switch --flake $flake#nixos --target-host $host --sudo"
      nixos-rebuild switch --flake "$flake#nixos" --target-host "$host" --sudo
    }

    cmd_create() {
      local image=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --image) image="''${2:?--image needs a path}"; shift 2 ;;
          --flake) flake="''${2:?--flake needs a path}"; shift 2 ;;
          -h | --help) usage; return 0 ;;
          *) die "create: unknown argument '$1'" ;;
        esac
      done
      need_utm
      # Needed even with --image: the first switch builds from it.
      resolve_flake

      # (1) Long-lived VM: never overwrite a disk. `destroy --yes` is the only reset.
      [ ! -e "$bundle" ] || die "$bundle already exists — refusing to overwrite the VM's disk. 'nixos-vm destroy --yes' first to recreate."
      # A stale UTM entry for the fixed UUID (bundle removed by hand) would make
      # the registration wait below succeed instantly, against the wrong VM.
      ! "$utmctl" status "$uuid" >/dev/null 2>&1 || die "$uuid is still registered in UTM without its bundle — 'nixos-vm destroy --yes' first."

      if [ -z "$image" ]; then
        echo "nixos-vm: building the seed image $flake#nixosConfigurations.nixos.config.system.build.image …"
        local outs
        outs=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.nixos.config.system.build.image")
        [[ "$outs" != *$'\n'* ]] || die "image build returned more than one output path:"$'\n'"$outs"
        image=$(find_raw "$outs")
      fi
      [ -f "$image" ] || die "image not found: $image"

      # (2) Assemble beside the target and rename last (same filesystem →
      # atomic), so a failed convert never leaves a half-bundle the guard above
      # would then refuse forever.
      # `tmp` is global, not `local`: the EXIT trap runs after this function
      # returns, when a local would already be unset (fatal under `set -u`).
      local parent
      parent=$(dirname "$bundle")
      mkdir -p "$parent"
      tmp=$(mktemp -d "$parent/.nixos.utm.XXXXXX")
      trap 'rm -rf "$tmp"' EXIT
      mkdir -p "$tmp/Data"
      install -m 644 ${configPlist} "$tmp/config.plist"
      echo "nixos-vm: converting $image → qcow2 …"
      qemu-img convert -p -f raw -O qcow2 "$image" "$tmp/Data/${diskName}"
      qemu-img resize -f qcow2 "$tmp/Data/${diskName}" ${diskSize}
      mv "$tmp" "$bundle"
      trap - EXIT
      echo "nixos-vm: wrote $bundle (config.plist + Data/${diskName}, ${diskSize})"

      # (3a) UTM APP prefs — global, not per-VM, so not in config.plist. Each
      # was measured on 2026-10-17:
      #   QEMUVulkanDriver=1 (Disabled): UTM 5.0.x's own release notes say its
      #     default Vulkan/Venus path breaks Linux desktop rendering; with it off
      #     QEMU gets virtio-gpu-gl without venus=true and GNOME renders on virgl.
      #   QEMUSoundBackend=2 (CoreAudio): output straight to macOS, no SPICE audio.
      #   IsCtrlCmdSwapped=true: Cmd+C/Cmd+V reach the guest as Ctrl+C/Ctrl+V.
      # BEST-EFFORT: after UTM's first launch its sandbox container is
      # TCC-protected and `defaults write` fails without Full Disk Access
      # ("Could not write domain"), so a failure prints the manual fix rather
      # than aborting a create that is otherwise fine.
      if /usr/bin/defaults write com.utmapp.UTM QEMUVulkanDriver -int 1 2>/dev/null &&
        /usr/bin/defaults write com.utmapp.UTM QEMUSoundBackend -int 2 2>/dev/null &&
        /usr/bin/defaults write com.utmapp.UTM IsCtrlCmdSwapped -bool true 2>/dev/null; then
        echo "nixos-vm: UTM prefs set (Vulkan off, CoreAudio, Cmd/Ctrl swapped)"
      else
        echo "nixos-vm: could not write UTM's prefs (its container is TCC-protected)." >&2
        echo "          Set them once in UTM > Settings: Vulkan Driver = Disabled," >&2
        echo "          Sound Backend = CoreAudio, and swap Control and Command." >&2
      fi

      # (3b) Register the bundle IN PLACE, keeping its UUID (measured 2026-10-17).
      mkdir -p "$share_dir"
      /usr/bin/open -a UTM "$bundle"
      local i
      for i in $(seq 1 30); do
        if "$utmctl" status "$uuid" >/dev/null 2>&1; then break; fi
        [ "$i" -lt 30 ] || die "UTM did not register $uuid within 30s — open UTM and check it imported $bundle."
        sleep 1
      done
      echo "nixos-vm: registered with UTM as $uuid"
      # argv, not string interpolation, so a path with quotes cannot break the script.
      /usr/bin/osascript \
        -e 'on run argv' \
        -e 'tell application "UTM" to update registry of virtual machine id (item 1 of argv) with {POSIX file (item 2 of argv)}' \
        -e 'end run' \
        "$uuid" "$share_dir" >/dev/null
      echo "nixos-vm: shared $share_dir (guest mount tag: share)"

      # (4) Boot the seed.
      "$utmctl" start "$uuid"
      echo "nixos-vm: started $uuid"

      # (5) Wait for sshd. A re-created VM has a NEW host key under the SAME
      # name, so the old known_hosts entry would make accept-new refuse it
      # forever — drop it first (this VM was created seconds ago, there is
      # nothing to trust in the old key).
      /usr/bin/ssh-keygen -R "$host" >/dev/null 2>&1 || true
      printf 'nixos-vm: waiting for ssh on %s ' "$host"
      local deadline=$((SECONDS + 300))
      until /usr/bin/ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$host" true 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo
          die "no ssh on $host after 5 min. The VM is created and running — check its console in UTM (mDNS name, network, sshd), then 'nixos-vm switch'."
        fi
        printf '.'
        sleep 5
      done
      echo " up"

      # (6) The desktop arrives here.
      echo "nixos-vm: first switch — copies ~6.7 GiB to the guest; this takes minutes."
      cmd_switch
      echo "nixos-vm: done."
    }

    cmd_destroy() {
      [ "''${1:-}" = "--yes" ] || die "destroy deletes the VM and its disk for good — rerun as 'nixos-vm destroy --yes'."
      need_utm
      if "$utmctl" status "$uuid" >/dev/null 2>&1; then
        # --kill, not the default power-off: the disk is about to be deleted,
        # and `delete` refuses a VM that is still stopping. States per UTM
        # v5.0.8 utmctl/UTMCtl.swift `asString`.
        if [ "$("$utmctl" status "$uuid")" != "stopped" ]; then
          "$utmctl" stop --kill "$uuid"
          local i
          for i in $(seq 1 30); do
            [ "$("$utmctl" status "$uuid")" = "stopped" ] && break
            [ "$i" -lt 30 ] || die "$uuid did not reach 'stopped' within 30s."
            sleep 1
          done
        fi
        "$utmctl" delete "$uuid"
        echo "nixos-vm: deleted $uuid from UTM"
      else
        echo "nixos-vm: $uuid is not registered with UTM"
      fi
      if [ -e "$bundle" ]; then
        rm -rf "$bundle"
        echo "nixos-vm: removed $bundle"
      fi
    }

    sub="''${1:-help}"
    [ $# -eq 0 ] || shift
    case "$sub" in
      create) cmd_create "$@" ;;
      switch)
        while [ $# -gt 0 ]; do
          case "$1" in
            --flake) flake="''${2:?--flake needs a path}"; shift 2 ;;
            *) die "switch: unknown argument '$1'" ;;
          esac
        done
        cmd_switch
        ;;
      start | stop | status)
        need_utm
        exec "$utmctl" "$sub" "$uuid" "$@"
        ;;
      # A COLD restart. Rebooting from INSIDE the guest hung on a black screen
      # with the guest off the network (measured 2026-10-17), while stop +
      # start came up cleanly; the suspected cause is QEMU's virtio-gpu-gl
      # reset path destroying the renderer (the same reset behind QEMU issue
      # 1860's black screen after guest S3). So restart = stop, wait, start.
      restart)
        need_utm
        "$utmctl" stop "$uuid"
        for _ in $(seq 1 30); do
          [ "$("$utmctl" status "$uuid")" = "stopped" ] && break
          sleep 2
        done
        [ "$("$utmctl" status "$uuid")" = "stopped" ] || die "did not stop within 60s — 'nixos-vm stop' again, or quit it from UTM."
        exec "$utmctl" start "$uuid"
        ;;
      ssh) exec /usr/bin/ssh "$host" "$@" ;;
      destroy) cmd_destroy "$@" ;;
      help | -h | --help) usage ;;
      *) usage >&2; exit 1 ;;
    esac
  '';
}
