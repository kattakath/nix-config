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
    RUNNER_STORE_PATH="${browservmRunner}"
    SSH_USER="''${BROWSERVM_SSH_USER:-${loginName}}"
    IDENTITY="''${BROWSERVM_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
    LOG_DIR="''${BROWSERVM_LOG_DIR:-$HOME/Library/Logs}"
    RUN_LOG="$LOG_DIR/browservm-vfkit-run.log"
    PID_FILE="$LOG_DIR/browservm-vfkit-run.pid"
    LEASES="/var/db/dhcpd_leases"
    # Fixed state dir: the vfkit socket + GC root live here, independent of
    # whatever directory the caller happened to invoke us from (a CWD-relative
    # socket path was observed scattering across the filesystem — see
    # docs/browservm-runbook.md).
    STATE_DIR="''${BROWSERVM_STATE_DIR:-$HOME/Library/Application Support/browservm}"
    SOCK_NAME="$VM_NAME.sock"
    SOCK_PATH="$STATE_DIR/$SOCK_NAME"
    TUNNEL_PID_FILE="$LOG_DIR/browservm-vfkit-tunnel.pid"
    CDP_PORT="''${CHROME_AUTOMATION_PORT:-9222}"

    die() { echo "browservm-vfkit: $*" >&2; exit 1; }
    info() { echo "browservm-vfkit: $*" >&2; }

    vm_running() {
      if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null) || true
        if [ -n "''${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
          return 0
        fi
      fi
      # PID file can go stale (lost across shell restarts, or the tracked pid
      # is `script`'s pty wrapper, which can exit once vfkit is fully up)
      # while vfkit is still up. Two fallbacks, since `microvm-run` typically
      # `exec`s into vfkit — replacing its own argv, so the runner store path
      # no longer appears in the live process's command line at all (verified
      # live: a real orphaned vfkit process was found this way, invisible to a
      # $RUNNER-only pgrep match). Match on vfkit's socket FILENAME (not the
      # full path — a pre-fix or otherwise differently-invoked process may
      # have landed its socket somewhere other than $STATE_DIR) — distinctive
      # enough on its own that nothing else on this Mac would have it in its
      # command line, and present in vfkit's argv for its whole lifetime.
      /usr/bin/pgrep -f "$RUNNER" >/dev/null 2>&1 || /usr/bin/pgrep -f "$SOCK_NAME" >/dev/null 2>&1
    }

    tunnel_running() {
      [ -f "$TUNNEL_PID_FILE" ] || return 1
      local pid
      pid=$(cat "$TUNNEL_PID_FILE" 2>/dev/null) || return 1
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
    }

    stop_tunnel() {
      tunnel_running || { rm -f "$TUNNEL_PID_FILE"; return 0; }
      local pid
      pid=$(cat "$TUNNEL_PID_FILE")
      info "closing CDP tunnel (pid $pid)"
      kill "$pid" 2>/dev/null || true
      rm -f "$TUNNEL_PID_FILE"
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

    # browservm has no persistent disk, so it has no persistent SSH host key
    # either — every boot generates a fresh one, at the same stable vmnet IP.
    # `StrictHostKeyChecking=accept-new` only covers a host not yet known; a
    # CHANGED key at a known IP still hard-fails (verified live: this broke
    # every connection, including the CDP tunnel, on the second boot in a
    # row). Always drop any prior entry for this IP before connecting — an
    # unconditional, idempotent no-op when there's nothing to drop.
    forget_stale_hostkey() {
      /usr/bin/ssh-keygen -R "$1" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 || true
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
      /bin/mkdir -p "$LOG_DIR" "$STATE_DIR/gcroots"
      # Root the runner closure so a routine `nix store gc` doesn't evict this
      # multi-GB guest closure and force a slow rebuild on the next start —
      # best-effort, never fatal to boot.
      nix-store --add-root "$STATE_DIR/gcroots/runner" --indirect -r "$RUNNER_STORE_PATH" >/dev/null 2>&1 || true
      info "booting $VM_NAME fresh from the Nix store — log: $RUN_LOG"
      # vfkit's stdio console needs a real TTY (fails "operation not supported by
      # device" otherwise — observed live) — /usr/bin/script allocates a pty so
      # this works the same whether run interactively or from a pipeline/CI.
      # Run from STATE_DIR so the vfkit socket (CWD-relative) lands in a fixed,
      # predictable place regardless of the caller's own working directory.
      (
        cd "$STATE_DIR"
        nohup /usr/bin/script -q /dev/null "$RUNNER" >>"$RUN_LOG" 2>&1 &
        echo $! >"$PID_FILE"
      )
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
      stop_tunnel
      if ! vm_running; then
        info "not running"
        exit 0
      fi
      pid=$(cat "$PID_FILE" 2>/dev/null || true)
      info "stopping $VM_NAME''${pid:+ (pid $pid)}"
      # $pid (when the PID file is intact) is the `script` pty wrapper, not
      # vfkit itself — kill its whole process group first (script's child can
      # otherwise survive, orphaned), falling back to a direct kill and a
      # path-matched pkill as a last resort (also the path taken when the PID
      # file was stale/missing, since vm_running's own fallback got us here).
      [ -n "''${pid:-}" ] && { kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; }
      /usr/bin/pkill -f "$RUNNER" 2>/dev/null || true
      # Also match on the socket filename: microvm-run typically execs into
      # vfkit, replacing its own argv, so an orphaned vfkit process
      # (script/microvm-run already gone) won't match $RUNNER at all — same
      # gap vm_running()'s fallback covers, including sockets left over from
      # before $STATE_DIR was pinned.
      /usr/bin/pkill -f "$SOCK_NAME" 2>/dev/null || true
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
      forget_stale_hostkey "$ip"

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
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "''${pid:-}" ]; then
          echo "state: running (pid $pid)"
        else
          echo "state: running (pid file stale/missing — matched by process name)"
        fi
        ip=$(guest_ip || true)
        echo "ip: ''${ip:-no DHCP lease yet}"
      else
        echo "state: stopped"
      fi
      if tunnel_running; then
        echo "cdp tunnel: up (pid $(cat "$TUNNEL_PID_FILE"), 127.0.0.1:$CDP_PORT)"
      else
        echo "cdp tunnel: down"
      fi
      echo "backend: microvm.nix (vfkit) -> Apple Virtualization.framework"
      echo "ssh user: ''${BROWSERVM_SSH_USER:-${loginName}}"
    '';
  };

  up = mkApp {
    name = "browservm-vfkit-up";
    text = ''
      # One-shot deterministic bootstrap for browser automation: boot the VM
      # if needed, wait for its IP, open (or reuse) the CDP tunnel, and block
      # until Chromium's browser-cdp.service actually answers — so an agent
      # (or `automation-session`) has exactly one command to run instead of
      # reconstructing the start/wait/tunnel sequence by hand.
      "${start}/bin/browservm-vfkit-start" >&2

      ip=$(wait_for_ip 60) || die "no IP yet (is the guest still booting? check $RUN_LOG)"
      forget_stale_hostkey "$ip"

      if tunnel_running; then
        info "CDP tunnel already open (pid $(cat "$TUNNEL_PID_FILE"))"
      else
        info "opening CDP tunnel -> 127.0.0.1:$CDP_PORT"
        # nohup'd: a plain backgrounded ssh gets SIGHUP'd (and dies) if this
        # script's own shell exits non-zero later — observed live — which
        # would silently orphan a half-open tunnel instead of leaving a
        # working one behind.
        nohup /usr/bin/ssh \
          -o "IdentityFile=$IDENTITY" \
          -o IdentitiesOnly=yes \
          -o StrictHostKeyChecking=accept-new \
          -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" \
          -N -L "$CDP_PORT:127.0.0.1:$CDP_PORT" \
          "$SSH_USER@$ip" >>"$RUN_LOG" 2>&1 &
        echo $! >"$TUNNEL_PID_FILE"
      fi

      info "waiting for Chromium's CDP endpoint on 127.0.0.1:''${CDP_PORT}…"
      i=0
      until /usr/bin/curl -fsS "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 30 ]; then
          die "CDP never answered on 127.0.0.1:$CDP_PORT — check the guest: nix run .#browservm-vfkit-ssh -- systemctl status browser-cdp"
        fi
        sleep 1
      done
      info "ready — automation-session status / seed, or the playwright MCP, can drive it now."
    '';
  };
in
{
  browservm-vfkit-start = start;
  browservm-vfkit-stop = stop;
  browservm-vfkit-ip = ipApp;
  browservm-vfkit-ssh = sshApp;
  browservm-vfkit-status = status;
  browservm-vfkit-up = up;
}
