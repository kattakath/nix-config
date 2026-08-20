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
    # mkdir-based lock: portable, no extra dependency, and atomic — mkdir on
    # an existing dir always fails, which is exactly the mutual-exclusion
    # primitive needed to close the TOCTOU race in "check if running, then
    # spawn" (two concurrent callers can otherwise both see "not running" and
    # both spawn a vfkit process against the same socket — the second spawn
    # can silently steal the first one's socket, orphaning it invisibly).
    LOCK_DIR="$STATE_DIR/lock"

    die() { echo "browservm-vfkit: $*" >&2; exit 1; }
    info() { echo "browservm-vfkit: $*" >&2; }

    acquire_lock() {
      local timeout="''${1:-30}" i=0 holder
      /bin/mkdir -p "$STATE_DIR"
      while true; do
        if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
          echo $$ >"$LOCK_DIR/pid"
          return 0
        fi
        # Someone holds it — if they're dead (crashed mid-lock, e.g. kill -9),
        # the lock is stale: break it. `rm -rf`, not `rmdir` — the lock dir
        # is never empty (it holds the pid file), and `rmdir` on a non-empty
        # dir fails silently under `|| true`, which (found live, this exact
        # bug) leaves the "stale" lock permanently stuck: every subsequent
        # attempt re-detects the same staleness and re-fails to clear it,
        # turning this into a tight infinite loop instead of a fix. Always
        # increment/sleep afterward too (no `continue`-without-counting) so
        # this stays bounded by $timeout no matter what.
        holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "''${holder:-}" ] && ! kill -0 "$holder" 2>/dev/null; then
          info "breaking stale lock (held by dead pid $holder)"
          rm -rf "$LOCK_DIR" 2>/dev/null || true
        fi
        i=$((i + 1))
        [ "$i" -ge "$timeout" ] && die "timed out waiting for the browservm lock ($LOCK_DIR, held by pid ''${holder:-unknown}) — if stuck, rm -rf it manually"
        sleep 1
      done
    }

    release_lock() {
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    }

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
      local pid waited=0
      pid=$(cat "$TUNNEL_PID_FILE")
      info "closing CDP tunnel (pid $pid)"
      kill "$pid" 2>/dev/null || true
      rm -f "$TUNNEL_PID_FILE"
      # Confirm it's actually gone (ssh under -N should die fast, but
      # confirm rather than assume — same reasoning as the VM's own stop).
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
        sleep 1
        waited=$((waited + 1))
      done
      # `if`-wrapped, not a bare `CMD && CMD` — this is the LAST statement in
      # the function, so its own exit status becomes stop_tunnel's return
      # value. The common/good outcome (process already confirmed dead, `kill
      # -0` fails) would otherwise make stop_tunnel return nonzero, which —
      # found live, 100% reproducible under 5-way parallel `stop` — silently
      # trips `set -e` in do_stop (stop_tunnel is called bare there), aborting
      # the rest of the teardown. `if` is unconditionally safe here regardless
      # of which branch is taken.
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
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
      # Decision + spawn is the critical section: lock it so two concurrent
      # `start`/`up` calls can't both observe "not running" and both spawn.
      # The lock is held only for this brief window, NOT the DHCP wait below
      # — once the real spawn has happened and $PID_FILE is written, any
      # other caller queued on the lock sees vm_running()==true immediately
      # and returns without waiting on (or duplicating) the boot.
      ALREADY_RUNNING=0
      boot_if_needed() {
        acquire_lock 30
        trap release_lock RETURN
        if vm_running; then
          ALREADY_RUNNING=1
          return 0
        fi
        /bin/mkdir -p "$LOG_DIR" "$STATE_DIR/gcroots"
        # Root the runner closure so a routine `nix store gc` doesn't evict
        # this multi-GB guest closure and force a slow rebuild on the next
        # start — best-effort, never fatal to boot.
        nix-store --add-root "$STATE_DIR/gcroots/runner" --indirect -r "$RUNNER_STORE_PATH" >/dev/null 2>&1 || true
        info "booting $VM_NAME fresh from the Nix store — log: $RUN_LOG"
        # vfkit's stdio console needs a real TTY (fails "operation not
        # supported by device" otherwise — observed live) — /usr/bin/script
        # allocates a pty so this works the same whether run interactively or
        # from a pipeline/CI. Run from STATE_DIR so the vfkit socket
        # (CWD-relative) lands in a fixed, predictable place regardless of
        # the caller's own working directory.
        (
          cd "$STATE_DIR"
          nohup /usr/bin/script -q /dev/null "$RUNNER" >>"$RUN_LOG" 2>&1 &
          echo $! >"$PID_FILE"
        )
      }
      boot_if_needed

      if [ "$ALREADY_RUNNING" = "1" ]; then
        info "already running"
        ip=$(guest_ip || true)
        echo "ip=''${ip:-pending}"
        exit 0
      fi
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
      # Same lock as `start`'s spawn decision — prevents a `start` and `stop`
      # firing at the same moment from interleaving into a half-killed state
      # (e.g. stop killing a pid right as start is about to overwrite it).
      do_stop() {
        acquire_lock 30
        trap release_lock RETURN
        stop_tunnel
        if ! vm_running; then
          info "not running"
          return 0
        fi
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        info "stopping $VM_NAME''${pid:+ (pid $pid)}"
        # $pid (when the PID file is intact) is the `script` pty wrapper, not
        # vfkit itself — kill its whole process group first (script's child
        # can otherwise survive, orphaned), falling back to a direct kill and
        # a path-matched pkill as a last resort (also the path taken when the
        # PID file was stale/missing, since vm_running's own fallback got us
        # here).
        if [ -n "''${pid:-}" ]; then
          kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
        /usr/bin/pkill -f "$RUNNER" 2>/dev/null || true
        # Also match on the socket filename: microvm-run typically execs into
        # vfkit, replacing its own argv, so an orphaned vfkit process
        # (script/microvm-run already gone) won't match $RUNNER at all — same
        # gap vm_running()'s fallback covers, including sockets left over
        # from before $STATE_DIR was pinned.
        /usr/bin/pkill -f "$SOCK_NAME" 2>/dev/null || true
        rm -f "$PID_FILE"
        # Confirm it's actually gone rather than fire-and-forget — vfkit can
        # take a few seconds to exit after SIGTERM (observed live: up to
        # ~3s). Escalate to SIGKILL if it's still around past a short grace
        # period, so `stop` returning really means stopped, not just "a
        # signal was sent" — the whole point of this command for "no orphan
        # VMs left behind."
        local waited=0
        while vm_running && [ "$waited" -lt 10 ]; do
          sleep 1
          waited=$((waited + 1))
        done
        if vm_running; then
          info "still alive after ''${waited}s — sending SIGKILL"
          /usr/bin/pkill -9 -f "$SOCK_NAME" 2>/dev/null || true
          sleep 1
        fi
      }
      do_stop
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

      # Same TOCTOU shape as start's spawn decision, on the tunnel instead of
      # the VM — lock it so two concurrent `up` calls can't both decide the
      # tunnel is down and both open one.
      open_tunnel_if_needed() {
        acquire_lock 30
        trap release_lock RETURN
        if tunnel_running; then
          info "CDP tunnel already open (pid $(cat "$TUNNEL_PID_FILE"))"
          return 0
        fi
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
      }
      open_tunnel_if_needed

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

  doctor = mkApp {
    name = "browservm-vfkit-doctor";
    text = ''
      # usage: browservm-vfkit-doctor [--fix]
      # Defense in depth for anything that gets past the lock anyway (a stale
      # build still on someone's PATH, a manually-invoked runner,
      # BROWSERVM_STATE_DIR overridden inconsistently between two calls).
      # Reports every process matching the socket filename and the lock's
      # state; --fix kills untracked processes and clears a stale lock.
      fix=0
      [ "''${1:-}" = "--fix" ] && fix=1

      echo "=== browservm-vfkit doctor ==="
      tracked_pid=""
      [ -f "$PID_FILE" ] && tracked_pid=$(cat "$PID_FILE" 2>/dev/null || true)

      mapfile -t procs < <(/usr/bin/pgrep -f "$SOCK_NAME" 2>/dev/null || true)
      if [ ''${#procs[@]} -eq 0 ]; then
        echo "processes: none matching '$SOCK_NAME' — clean."
      else
        echo "processes: ''${#procs[@]} matching '$SOCK_NAME':"
        orphans=()
        for p in "''${procs[@]}"; do
          # $tracked_pid is the `script` pty wrapper's pid — vfkit itself
          # runs as ITS CHILD, a different pid (verified live: matching on
          # exact pid alone always misclassified the legitimate vfkit
          # process as an orphan, which would have made --fix kill the
          # healthy VM every single run). A direct-parent match covers it.
          ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
          if [ -n "$tracked_pid" ] && { [ "$p" = "$tracked_pid" ] || [ "''${ppid:-}" = "$tracked_pid" ]; }; then
            echo "  pid $p — tracked (OK)"
          else
            echo "  pid $p — UNTRACKED (orphan candidate)"
            orphans+=("$p")
          fi
        done
        if [ ''${#orphans[@]} -gt 0 ]; then
          if [ "$fix" -eq 1 ]; then
            for p in "''${orphans[@]}"; do
              info "killing orphan pid $p"
              kill "$p" 2>/dev/null || true
            done
            # Confirm, don't fire-and-forget — vfkit can take several seconds
            # to actually exit after SIGTERM (observed live repeatedly).
            # Escalate to SIGKILL for anything still around past the grace
            # period, same reasoning as `stop`'s own confirm-then-escalate.
            waited=0
            still=1
            while [ "$still" -eq 1 ] && [ "$waited" -lt 10 ]; do
              still=0
              for p in "''${orphans[@]}"; do
                kill -0 "$p" 2>/dev/null && still=1
              done
              [ "$still" -eq 1 ] && sleep 1
              waited=$((waited + 1))
            done
            for p in "''${orphans[@]}"; do
              if kill -0 "$p" 2>/dev/null; then
                info "pid $p still alive after ''${waited}s — sending SIGKILL"
                kill -9 "$p" 2>/dev/null || true
              fi
            done
            echo "reaped ''${#orphans[@]} orphan(s)."
          else
            echo "run 'browservm-vfkit-doctor --fix' to kill ''${#orphans[@]} untracked process(es)."
          fi
        fi
      fi

      if [ -d "$LOCK_DIR" ]; then
        holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "''${holder:-}" ] && kill -0 "$holder" 2>/dev/null; then
          echo "lock: held by live pid $holder (normal if a start/stop is in flight)"
        else
          echo "lock: STALE (holder ''${holder:-unknown} not running)"
          if [ "$fix" -eq 1 ]; then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
            echo "cleared stale lock."
          else
            echo "run 'browservm-vfkit-doctor --fix' to clear it."
          fi
        fi
      else
        echo "lock: none held"
      fi

      if [ -f "$TUNNEL_PID_FILE" ] && ! tunnel_running; then
        echo "tunnel pid file: stale (process not running)"
        if [ "$fix" -eq 1 ]; then
          rm -f "$TUNNEL_PID_FILE"
          echo "cleared stale tunnel pid file."
        else
          echo "run 'browservm-vfkit-doctor --fix' to clear it."
        fi
      fi
    '';
  };

  selftest = mkApp {
    name = "browservm-vfkit-selftest";
    text = ''
      # A real, re-runnable lifecycle regression test: clean slate -> N
      # parallel `up` calls converge to exactly one VM -> N parallel `stop`
      # calls converge to a clean state -> a stale lock self-heals -> final
      # doctor check. Exits non-zero if anything failed. Safe to re-run
      # routinely — it never spins up more than one real guest; the whole
      # point is proving that N concurrent callers converge to one.
      STOP_BIN="${stop}/bin/browservm-vfkit-stop"
      UP_BIN="${up}/bin/browservm-vfkit-up"
      START_BIN="${start}/bin/browservm-vfkit-start"
      DOCTOR_BIN="${doctor}/bin/browservm-vfkit-doctor"
      N=5

      pass=0
      fail=0
      assert_eq() {
        # usage: assert_eq <description> <actual> <expected>
        if [ "$2" = "$3" ]; then
          echo "PASS: $1 ($2)"
          pass=$((pass + 1))
        else
          echo "FAIL: $1 (got '$2', expected '$3')"
          fail=$((fail + 1))
        fi
      }
      assert_zero() {
        # usage: assert_zero <description> <exit-status>
        if [ "$2" -eq 0 ]; then
          echo "PASS: $1"
          pass=$((pass + 1))
        else
          echo "FAIL: $1 (exit $2)"
          fail=$((fail + 1))
        fi
      }
      count_procs() {
        /usr/bin/pgrep -f "$SOCK_NAME" 2>/dev/null | wc -l | tr -d ' '
      }
      # Run $N copies of a command in parallel and report whether all of them
      # exited 0 — via each subshell writing its OWN exit code to a file,
      # not `wait $pid`'s return value. `wait` on a specific pid can be
      # unreliable here: these commands can return in well under a second
      # (the "not running, nothing to do" fast path), and rapid-fire
      # background+wait cycles on very short-lived processes hit inconsistent
      # exit-status reporting in practice (observed live — the exact same
      # 5-way parallel invocation was clean on every manual, slower
      # reproduction but intermittently reported a stray nonzero via `wait`
      # inside this tighter loop). Reading each subshell's own recorded exit
      # code sidesteps that entirely.
      run_parallel() {
        local cmd="$1" tag="$2" n pids=() ec all_ok=0
        for n in $(seq 1 "$N"); do
          ( "$cmd" >"$STATE_DIR/.selftest-$tag-$n.out" 2>&1; echo $? >"$STATE_DIR/.selftest-$tag-$n.ec" ) &
          pids+=($!)
        done
        for p in "''${pids[@]}"; do
          wait "$p" 2>/dev/null || true
        done
        for n in $(seq 1 "$N"); do
          ec=$(cat "$STATE_DIR/.selftest-$tag-$n.ec" 2>/dev/null || echo 1)
          if [ "$ec" != "0" ]; then
            all_ok=1
            echo "  [$tag-$n exited $ec]: $(cat "$STATE_DIR/.selftest-$tag-$n.out" 2>/dev/null)" >&2
          fi
          rm -f "$STATE_DIR/.selftest-$tag-$n.ec" "$STATE_DIR/.selftest-$tag-$n.out"
        done
        return "$all_ok"
      }

      echo "=== browservm-vfkit selftest ==="

      echo "--- 1/5: clean slate ---"
      "$STOP_BIN" >/dev/null 2>&1 || true
      "$DOCTOR_BIN" --fix >/dev/null 2>&1 || true
      assert_eq "clean slate: zero browservm processes" "$(count_procs)" "0"

      echo "--- 2/5: $N parallel 'up' calls converge to exactly one VM ---"
      up_ok=0
      run_parallel "$UP_BIN" "up" || up_ok=1
      assert_zero "all $N parallel 'up' invocations exited 0" "$up_ok"
      assert_eq "exactly one browservm process after $N parallel starts" "$(count_procs)" "1"
      curl_status=0
      /usr/bin/curl -fsS -m 5 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 || curl_status=1
      assert_zero "CDP endpoint answers after parallel 'up'" "$curl_status"

      echo "--- 3/5: $N parallel 'stop' calls converge to a clean state ---"
      stop_ok=0
      run_parallel "$STOP_BIN" "stop" || stop_ok=1
      assert_zero "all $N parallel 'stop' invocations exited 0" "$stop_ok"
      assert_eq "zero browservm processes after parallel stop" "$(count_procs)" "0"
      tunnel_status=0
      tunnel_running && tunnel_status=1
      assert_zero "no CDP tunnel process left behind" "$tunnel_status"

      echo "--- 4/5: stale lock self-heals ---"
      ( exit 0 ) & deadpid=$!
      wait "$deadpid" 2>/dev/null || true
      /bin/mkdir -p "$LOCK_DIR"
      echo "$deadpid" >"$LOCK_DIR/pid"
      t0=$(date +%s)
      "$START_BIN" >/dev/null 2>&1 || true
      t1=$(date +%s)
      elapsed=$((t1 - t0))
      if [ "$elapsed" -le 15 ]; then
        assert_zero "stale lock self-healed quickly (''${elapsed}s)" 0
      else
        assert_zero "stale lock self-healed quickly (''${elapsed}s, too slow)" 1
      fi

      echo "--- 5/5: final cleanup + doctor ---"
      "$STOP_BIN" >/dev/null 2>&1 || true
      assert_eq "final cleanup: zero processes" "$(count_procs)" "0"
      "$DOCTOR_BIN"

      echo "=== selftest: $pass passed, $fail failed ==="
      [ "$fail" -eq 0 ]
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
  browservm-vfkit-doctor = doctor;
  browservm-vfkit-selftest = selftest;
}
