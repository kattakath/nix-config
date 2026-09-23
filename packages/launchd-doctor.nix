# Runtime health check for every launchd unit this fleet installs.
#
# Covers the three gaps that CANNOT be flake checks, because all three are
# properties of the RUNNING machine, not of the evaluated config:
#   (a) declared-vs-loaded drift — a plist on disk whose job is not in its domain
#   (b) log growth — launchd agent logs have no rotation until newsyslog covers them
#   (c) launchd's disabled DB and ~/Library/Logs both accumulate keys/files for
#       units that no longer exist
# `nix flake check` proves what the config SAYS. Only this proves what launchd DID.
#
# NO NIX-TIME THREADING, deliberately — same contract as claude-otel-doctor.nix.
# The installed plists ARE the declared set: nix-darwin writes /Library/Launch*
# and Home Manager writes ~/Library/LaunchAgents, so reading them back is exactly
# the "declared" side of declared-vs-loaded. Threading a Nix manifest in would
# make the doctor agree with the config by construction, which is the one thing a
# drift check must not do.
#
# READ-ONLY. It prints remedies; it never runs them. Bootstrapping a daemon needs
# root and is the operator's call.
#
# Why (a) exists at all: nix-darwin's launchd activation is diff-gated
# (modules/system/launchd.nix:19), so an unchanged plist means a dead daemon is
# never re-bootstrapped. modules/darwin/launchd-reconcile.nix fixes the recovery;
# this reports it, and stays useful as the check-only twin.
{
  writeShellApplication,
  coreutils,
  findutils,
  gnugrep,
  gnused,
}:
writeShellApplication {
  name = "launchd-doctor";
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    gnused
  ];
  text = ''
    rc=0
    uid=$(id -u)
    # Size at which an unrotated agent log is worth reporting (KiB).
    warn_kb=''${LAUNCHD_DOCTOR_WARN_KB:-5120}

    # Only units THIS fleet installs. Everything else on the box (Apple, Google,
    # Microsoft, Wireshark) is out of scope and must not be reported as drift.
    ours='^(org\.nixos|org\.nix-community\.home|com\.kattakath)\.'

    plists=()
    for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
      [ -d "$d" ] || continue
      while IFS= read -r p; do
        base=$(basename "$p" .plist)
        if echo "$base" | grep -Eq "$ours"; then plists+=("$p"); fi
      done < <(find "$d" -maxdepth 1 -name '*.plist' | sort)
    done

    domain_of() {
      case "$1" in
        /Library/LaunchDaemons/*) echo "system" ;;
        *) echo "gui/$uid" ;;
      esac
    }

    # NOTE: /usr/bin/stat, not stat. `coreutils` is in runtimeInputs and its GNU
    # stat shadows Apple's on PATH — GNU wants -c%s and dies on -f%z. Same reason
    # /usr/bin/plutil and /bin/launchctl are absolute here.
    logs_of() {
      /usr/bin/plutil -extract StandardOutPath raw -o - "$1" 2>/dev/null || true
      /usr/bin/plutil -extract StandardErrorPath raw -o - "$1" 2>/dev/null || true
    }

    echo "=== launchd doctor ==="
    echo "scope: ''${#plists[@]} unit(s) installed by this fleet"
    echo

    # ---- (a) declared vs loaded, and non-zero exits --------------------------
    echo "--- loaded ---"
    for p in "''${plists[@]}"; do
      label=$(basename "$p" .plist)
      target="$(domain_of "$p")/$label"
      if ! out=$(/bin/launchctl print "$target" 2>/dev/null); then
        echo "  NOT LOADED  $label"
        echo "              plist is on disk but the job is absent from $(domain_of "$p")."
        echo "              remedy: sudo launchctl bootstrap $(domain_of "$p") $p"
        rc=1
        continue
      fi
      # The exit-code half is what catches the exit-78 class: loaded, present in
      # the domain, and failing every single spawn.
      code=$(echo "$out" | grep -m1 'last exit code' | sed 's/.*= *//' || true)
      case "$code" in
        ""|0|"(never exited)") ;;
        *) echo "  EXIT $code     $label"; rc=1 ;;
      esac
    done
    echo

    # ---- (b) log growth ------------------------------------------------------
    echo "--- log size (warn at ''${warn_kb} KiB) ---"
    declare -a seen=()
    for p in "''${plists[@]}"; do
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Dedupe on PATH, not per unit: media-queue and media-queue-power declare
        # the same file, and most units declare it twice (stdout AND stderr).
        for s in "''${seen[@]:-}"; do [ "$s" = "$f" ] && continue 2; done
        seen+=("$f")
        [ -f "$f" ] || continue
        kb=$(( $(/usr/bin/stat -f%z "$f") / 1024 ))
        if [ "$kb" -ge "$warn_kb" ]; then
          echo "  $(printf '%8d' "$kb") KiB  $f"
          rc=1
        fi
      done < <(logs_of "$p")
    done
    echo "  (unlisted = under threshold)"
    echo

    # ---- (c) disabled-DB keys with no plist ----------------------------------
    echo "--- launchd disabled-DB orphans ---"
    for dom in "gui/$uid" system; do
      /bin/launchctl print-disabled "$dom" 2>/dev/null |
        grep -oE '"[^"]+"' | tr -d '"' |
        grep -E "$ours" |
        while IFS= read -r label; do
          found=""
          for p in "''${plists[@]}"; do
            [ "$(basename "$p" .plist)" = "$label" ] && found=1 && break
          done
          [ -n "$found" ] || echo "  $dom  $label  (no plist installed)"
        done
    done
    echo "  note: cosmetic while every key reads 'enabled'. A stale 'disabled'"
    echo "        entry makes a later bootstrap of that label fail with error 119."
    echo

    # ---- (d) logs no installed unit writes -----------------------------------
    echo "--- orphan logs in ~/Library/Logs ---"
    declare -a declared=()
    for p in "''${plists[@]}"; do
      while IFS= read -r f; do [ -n "$f" ] && declared+=("$f"); done < <(logs_of "$p")
    done
    while IFS= read -r f; do
      for d in "''${declared[@]:-}"; do [ "$d" = "$f" ] && continue 2; done
      kb=$(( $(/usr/bin/stat -f%z "$f") / 1024 ))
      echo "  $(printf '%8d' "$kb") KiB  $f"
    done < <(find "$HOME/Library/Logs" -maxdepth 1 -name '*.log' | sort)
    echo "  remedy: no installed unit writes these. rm when you are satisfied"
    echo "          the owning feature is really gone."
    echo

    if [ "$rc" -ne 0 ]; then
      echo "launchd-doctor: findings above"
    else
      echo "launchd-doctor: clean"
    fi
    exit "$rc"
  '';
}
