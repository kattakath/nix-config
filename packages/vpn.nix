# WireGuard operator — atomic / idempotent / graceful tunnel control.
# Operates confs under ~/.config/wireguard (synced by local.wireguardConfigs).
# Never prints private keys. Does not install confs (see plant dir + HM sync).
{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  findutils,
}:
writeShellApplication {
  name = "vpn";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    gawk
    findutils
  ];
  excludeShellChecks = [
    "SC2012"
    "SC2016"
    "SC2034"
    "SC2086"
    "SC2318"
  ];
  text = ''
    set -euo pipefail

    conf_dir="''${VPN_CONFIG_DIR:-$HOME/.config/wireguard}"
    source_dir="''${VPN_SOURCE_DIR:-$HOME/.local/share/wireguard-configs}"
    lock_file="''${VPN_LOCK:-/tmp/vpn-operator.lock}"
    handshake_wait="''${VPN_HANDSHAKE_WAIT:-15}"
    # Prefer Homebrew tools on darwin; fall back to PATH.
    WG="''${WG:-}"
    WGQ="''${WG_QUICK:-}"
    if [ -z "$WG" ]; then
      if [ -x /opt/homebrew/bin/wg ]; then WG=/opt/homebrew/bin/wg
      elif [ -x /usr/local/bin/wg ]; then WG=/usr/local/bin/wg
      else WG=$(command -v wg 2>/dev/null || true)
      fi
    fi
    if [ -z "$WGQ" ]; then
      if [ -x /opt/homebrew/bin/wg-quick ]; then WGQ=/opt/homebrew/bin/wg-quick
      elif [ -x /usr/local/bin/wg-quick ]; then WGQ=/usr/local/bin/wg-quick
      else WGQ=$(command -v wg-quick 2>/dev/null || true)
      fi
    fi

    die() { echo "vpn: $*" >&2; exit 1; }
    info() { echo "vpn: $*" >&2; }
    ok() { echo "vpn: $*" >&2; }

    usage() {
      cat >&2 <<'EOF'
    usage: vpn <command> [args]

    Atomic, idempotent WireGuard control for confs in ~/.config/wireguard
    (plant sources in ~/.local/share/wireguard-configs; HM syncs on activate).

      list                 conf names available (no secrets)
      status               active tunnels + handshake/transfer (redacted)
      doctor               tools, dirs, conf inventory
      up <name>            bring up conf (idempotent; fails if another is up)
      down [name]          bring down one conf, or all managed confs
      switch <name>        down all managed, then up <name> (atomic)
      restart <name>       down then up

    Env:
      VPN_CONFIG_DIR       default ~/.config/wireguard
      VPN_SOURCE_DIR       default ~/.local/share/wireguard-configs
      VPN_HANDSHAKE_WAIT   seconds to wait for handshake (default 15)
      WG / WG_QUICK        override tool paths

    Examples:
      vpn list
      vpn switch BANGKOK
      vpn status
      vpn down
    EOF
    }

    require_tools() {
      [ -n "''${WG:-}" ] && [ -x "$WG" ] || die "wg not found — install wireguard-tools (brew) or activate darwin host"
      [ -n "''${WGQ:-}" ] && [ -x "$WGQ" ] || die "wg-quick not found — install wireguard-tools"
    }

    # Resolve NAME / NAME.conf / path → absolute conf path + basename stem
    resolve_conf() {
      local raw="''${1:-}" conf base
      [ -n "$raw" ] || die "missing conf name"
      raw="''${raw%.conf}"
      if [ -f "$raw" ]; then
        conf=$(cd "$(dirname "$raw")" && pwd)/$(basename "$raw")
      elif [ -f "$conf_dir/$raw.conf" ]; then
        conf="$conf_dir/$raw.conf"
      elif [ -f "$conf_dir/$raw" ]; then
        conf="$conf_dir/$raw"
      else
        die "no conf for '$1' (looked in $conf_dir)"
      fi
      base=$(basename "$conf" .conf)
      printf '%s\t%s\n' "$conf" "$base"
    }

    list_confs() {
      local f
      if [ ! -d "$conf_dir" ]; then
        return 0
      fi
      # shellcheck disable=SC2012
      ls -1 "$conf_dir"/*.conf 2>/dev/null | while read -r f; do
        basename "$f" .conf
      done | sort
    }

    # Map of managed conf stems we know about
    is_managed_name() {
      local name="$1" c
      for c in $(list_confs); do
        [ "$c" = "$name" ] && return 0
      done
      return 1
    }

    # Active interface name for a conf stem (wg-quick writes /var/run/wireguard/NAME.name)
    iface_for() {
      local name="$1" f="/var/run/wireguard/$name.name"
      if [ -f "$f" ]; then
        cat "$f"
        return 0
      fi
      return 1
    }

    is_up() {
      local name="$1" iface
      iface=$(iface_for "$name" 2>/dev/null || true)
      [ -n "''${iface:-}" ] || return 1
      "$WG" show "$iface" >/dev/null 2>&1
    }

    active_managed() {
      local name
      for name in $(list_confs); do
        if is_up "$name"; then
          echo "$name"
        fi
      done
    }

    # Redacted status for one interface
    show_iface_status() {
      local iface="$1" name="''${2:-}"
      local line
      echo "interface: $iface''${name:+ ($name)}"
      "$WG" show "$iface" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *"private key:"*) continue ;;
          *) printf '  %s\n' "$line" ;;
        esac
      done
    }

    wait_handshake() {
      local name="$1" iface i show
      iface=$(iface_for "$name") || return 1
      for i in $(seq 1 "$handshake_wait"); do
        show=$("$WG" show "$iface" 2>/dev/null || true)
        if echo "$show" | grep -qiE 'latest handshake:.*(second|minute|hour|day|ago)'; then
          ok "$name: handshake ok (iface $iface)"
          return 0
        fi
        sleep 1
      done
      info "$name: no handshake within ''${handshake_wait}s (iface $iface) — tunnel may still come up"
      return 1
    }

    with_lock() {
      # Atomic critical section (mkdir lock — portable; no util-linux flock on macOS).
      local d="$lock_file.d" n=0
      while ! mkdir "$d" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -lt 60 ] || die "could not acquire lock $d"
        sleep 0.5
      done
      # shellcheck disable=SC2064
      trap 'rmdir "$d" 2>/dev/null || true' EXIT
      "$@"
      rmdir "$d" 2>/dev/null || true
      trap - EXIT
    }

    do_restart() {
      do_down_one "$1"
      sleep 1
      do_up "$1"
    }

    cmd_list() {
      local n
      n=$(list_confs | wc -l | tr -d ' ')
      if [ "''${n:-0}" -eq 0 ]; then
        info "no confs in $conf_dir (plant $source_dir/*.conf and re-activate)"
        return 0
      fi
      list_confs | while read -r name; do
        if is_up "$name"; then
          printf '%-12s %s\n' "$name" up
        else
          printf '%-12s %s\n' "$name" down
        fi
      done
    }

    cmd_status() {
      require_tools
      local name iface any=0
      for name in $(active_managed); do
        any=1
        iface=$(iface_for "$name")
        show_iface_status "$iface" "$name"
        echo
      done
      if [ "$any" -eq 0 ]; then
        # Also show any non-managed wg interfaces
        if "$WG" show interfaces 2>/dev/null | grep -q .; then
          info "no managed confs up; other interfaces:"
          "$WG" show 2>/dev/null | grep -v 'private key' || true
        else
          ok "no tunnels up"
        fi
      fi
    }

    cmd_doctor() {
      echo "conf_dir:   $conf_dir $([ -d "$conf_dir" ] && echo ok || echo MISSING)"
      echo "source_dir: $source_dir $([ -d "$source_dir" ] && echo ok || echo MISSING)"
      echo "wg:         ''${WG:-MISSING}"
      echo "wg-quick:   ''${WGQ:-MISSING}"
      if [ -d "$source_dir" ]; then
        echo "source confs: $(ls -1 "$source_dir"/*.conf 2>/dev/null | wc -l | tr -d ' ')"
      fi
      if [ -d "$conf_dir" ]; then
        echo "active confs: $(ls -1 "$conf_dir"/*.conf 2>/dev/null | wc -l | tr -d ' ')"
      fi
      require_tools
      echo "managed:"
      cmd_list
    }

    do_up() {
      local conf base active others pair
      require_tools
      pair=$(resolve_conf "$1")
      conf=$(printf '%s\n' "$pair" | cut -f1)
      base=$(printf '%s\n' "$pair" | cut -f2)

      if is_up "$base"; then
        ok "$base: already up"
        wait_handshake "$base" || true
        return 0
      fi

      active=$(active_managed | tr '\n' ' ')
      if [ -n "''${active// /}" ]; then
        others=$(echo "$active" | tr ' ' '\n' | grep -v "^$base$" | tr '\n' ' ' || true)
        if [ -n "''${others// /}" ]; then
          die "$base: other tunnel(s) active ($others)— use: vpn switch $base"
        fi
      fi

      info "$base: bringing up…"
      if ! sudo "$WGQ" up "$conf"; then
        die "$base: wg-quick up failed"
      fi
      wait_handshake "$base" || true
      ok "$base: up"
    }

    do_down_one() {
      local conf base pair
      pair=$(resolve_conf "$1")
      conf=$(printf '%s\n' "$pair" | cut -f1)
      base=$(printf '%s\n' "$pair" | cut -f2)
      if ! is_up "$base"; then
        ok "$base: already down"
        return 0
      fi
      info "$base: bringing down…"
      if ! sudo "$WGQ" down "$conf"; then
        # Try by name file / residual
        sudo "$WGQ" down "$base" 2>/dev/null || true
        die "$base: wg-quick down failed"
      fi
      ok "$base: down"
    }

    do_down_all() {
      local name any=0
      require_tools
      for name in $(active_managed); do
        any=1
        do_down_one "$name" || true
      done
      if [ "$any" -eq 0 ]; then
        ok "no managed tunnels up"
      fi
    }

    do_switch() {
      local conf base name pair
      require_tools
      pair=$(resolve_conf "$1")
      conf=$(printf '%s\n' "$pair" | cut -f1)
      base=$(printf '%s\n' "$pair" | cut -f2)

      if is_up "$base"; then
        # Already target — still ensure nothing else is up
        for name in $(active_managed); do
          if [ "$name" != "$base" ]; then
            do_down_one "$name" || true
          fi
        done
        ok "$base: already up (switch no-op)"
        wait_handshake "$base" || true
        return 0
      fi

      info "switch → $base"
      for name in $(active_managed); do
        do_down_one "$name" || true
      done
      # Brief settle so routes/DNS from previous full-tunnel clear
      sleep 1
      if ! sudo "$WGQ" up "$conf"; then
        die "$base: wg-quick up failed after switch"
      fi
      wait_handshake "$base" || true
      ok "switch: $base is up"
    }

    cmd="''${1:-}"
    if [ -n "$cmd" ]; then shift; fi
    case "$cmd" in
      "" | -h | --help | help) usage; exit 0 ;;
      list) cmd_list ;;
      status) cmd_status ;;
      doctor) cmd_doctor ;;
      up)
        [ "$#" -ge 1 ] || die "usage: vpn up <name>"
        with_lock do_up "$1"
        ;;
      down)
        if [ "$#" -ge 1 ]; then
          with_lock do_down_one "$1"
        else
          with_lock do_down_all
        fi
        ;;
      switch)
        [ "$#" -ge 1 ] || die "usage: vpn switch <name>"
        with_lock do_switch "$1"
        ;;
      restart)
        [ "$#" -ge 1 ] || die "usage: vpn restart <name>"
        with_lock do_restart "$1"
        ;;
      *)
        die "unknown command: $cmd (try: vpn --help)"
        ;;
    esac
  '';
}
