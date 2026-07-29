# macvm UTM control-plane (host Mac only).
#
# Guest OS: darwinConfigurations.macvm — activate inside the VM as aloshy.
# Disks/IPSWs never enter the Nix store. See docs/macvm-utm-runbook.md.
{
  writeShellApplication,
  writeText,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  gawk,
  python3,
}:
let
  vmName = "macvm";
  utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl";
  openBin = "/usr/bin/open";
  plutil = "/usr/bin/plutil";
  pgrep = "/usr/bin/pgrep";
  osascript = "/usr/bin/osascript";

  dedupePy = writeText "macvm-utm-registry-dedupe.py" ''
    import os, subprocess, plistlib, pathlib, datetime, sys

    canon = os.environ["MACVM_CANON"]
    pkg = os.environ["MACVM_PKG_PATH"]
    apply = os.environ.get("MACVM_APPLY") == "1"
    domain = os.environ["MACVM_PREFS_DOMAIN"]

    raw = subprocess.check_output(["/usr/bin/defaults", "export", domain, "-"])
    pl = plistlib.loads(raw)
    reg = pl.get("Registry") or {}
    if not isinstance(reg, dict):
        print("macvm-utm: no Registry in prefs", file=sys.stderr)
        sys.exit(1)

    same = []
    for uuid, meta in list(reg.items()):
        path = (meta.get("Package") or {}).get("Path") or ""
        name = meta.get("Name") or ""
        if name == "macvm" or path == pkg or path.rstrip("/") == pkg.rstrip("/"):
            same.append((uuid, name, path))

    print(f"canonical config UUID: {canon}")
    print(f"package path: {pkg}")
    print(f"matching registry entries: {len(same)}")
    for u, n, p in same:
        mark = "KEEP" if u == canon else "DROP"
        print(f"  [{mark}] {u} name={n} path={p}")

    if canon not in reg:
        print(
            "macvm-utm: REFUSING — canonical UUID not in registry; fix package first",
            file=sys.stderr,
        )
        sys.exit(1)

    drop = [u for u, _, _ in same if u != canon]
    if not drop:
        print("nothing to de-dupe")
        sys.exit(0)

    if not apply:
        print("dry-run only — re-run with --apply to remove DROP entries")
        sys.exit(0)

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir = (
        pathlib.Path.home() / "Library/Application Support" / f"utm-registry-backup-{stamp}"
    )
    backup_dir.mkdir(parents=True, exist_ok=True)
    before = backup_dir / "com.utmapp.UTM.before.plist"
    with open(before, "wb") as f:
        f.write(raw)
    for u in drop:
        del reg[u]
    pl["Registry"] = reg
    after = backup_dir / "com.utmapp.UTM.after.plist"
    with open(after, "wb") as f:
        plistlib.dump(pl, f)
    subprocess.check_call(["/usr/bin/defaults", "import", domain, str(after)])
    print(f"applied; backup: {backup_dir}")
    print(f"registry size now: {len(reg)}")
  '';

  bootstrapText = writeText "macvm-utm-bootstrap.txt" ''
    macvm guest bootstrap (run INSIDE the UTM VM)

    1. Login account: aloshy  (must match flake identity)
    2. Determinate Nix if missing: https://docs.determinate.systems
    3. First activation (also installs UTM Guest Tools / spice-vdagent):
         sudo nix run github:kattakath/nix-config#macvm
    4. Thereafter:
         sudo darwin-rebuild switch --flake .#macvm

    Host-side (outside the guest):
         nix run .#macvm-utm-doctor | start | ssh | ensure

    Disks are NOT in the flake. See docs/macvm-utm-runbook.md
  '';

  createText = writeText "macvm-utm-create.txt" ''
    Create the macvm UTM guest (host Mac — one-time GUI)

    utmctl cannot create Apple Virtualization macOS guests.

    1. nix run .#macvm-utm-open
    2. UTM → "+" → Virtualize → macOS (Apple Virtualization)
    3. Name the VM exactly: macvm
    4. Network: Shared; login user: aloshy
    5. UTM settings: Virtualization → Enable Clipboard Sharing (macOS 15+)
    6. Host: nix run .#macvm-utm-doctor
    7. Guest activate (installs spice-vdagent Guest Tools automatically):
         nix run .#macvm-utm-ssh -- sudo nix run github:kattakath/nix-config#macvm

    NEVER put IPSW or .img into the Nix store or this git repo.
  '';

  preamble = ''
    set -euo pipefail
    VM_NAME="${vmName}"
    UTMCTL="${utmctl}"
    UTM_DOCS="''${MACVM_UTM_DOCS:-$HOME/Library/Containers/com.utmapp.UTM/Data/Documents}"
    UTM_PKG="''${MACVM_UTM_PATH:-$UTM_DOCS/macvm.utm}"

    die() { echo "macvm-utm: $*" >&2; exit 1; }
    info() { echo "macvm-utm: $*" >&2; }

    require_utm() {
      if [ ! -x "$UTMCTL" ]; then
        die "UTM not found at $UTMCTL — install the utm cask (hosts/macos.nix) and re-activate"
      fi
    }

    resolve_macvm_uuid() {
      require_utm
      local out n
      out=$("$UTMCTL" list 2>/dev/null | grep -E "[[:space:]]''${VM_NAME}[[:space:]]*$" || true)
      n=$(printf '%s\n' "$out" | grep -c . || true)
      if [ "''${n:-0}" -eq 0 ]; then
        return 0
      fi
      if [ "$n" -gt 1 ]; then
        printf '%s\n' "$out" >&2
        die "multiple UTM VMs named '$VM_NAME' — run: nix run .#macvm-utm-registry-dedupe -- --apply"
      fi
      printf '%s\n' "$out" | awk '{print $1}'
    }

    utm_running() {
      ${pgrep} -xq UTM 2>/dev/null || ${pgrep} -f 'com.utmapp.UTM' >/dev/null 2>&1
    }

    quit_utm() {
      if utm_running; then
        info "quitting UTM…"
        ${osascript} -e 'tell application "UTM" to quit' 2>/dev/null || true
        local _i
        for _i in $(seq 1 40); do
          utm_running || return 0
          sleep 0.25
        done
        die "UTM still running — quit it and retry"
      fi
    }

    package_canon_uuid() {
      if [ ! -f "$UTM_PKG/config.plist" ]; then
        return 0
      fi
      ${plutil} -extract Information.UUID raw "$UTM_PKG/config.plist" 2>/dev/null || true
    }
  '';

  baseInputs = [
    coreutils
    findutils
    gnugrep
    gnused
    gawk
  ];

  mkApp =
    {
      name,
      text,
      runtimeInputs ? baseInputs,
    }:
    writeShellApplication {
      inherit name runtimeInputs;
      excludeShellChecks = [
        "SC2034"
        "SC2329"
      ];
      text = preamble + "\n" + text;
    };

  doctor = mkApp {
    name = "macvm-utm-doctor";
    text = ''
      rc=0
      echo "=== macvm-utm doctor ==="
      if [ -x "$UTMCTL" ]; then
        echo "utmctl: ok ($UTMCTL)"
      else
        echo "utmctl: MISSING ($UTMCTL)"
        rc=1
      fi

      if [ -d "$UTM_DOCS" ]; then
        echo "utm docs: ok ($UTM_DOCS)"
      else
        echo "utm docs: missing ($UTM_DOCS) — open UTM once to create the sandbox"
      fi

      if [ -d "$UTM_PKG" ]; then
        echo "package:  present ($UTM_PKG)"
        if [ -f "$UTM_PKG/config.plist" ]; then
          cu=$(package_canon_uuid || true)
          echo "config UUID: ''${cu:-unknown}"
        else
          echo "config.plist: MISSING"
          rc=1
        fi
        imgs=$(find "$UTM_PKG/Data" -name '*.img' 2>/dev/null | wc -l | tr -d ' ')
        echo "disk images: $imgs"
        if [ "''${imgs:-0}" -eq 0 ]; then
          echo "disk images: WARNING — package has no .img (incomplete install?)"
        fi
      else
        echo "package:  absent ($UTM_PKG) — run: nix run .#macvm-utm-ensure"
      fi

      if [ -x "$UTMCTL" ]; then
        matches=$("$UTMCTL" list 2>/dev/null | grep -E "[[:space:]]''${VM_NAME}[[:space:]]*$" || true)
        n=$(printf '%s\n' "$matches" | grep -c . || true)
        echo "utmctl list matches for '$VM_NAME': $n"
        if [ "''${n:-0}" -gt 0 ]; then
          printf '%s\n' "$matches"
        fi
        if [ "''${n:-0}" -gt 1 ]; then
          echo "ERROR: duplicate registry/sidebar entries — run macvm-utm-registry-dedupe -- --apply"
          rc=1
        fi
        if [ "''${n:-0}" -eq 1 ] && [ -f "$UTM_PKG/config.plist" ]; then
          listed=$(printf '%s\n' "$matches" | awk '{print $1}')
          cu=$(package_canon_uuid || true)
          if [ -n "''${cu:-}" ] && [ "$listed" != "$cu" ]; then
            echo "WARNING: listed UUID ($listed) != config.plist UUID ($cu)"
          fi
          st=$("$UTMCTL" status "$listed" 2>/dev/null || true)
          echo "status: ''${st:-unknown}"
        fi
      fi
      echo "guest persona: aloshy (activate with nix run …#macvm inside the VM)"
      exit "$rc"
    '';
  };

  list = mkApp {
    name = "macvm-utm-list";
    text = ''
      require_utm
      "$UTMCTL" list "$@"
    '';
  };

  openApp = mkApp {
    name = "macvm-utm-open";
    text = ''
      if [ ! -d /Applications/UTM.app ]; then
        die "UTM.app not in /Applications — install the utm cask and re-activate"
      fi
      exec ${openBin} -a UTM "$@"
    '';
  };

  start = mkApp {
    name = "macvm-utm-start";
    text = ''
      require_utm
      uuid=$(resolve_macvm_uuid || true)
      if [ -z "''${uuid:-}" ]; then
        die "no UTM VM named '$VM_NAME' — run: nix run .#macvm-utm-ensure"
      fi
      info "starting $VM_NAME ($uuid)"
      exec "$UTMCTL" start "$uuid"
    '';
  };

  stop = mkApp {
    name = "macvm-utm-stop";
    text = ''
      require_utm
      uuid=$(resolve_macvm_uuid || true)
      if [ -z "''${uuid:-}" ]; then
        die "no UTM VM named '$VM_NAME'"
      fi
      info "stopping $VM_NAME ($uuid)"
      exec "$UTMCTL" stop "$uuid"
    '';
  };

  registry-dedupe = mkApp {
    name = "macvm-utm-registry-dedupe";
    runtimeInputs = baseInputs ++ [ python3 ];
    text = ''
      apply=0
      yes=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --apply) apply=1; shift ;;
          --yes|-y) yes=1; shift ;;
          -h|--help)
            echo "usage: macvm-utm-registry-dedupe [--apply] [--yes]"
            echo "  dry-run by default; --apply mutates com.utmapp.UTM prefs"
            exit 0
            ;;
          *) die "unknown arg: $1" ;;
        esac
      done

      if [ ! -f "$UTM_PKG/config.plist" ]; then
        die "package config missing: $UTM_PKG/config.plist"
      fi
      canon=$(package_canon_uuid)
      [ -n "$canon" ] || die "could not read Information.UUID from config.plist"

      if [ "$apply" -eq 1 ]; then
        if utm_running && [ "$yes" -eq 0 ]; then
          die "UTM is running — quit it, or re-run with --yes to auto-quit"
        fi
        if [ "$yes" -eq 1 ]; then
          quit_utm
        fi
      fi

      export MACVM_CANON="$canon"
      export MACVM_PKG_PATH="$UTM_PKG"
      export MACVM_APPLY="$apply"
      export MACVM_PREFS_DOMAIN="com.utmapp.UTM"
      exec ${python3}/bin/python3 ${dedupePy}
    '';
  };

  bootstrap-print = mkApp {
    name = "macvm-utm-bootstrap-print";
    text = ''
      exec cat ${bootstrapText}
    '';
  };

  create-print = mkApp {
    name = "macvm-utm-create-print";
    text = ''
      exec cat ${createText}
    '';
  };

  # utmctl has no create for macOS AVF guests → ensure = health check or guide.
  ensure = mkApp {
    name = "macvm-utm-ensure";
    text = ''
      # Exit 0: healthy single macvm. Exit 2: missing (print create, open UTM).
      # Exit 1: errors (duplicates, broken package, missing UTM).
      if [ ! -x "$UTMCTL" ]; then
        die "UTM missing — activate macos (utm cask) first"
      fi

      matches=$("$UTMCTL" list 2>/dev/null | grep -E "[[:space:]]''${VM_NAME}[[:space:]]*$" || true)
      n=$(printf '%s\n' "$matches" | grep -c . || true)

      if [ "''${n:-0}" -gt 1 ]; then
        printf '%s\n' "$matches" >&2
        die "duplicate '$VM_NAME' entries — nix run .#macvm-utm-registry-dedupe -- --apply --yes"
      fi

      if [ "''${n:-0}" -eq 1 ] && [ -d "$UTM_PKG" ] && [ -f "$UTM_PKG/config.plist" ]; then
        info "macvm present and registered — ok"
        uuid=$(printf '%s\n' "$matches" | awk '{print $1}')
        st=$("$UTMCTL" status "$uuid" 2>/dev/null || true)
        echo "uuid=$uuid status=''${st:-unknown}"
        exit 0
      fi

      info "macvm not ready — create path is UTM GUI (utmctl has no create for macOS AVF)"
      cat ${createText}
      if [ -d /Applications/UTM.app ]; then
        info "opening UTM…"
        ${openBin} -a UTM || true
      fi
      exit 2
    '';
  };

  # SSH over UTM Shared (host bridge100 ≈ 192.168.64.0/24). Guest: services.openssh
  # + operator authorized_keys (hosts/macvm.nix). Discover :22 on the shared subnet.
  sshApp = mkApp {
    name = "macvm-utm-ssh";
    runtimeInputs = baseInputs ++ [ python3 ];
    text = ''
      # usage: macvm-utm-ssh [--ip ADDR] [--user USER] [ssh-args…]
      user=aloshy
      identity="''${MACVM_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
      ip="''${MACVM_SSH_IP:-}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --ip) ip="''${2:?}"; shift 2 ;;
          --user) user="''${2:?}"; shift 2 ;;
          -h|--help)
            echo "usage: macvm-utm-ssh [--ip ADDR] [--user USER] [ssh-args…]"
            echo "  Discovers macvm on UTM Shared net (192.168.64.0/24); default user aloshy."
            exit 0
            ;;
          --) shift; break ;;
          *) break ;;
        esac
      done

      if [ -z "$ip" ]; then
        mac=""
        if [ -f "$UTM_PKG/config.plist" ]; then
          mac=$(${plutil} -extract Network.0.MacAddress raw "$UTM_PKG/config.plist" 2>/dev/null || true)
        fi
        export MACVM_HINT_MAC="$mac"
        ip=$(
          ${python3}/bin/python3 - <<'PY'
      import os, re, socket, subprocess, sys

      hint = (os.environ.get("MACVM_HINT_MAC") or "").lower().replace("-", ":")
      try:
          arp = subprocess.check_output(["/usr/sbin/arp", "-an"], text=True, errors="replace")
      except Exception:
          arp = ""

      candidates = []
      for line in arp.splitlines():
          m = re.search(r"\((192\.168\.64\.\d+)\)\s+at\s+([0-9a-f:]+)", line, re.I)
          if not m:
              continue
          ip, mac = m.group(1), m.group(2).lower()
          if mac in ("(incomplete)", "incomplete"):
              continue
          if hint and mac == hint:
              print(ip)
              sys.exit(0)
          candidates.append(ip)

      probe = candidates + [f"192.168.64.{i}" for i in range(2, 32)]
      seen = set()
      for ip in probe:
          if ip in seen:
              continue
          seen.add(ip)
          s = socket.socket()
          s.settimeout(0.4)
          try:
              s.connect((ip, 22))
              print(ip)
              sys.exit(0)
          except Exception:
              pass
          finally:
              s.close()
      sys.exit(1)
      PY
        ) || true
      fi

      if [ -z "''${ip:-}" ]; then
        die "no SSH on UTM Shared net — start the VM, activate guest (#macvm), check ALF off"
      fi

      info "ssh $user@$ip"
      exec /usr/bin/ssh \
        -o "IdentityFile=$identity" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" \
        "$user@$ip" "$@"
    '';
  };

in
{
  macvm-utm-doctor = doctor;
  macvm-utm-list = list;
  macvm-utm-open = openApp;
  macvm-utm-start = start;
  macvm-utm-stop = stop;
  macvm-utm-registry-dedupe = registry-dedupe;
  macvm-utm-bootstrap-print = bootstrap-print;
  macvm-utm-create-print = create-print;
  macvm-utm-ensure = ensure;
  macvm-utm-ssh = sshApp;
}
