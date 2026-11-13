#!/usr/bin/env bash
# stop-gate.js check 0: a FAILED grok-build run blocks the stop of the session that owns it,
# and only that one.
#
# Ownership comes from the job's `sessionId`, but the bridge records one only when the
# plugin's SessionStart env-file export reached Bash, and it mostly does not (5 of 593
# session-env files, measured 2026-11-13). The old filter skipped a failure only when BOTH
# ids were present, so an unattributed failure blocked whichever checkout stopped next.
# Now an unattributed job counts only in the checkout that ran it (`workspaceRoot`).
set -uo pipefail
H="$PWD/.claude/hooks/stop-gate.js"
pass=0; fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkrepo() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
mkrepo "$TMP/repo-a"; mkrepo "$TMP/repo-b"
state="$TMP/home/.claude/plugins/data/grok-build-xai-grok-build/state/x"
mkdir -p "$state"

# job <id> <sessionId or ""> <workspaceRoot>
job() { python3 -c 'import json,sys;j={"id":sys.argv[1],"status":"failed","kindLabel":"delegate","summary":"boom","workspaceRoot":sys.argv[3]}
if sys.argv[2]: j["sessionId"]=sys.argv[2]
print(json.dumps(j))' "$@"; }
write_state() { printf '{"jobs":[%s]}' "$(IFS=,; echo "$*")" > "$state/state.json"; }

decide() { # decide <project-dir> <session-id>
  rm -f "$1/.claude/hooks/.grok-runs-state.json"
  mkdir -p "$1/.claude/hooks"
  printf '{"session_id":"%s"}' "$2" \
    | HOME="$TMP/home" CLAUDE_PROJECT_DIR="$1" GIT_CONFIG_GLOBAL=/dev/null node "$H" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("decision","?"))' 2>/dev/null
}
ck() { # ck <want> <project> <session> <label>
  got="$(decide "$2" "$3")"
  if [ "$got" = "$1" ]; then printf '  ok    %-8s %s\n' "$got" "$4"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "$4"; fail=$((fail+1)); fi
}

write_state "$(job r1 S1 "$TMP/repo-a")"
ck block   "$TMP/repo-a" S1 "attributed failure, owning session"
ck approve "$TMP/repo-a" S2 "attributed failure, another session"

write_state "$(job r2 "" "$TMP/repo-a")"
ck block   "$TMP/repo-a" S2 "unattributed failure, the checkout that ran it"
ck approve "$TMP/repo-b" S2 "unattributed failure, a different checkout (was: block)"

write_state "$(job r3 "" "")"
ck approve "$TMP/repo-a" S2 "unattributed failure with no workspaceRoot"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
