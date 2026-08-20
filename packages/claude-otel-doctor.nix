# Health check for the local Claude Code routing-telemetry OTel Collector
# (modules/shared/claude-otel.nix, launchd label org.nix-community.home.
# claude-otel-collector, wrapped by hm-launchd as nix-claude-otel-collector).
# Generic + runtime-introspecting, like macvm-tart-doctor — no Nix-time config
# threading, just checks what's actually running/listening/on-disk right now.
{
  writeShellApplication,
  coreutils,
  findutils,
}:
writeShellApplication {
  name = "claude-otel-doctor";
  runtimeInputs = [
    coreutils
    findutils
  ];
  excludeShellChecks = [ "SC2016" ];
  text = ''
    rc=0
    echo "=== claude-otel doctor ==="

    label="org.nix-community.home.claude-otel-collector"
    if /bin/launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      echo "launchd agent: loaded ($label)"
    else
      echo "launchd agent: NOT LOADED — activate the macos config (see docs/claude-code-observability-runbook.md)"
      rc=1
    fi

    if (exec 3<>"/dev/tcp/127.0.0.1/4317") 2>/dev/null; then
      exec 3>&- 3<&-
      echo "otlp grpc endpoint: listening (127.0.0.1:4317)"
    else
      echo "otlp grpc endpoint: NOT LISTENING on 127.0.0.1:4317"
      rc=1
    fi

    events_file="''${CLAUDE_OTEL_EVENTS_FILE:-$HOME/.local/state/claude-otel/events.jsonl}"
    if [ -f "$events_file" ]; then
      mtime=$(/usr/bin/stat -f %m "$events_file")
      now=$(/bin/date +%s)
      age=$(( now - mtime ))
      echo "events file: $events_file (last write ''${age}s ago)"
      if [ "$age" -gt 86400 ]; then
        echo "  note: no write in over 24h — expected if Claude Code hasn't run recently, not necessarily a fault"
      fi
    else
      echo "events file: absent ($events_file) — no Claude Code session has run telemetry through it yet"
    fi

    echo "=== $([ "$rc" -eq 0 ] && echo PASS || echo FAIL) ==="
    exit "$rc"
  '';
}
