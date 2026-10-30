#!/usr/bin/env bash
# The two SessionStart digests keep their last-run state PER USER, under
# ${XDG_STATE_HOME:-~/.local/state}/nix-config/, not in the checkout — so a
# worktree session does not read a false "never run". Both are pointed at
# scratch dirs here (XDG_STATE_HOME, CLAUDE_PROJECT_DIR, CLAUDE_OTEL_EVENTS_FILE),
# so the operator's real state and telemetry are never read or written.
set -uo pipefail
FD=.claude/hooks/fleet-doctor-digest.js
RR=.claude/hooks/routing-review-digest.js
pass=0; fail=0
ck() { # ck <label> <want: silent|nudge> <output> <exit>
  local got=nudge
  [ -z "$3" ] && got=silent
  if [ "$got" = "$2" ] && [ "$4" -eq 0 ]; then printf '  ok    %-7s %s\n' "$got" "$1"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s exit=%s  %s\n' "$2" "$got" "$4" "$1"; fail=$((fail+1)); fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
STATE="$T/state"; PROJ="$T/checkout"; mkdir -p "$STATE" "$PROJ/.claude/hooks"
now="$(node -e 'console.log(new Date().toISOString())')"
old="2020-01-01T00:00:00.000Z"

fd() { XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$PROJ" node "$FD"; }
rr() { XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_OTEL_EVENTS_FILE="$T/events.jsonl" node "$RR"; }

echo "== fleet-doctor-digest =="
out="$(fd)"; ck "no state anywhere -> never-run nudge" nudge "$out" $?
mkdir -p "$STATE/nix-config"
printf '{"lastRunAt":"%s"}\n' "$now" > "$STATE/nix-config/fleet-doctor-state.json"
out="$(fd)"; ck "fresh per-user state -> silent" silent "$out" $?
# The bug this fixes: a DIFFERENT checkout (a worktree) with no file of its own.
out="$(XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$T/other-worktree" node "$FD")"
ck "fresh per-user state, another checkout -> silent" silent "$out" $?
printf '{"lastRunAt":"%s"}\n' "$old" > "$STATE/nix-config/fleet-doctor-state.json"
out="$(fd)"; ck "stale per-user state -> nudge" nudge "$out" $?
rm "$STATE/nix-config/fleet-doctor-state.json"
printf '{"lastRunAt":"%s"}\n' "$now" > "$PROJ/.claude/hooks/.fleet-doctor-state.json"
out="$(fd)"; ck "only the legacy per-checkout file -> still read (silent)" silent "$out" $?
rm "$PROJ/.claude/hooks/.fleet-doctor-state.json"

echo "== routing-review-digest =="
# Three relevant decisions (the NUDGE_THRESHOLD), timestamped 2023-11-14.
node -e '
const rec = (n) => ({ timeUnixNano: String(1700000000000000000n + BigInt(n)), attributes: [
  { key: "event.name", value: { stringValue: "tool_decision" } },
  { key: "source", value: { stringValue: "user_temporary" } },
  { key: "tool_name", value: { stringValue: "Bash" } } ] });
console.log(JSON.stringify({ resourceLogs: [{ scopeLogs: [{ logRecords: [rec(1), rec(2), rec(3)] }] }] }));
' > "$T/events.jsonl"
out="$(rr)"; ck "unreviewed backlog -> nudge" nudge "$out" $?
printf '{"reviewedAt":"%s"}\n' "$now" > "$STATE/nix-config/routing-review-state.json"
out="$(rr)"; ck "reviewed per-user -> silent" silent "$out" $?
out="$(XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$T/other-worktree" CLAUDE_OTEL_EVENTS_FILE="$T/events.jsonl" node "$RR")"
ck "reviewed per-user, another checkout -> silent" silent "$out" $?
rm "$STATE/nix-config/routing-review-state.json"
printf '{"reviewedAt":"%s"}\n' "$now" > "$PROJ/.claude/hooks/.routing-review-state.json"
out="$(rr)"; ck "only the legacy per-checkout file -> still read (silent)" silent "$out" $?

echo "== the writers in .claude/commands/ stamp the path the readers read =="
# Run each command's own `node -e` stamp line, extracted from the markdown, so a
# writer that drifts from its reader goes red here rather than in a session.
rm -rf "$STATE/nix-config" "$PROJ/.claude/hooks/.routing-review-state.json"
for pair in "fleet-doctor:fleet-doctor-state.json" "routing-review:routing-review-state.json"; do
  cmd="${pair%%:*}"; file="${pair#*:}"
  line="$(grep -m1 "^ *node -e '.*$file" ".claude/commands/$cmd.md" | sed 's/^ *//')"
  if [ -z "$line" ]; then printf '  FAIL  no stamp line naming %s in %s.md\n' "$file" "$cmd"; fail=$((fail+1)); continue; fi
  (cd "$PROJ" && XDG_STATE_HOME="$STATE" bash -c "$line")
  if [ -s "$STATE/nix-config/$file" ]; then printf '  ok    /%s stamps $XDG_STATE_HOME/nix-config/%s\n' "$cmd" "$file"; pass=$((pass+1))
  else printf '  FAIL  /%s did not write $XDG_STATE_HOME/nix-config/%s\n' "$cmd" "$file"; fail=$((fail+1)); fi
done
out="$(fd)"; ck "after /fleet-doctor's stamp -> silent" silent "$out" $?
out="$(rr)"; ck "after /routing-review's stamp -> silent" silent "$out" $?

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
