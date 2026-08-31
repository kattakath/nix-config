# macvm Tart control-plane (host Mac only).
#
# Hypervisor: Apple Virtualization.framework.
# Front-end: Tart (CLI) — create from Apple IPSW.
# Guest OS: darwinConfigurations.macvm — activate inside the VM as ismail.
# Disks/IPSWs never enter the Nix store (~/.tart/vms/<name>).
# See docs/macvm-tart-runbook.md.
{
  lib,
  writeShellApplication,
  writeText,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  tart,
}:
let
  vmName = "macvm";
  # nixpkgs wraps tart.app (provisioning profile) via bin/tart.
  tartBin = lib.getExe tart;

  bootstrapText = writeText "macvm-tart-bootstrap.txt" ''
    macvm guest bootstrap (run INSIDE the Tart VM)

    1. Login account: ismail  (must match flake identity)
    2. Enable Remote Login (SSH) in System Settings if not already on
    3. Determinate Nix if missing: https://docs.determinate.systems
    4. First activation (app handles sudo + root HOME — do not bare sudo darwin-rebuild):
         nix run github:kattakath/nix-config#macvm
    5. Thereafter (from host):
         nix run .#macvm-tart-ssh -- nix run --refresh github:kattakath/nix-config#macvm

    Host-side:
         nix run .#macvm-tart-doctor | start | stop | ssh | create

    Disks live under ~/.tart/ — NOT in the flake. See docs/macvm-tart-runbook.md
  '';

  createHelp = writeText "macvm-tart-create-help.txt" ''
    Create macvm via Tart (Apple Virtualization + IPSW)

      nix run .#macvm-tart-create
      nix run .#macvm-tart-create -- --ipsw=/path/to/UniversalMac_….ipsw
      nix run .#macvm-tart-create -- --ipsw=latest   # default: Apple CDN latest

    Then: tart opens a window — complete Setup Assistant as user ismail.
    Optional (prebuilt image instead of IPSW install):
      tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest macvm
      # then create an ismail user (or re-login) matching the flake identity

    NEVER put IPSW or disk images into the Nix store or this git repo.
  '';

  preamble = ''
    set -euo pipefail
    VM_NAME="${vmName}"
    TART="${tartBin}"
    DOWNLOADS="''${MACVM_HOST_DOWNLOADS:-$HOME/Downloads}"
    LOG_DIR="''${MACVM_TART_LOG_DIR:-$HOME/Library/Logs}"
    RUN_LOG="$LOG_DIR/macvm-tart-run.log"

    die() { echo "macvm-tart: $*" >&2; exit 1; }
    info() { echo "macvm-tart: $*" >&2; }

    require_tart() {
      if [ ! -x "$TART" ]; then
        die "tart not found at $TART — rebuild host packages / check unfree tart"
      fi
    }

    vm_exists() {
      require_tart
      # --quiet: one name per line (no header/columns).
      "$TART" list --quiet 2>/dev/null | grep -qx "$VM_NAME"
    }

    # Prefer tart list/get state — tart ip can still resolve after stop (stale DHCP).
    vm_running() {
      require_tart
      "$TART" list 2>/dev/null | /usr/bin/awk -v n="$VM_NAME" '
        NR>1 && $2==n {
          st=tolower($NF)
          exit (st=="running" || st=="suspended") ? 0 : 1
        }
        END { if (NR==0) exit 1 }
      '
    }

    guest_ip() {
      require_tart
      local wait="''${1:-0}"
      "$TART" ip "$VM_NAME" --wait "$wait" 2>/dev/null || true
    }

    dir_share_args() {
      # Guest mount: /Volumes/My Shared Files/Downloads (VirtioFS automount).
      # The guest symlinks its own ~/Downloads to it (hosts/macvm.nix), so both
      # machines share ONE download/screencapture inbox, rotated only on the host.
      /bin/mkdir -p "$DOWNLOADS"
      printf '%s' "--dir=Downloads:$DOWNLOADS"
    }
  '';

  baseInputs = [
    coreutils
    findutils
    gnugrep
    gnused
  ];

  mkApp =
    {
      name,
      text,
      runtimeInputs ? baseInputs,
      excludeShellChecks ? [
        "SC2034"
        "SC2329"
      ],
    }:
    writeShellApplication {
      inherit name runtimeInputs excludeShellChecks;
      text = preamble + "\n" + text;
    };

  doctor = mkApp {
    name = "macvm-tart-doctor";
    text = ''
      rc=0
      echo "=== macvm-tart doctor ==="
      if [ -x "$TART" ]; then
        echo "tart: ok ($TART)"
        "$TART" --version 2>/dev/null || true
      else
        echo "tart: MISSING"
        rc=1
      fi

      if vm_exists; then
        echo "vm: present ($VM_NAME)"
        "$TART" list 2>/dev/null | /usr/bin/awk -v n="$VM_NAME" 'NR==1 || $2==n {print}'
        if vm_running; then
          echo "state: running"
          ip=$(guest_ip 0 || true)
          echo "ip: ''${ip:-unknown}"
        else
          echo "state: stopped (or no DHCP lease yet)"
        fi
      else
        echo "vm: ABSENT — nix run .#macvm-tart-create"
        rc=1
      fi

      echo "downloads host path: $DOWNLOADS ($( [ -d "$DOWNLOADS" ] && echo present || echo MISSING ))"
      echo "guest mount (when running with start): /Volumes/My Shared Files/Downloads"
      echo "guest persona: ismail (activate #macvm inside the VM)"
      echo "backend: Tart → Apple Virtualization.framework"
      exit "$rc"
    '';
  };

  list = mkApp {
    name = "macvm-tart-list";
    text = ''
      require_tart
      exec "$TART" list "$@"
    '';
  };

  create = mkApp {
    name = "macvm-tart-create";
    text = ''
      require_tart
      ipsw="latest"
      disk_gb="''${MACVM_TART_DISK_GB:-80}"
      cpus="''${MACVM_TART_CPUS:-4}"
      memory_mb="''${MACVM_TART_MEMORY_MB:-8192}"
      force=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --ipsw) ipsw="''${2:?}"; shift 2 ;;
          --disk-gb) disk_gb="''${2:?}"; shift 2 ;;
          --cpus) cpus="''${2:?}"; shift 2 ;;
          --memory-mb) memory_mb="''${2:?}"; shift 2 ;;
          --force) force=1; shift ;;
          -h|--help)
            cat ${createHelp}
            exit 0
            ;;
          *) die "unknown arg: $1 (try --help)" ;;
        esac
      done

      if vm_exists; then
        if [ "$force" -eq 0 ]; then
          die "VM '$VM_NAME' already exists (tart list). Use --force to delete+recreate, or tart rename."
        fi
        info "deleting existing $VM_NAME (--force)"
        "$TART" stop "$VM_NAME" 2>/dev/null || true
        "$TART" delete "$VM_NAME"
      fi

      info "creating $VM_NAME from IPSW=$ipsw disk=''${disk_gb}G (disk stays under ~/.tart — not the store)"
      "$TART" create --from-ipsw="$ipsw" --disk-size "$disk_gb" "$VM_NAME"
      "$TART" set "$VM_NAME" --cpu "$cpus" --memory "$memory_mb"
      info "created. Next:"
      echo "  1. nix run .#macvm-tart-start     # opens Tart UI; finish Setup as ismail"
      echo "  2. Enable Remote Login (SSH) in the guest if needed"
      echo "  3. In guest: nix run github:kattakath/nix-config#macvm"
      echo "  4. nix run .#macvm-tart-ssh -- uname -a"
      cat ${bootstrapText}
    '';
  };

  ensure = mkApp {
    name = "macvm-tart-ensure";
    text = ''
      # Exit 0: VM exists. Exit 2: missing (print create help).
      if vm_exists; then
        info "macvm present — ok"
        "$TART" list 2>/dev/null | /usr/bin/awk -v n="$VM_NAME" 'NR==1 || $2==n {print}'
        exit 0
      fi
      info "macvm missing — create from IPSW with Tart"
      cat ${createHelp}
      exit 2
    '';
  };

  start = mkApp {
    name = "macvm-tart-start";
    text = ''
      require_tart
      vm_exists || die "no VM '$VM_NAME' — nix run .#macvm-tart-create"
      if vm_running; then
        info "already running"
        ip=$(guest_ip 5 || true)
        echo "ip=''${ip:-pending}"
        exit 0
      fi
      /bin/mkdir -p "$LOG_DIR" "$DOWNLOADS"
      share=$(dir_share_args)
      info "starting $VM_NAME ($share) — log: $RUN_LOG"
      # tart run is long-lived (GUI); detach so the flake app can return.
      # shellcheck disable=SC2086
      nohup "$TART" run $share "$VM_NAME" >>"$RUN_LOG" 2>&1 &
      echo $! >"$LOG_DIR/macvm-tart-run.pid"
      info "waiting for DHCP IP (up to 180s)…"
      ip=$(guest_ip 180 || true)
      if [ -n "''${ip:-}" ]; then
        echo "ip=$ip"
      else
        info "IP not ready yet — check Tart window / $RUN_LOG; later: nix run .#macvm-tart-ip"
      fi
    '';
  };

  stop = mkApp {
    name = "macvm-tart-stop";
    text = ''
      require_tart
      vm_exists || die "no VM '$VM_NAME'"
      info "stopping $VM_NAME"
      "$TART" stop "$VM_NAME" "$@" || true
    '';
  };

  ipApp = mkApp {
    name = "macvm-tart-ip";
    text = ''
      require_tart
      vm_exists || die "no VM '$VM_NAME'"
      wait="''${1:-30}"
      ip=$(guest_ip "$wait")
      [ -n "''${ip:-}" ] || die "no IP yet (is the VM running?)"
      printf '%s\n' "$ip"
    '';
  };

  sshApp = mkApp {
    name = "macvm-tart-ssh";
    text = ''
      # usage: macvm-tart-ssh [--user USER] [ssh-args…]
      user=ismail
      identity="''${MACVM_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
      wait="''${MACVM_TART_IP_WAIT:-60}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --user) user="''${2:?}"; shift 2 ;;
          --wait) wait="''${2:?}"; shift 2 ;;
          -h|--help)
            echo "usage: macvm-tart-ssh [--user USER] [--wait SECS] [ssh-args…]"
            echo "  SSH via tart ip (default user ismail, operator key)."
            exit 0
            ;;
          --) shift; break ;;
          *) break ;;
        esac
      done

      require_tart
      vm_exists || die "no VM '$VM_NAME' — create + start first"
      vm_running || die "VM not running — nix run .#macvm-tart-start"
      ip=$(guest_ip "$wait")
      [ -n "''${ip:-}" ] || die "no IP from tart ip (guest Remote Login on?)"

      info "ssh $user@$ip"
      exec /usr/bin/ssh \
        -o "IdentityFile=$identity" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" \
        "$user@$ip" "$@"
    '';
  };

  bootstrap-print = mkApp {
    name = "macvm-tart-bootstrap-print";
    text = ''
      exec cat ${bootstrapText}
    '';
  };

in
{
  macvm-tart-doctor = doctor;
  macvm-tart-list = list;
  macvm-tart-create = create;
  macvm-tart-ensure = ensure;
  macvm-tart-start = start;
  macvm-tart-stop = stop;
  macvm-tart-ip = ipApp;
  macvm-tart-ssh = sshApp;
  macvm-tart-bootstrap-print = bootstrap-print;
}
