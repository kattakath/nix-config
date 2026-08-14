# browservm vfkit control-plane (host Mac only).
#
# Hypervisor: Apple Virtualization.framework, via microvm.nix's `vfkit` backend
# (crc-org/vfkit, wraps Apple's framework directly — no nested virtualization,
# same tier as Tart's macvm and Determinate's native Linux builder).
# Guest OS: nixosConfigurations.browservm — a headless-Chromium automation VM.
# UNLIKE macvm (persistent Tart disk under ~/.tart/), browservm has NO persistent
# disk at all: `start` builds+boots the guest fresh from the Nix store every
# time (microvm.nix's declaredRunner), so there is no create/ensure step — start
# IS create-and-run, and stop leaves nothing behind but Nix store paths.
# See docs/browservm-runbook.md.
{
  writeShellApplication,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  browservmRunner,
  loginName,
}:
let
  vmName = "browservm";
  runnerBin = "${browservmRunner}/bin/microvm-run";

  preamble = ''
    set -euo pipefail
    VM_NAME="${vmName}"
    RUNNER="${runnerBin}"
    SSH_USER="''${BROWSERVM_SSH_USER:-${loginName}}"
    IDENTITY="''${BROWSERVM_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
    LOG_DIR="''${BROWSERVM_LOG_DIR:-$HOME/Library/Logs}"
    RUN_LOG="$LOG_DIR/browservm-vfkit-run.log"
    PID_FILE="$LOG_DIR/browservm-vfkit-run.pid"
    LEASES="/var/db/dhcpd_leases"

    die() { echo "browservm-vfkit: $*" >&2; exit 1; }
    info() { echo "browservm-vfkit: $*" >&2; }

    vm_running() {
      [ -f "$PID_FILE" ] || return 1
      local pid
      pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
    }

    # Discover the guest's IP from macOS's vmnet shared-subnet DHCP leases —
    # the same mechanism/subnet (192.168.64.0/24) Tart's macvm already uses.
    # No port-forwarding, no vsock: host and guest are direct peers (verified
    # empirically — 0% ICMP loss to a vfkit guest on this exact subnet).
    guest_ip() {
      [ -r "$LEASES" ] || return 1
      /usr/bin/awk -v n="$VM_NAME" '
        $0 ~ "name=" n "$" { grab=1 }
        grab && /ip_address=/ { sub(/^[ \t]*ip_address=/, ""); print; exit }
        /^}/ { grab=0 }
      ' "$LEASES"
    }

    wait_for_ip() {
      local wait="''${1:-120}" i=0 ip
      while [ "$i" -lt "$wait" ]; do
        ip=$(guest_ip || true)
        [ -n "''${ip:-}" ] && { printf '%s\n' "$ip"; return 0; }
        sleep 1
        i=$((i + 1))
      done
      return 1
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

  start = mkApp {
    name = "browservm-vfkit-start";
    text = ''
      if vm_running; then
        info "already running"
        ip=$(guest_ip || true)
        echo "ip=''${ip:-pending}"
        exit 0
      fi
      /bin/mkdir -p "$LOG_DIR"
      info "booting $VM_NAME fresh from the Nix store — log: $RUN_LOG"
      # vfkit's stdio console needs a real TTY (fails "operation not supported by
      # device" otherwise — observed live) — /usr/bin/script allocates a pty so
      # this works the same whether run interactively or from a pipeline/CI.
      nohup /usr/bin/script -q /dev/null "$RUNNER" >>"$RUN_LOG" 2>&1 &
      echo $! >"$PID_FILE"
      info "waiting for a DHCP lease (up to 120s)…"
      if ip=$(wait_for_ip 120); then
        echo "ip=$ip"
        info "next: nix run .#browservm-vfkit-ssh"
      else
        info "no IP yet — check $RUN_LOG; later: nix run .#browservm-vfkit-ip"
      fi
    '';
  };

  stop = mkApp {
    name = "browservm-vfkit-stop";
    text = ''
      if ! vm_running; then
        info "not running"
        exit 0
      fi
      pid=$(cat "$PID_FILE")
      info "stopping $VM_NAME (pid $pid)"
      # $pid is the `script` pty wrapper, not vfkit itself — kill its whole
      # process group first (script's child can otherwise survive, orphaned),
      # falling back to a direct kill and a path-matched pkill as a last resort.
      kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      /usr/bin/pkill -f "$RUNNER" 2>/dev/null || true
      rm -f "$PID_FILE"
    '';
  };

  ipApp = mkApp {
    name = "browservm-vfkit-ip";
    text = ''
      vm_running || die "not running — nix run .#browservm-vfkit-start"
      wait="''${1:-30}"
      ip=$(wait_for_ip "$wait") || die "no IP yet (is the guest still booting?)"
      printf '%s\n' "$ip"
    '';
  };

  sshApp = mkApp {
    name = "browservm-vfkit-ssh";
    text = ''
      # usage: browservm-vfkit-ssh [--user USER] [--wait SECS] [-- ssh-args…]
      wait="''${BROWSERVM_IP_WAIT:-60}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --user) SSH_USER="''${2:?}"; shift 2 ;;
          --wait) wait="''${2:?}"; shift 2 ;;
          -h|--help)
            echo "usage: browservm-vfkit-ssh [--user USER] [--wait SECS] [-- ssh-args…]"
            echo "  SSH via the vmnet shared-subnet IP (default user \$loginName, operator key)."
            echo "  Pass -X yourself for X11 forwarding (needs XQuartz running as the host display)."
            exit 0
            ;;
          --) shift; break ;;
          *) break ;;
        esac
      done

      vm_running || die "not running — nix run .#browservm-vfkit-start"
      ip=$(wait_for_ip "$wait") || die "no IP yet (is the guest still booting?)"

      info "ssh $SSH_USER@$ip"
      exec /usr/bin/ssh \
        -o "IdentityFile=$IDENTITY" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" \
        "$SSH_USER@$ip" "$@"
    '';
  };

  status = mkApp {
    name = "browservm-vfkit-status";
    text = ''
      echo "=== browservm-vfkit status ==="
      if vm_running; then
        echo "state: running (pid $(cat "$PID_FILE"))"
        ip=$(guest_ip || true)
        echo "ip: ''${ip:-no DHCP lease yet}"
      else
        echo "state: stopped"
      fi
      echo "backend: microvm.nix (vfkit) -> Apple Virtualization.framework"
      echo "ssh user: ''${BROWSERVM_SSH_USER:-${loginName}}"
    '';
  };
in
{
  browservm-vfkit-start = start;
  browservm-vfkit-stop = stop;
  browservm-vfkit-ip = ipApp;
  browservm-vfkit-ssh = sshApp;
  browservm-vfkit-status = status;
}
