#!/usr/bin/env bash
# The guard's OUTPUT CONTRACT, asserted byte-for-byte (2026-11-07).
# On PreToolUse, `{"decision":"approve"}` is the deprecated spelling of
# `permissionDecision: "allow"`, and an allow SKIPS the permission prompt
# (https://code.claude.com/docs/en/hooks, PreToolUse decision control). Measured
# 2026-11-07 on 2.1.300: in a scratch project with no allow rule, `claude -p`
# DENIED `touch` under a silent hook and RAN it under an approving one. So a
# guard that only ever objects must emit NOTHING when it has no objection.
# The per-rule suites assert decisions; this one asserts the exact shapes,
# because a decoder that maps "no decision" and "approve" alike would pass both.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

run() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" | node "$H" 2>/dev/null; }
keys() { python3 -c 'import json,sys;s=sys.stdin.read();print(",".join(sorted(json.loads(s))) if s.strip() else "EMPTY")' 2>/dev/null || echo "NOT-JSON"; }
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== no objection = EMPTY stdout, exit 0 (never approve/allow) =="
for c in 'ls -l /tmp' 'git status' 'echo hello' ''; do
  out="$(run "$c")"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "empty     '$c'"; else bad "rc=$rc out=$out  '$c'"; fi
done
out="$(printf 'not json' | node "$H")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "empty     malformed payload"; else bad "rc=$rc out=$out  malformed payload"; fi

echo "== a nudge = systemMessage ONLY, no decision =="
API="api.cloud""flare.com"
got="$(run "cu""rl -s https://$API/client/v4/zones" | keys)"
if [ "$got" = "systemMessage" ]; then ok "nudge     keys=$got"; else bad "nudge keys=$got"; fi

echo "== a block keeps its full shape =="
got="$(run 'secret reveal K' | keys)"
if [ "$got" = "decision,reason,systemMessage" ]; then ok "block     keys=$got"; else bad "block keys=$got"; fi
got="$(run 'secret reveal K' | python3 -c 'import json,sys;print(json.load(sys.stdin)["decision"])')"
if [ "$got" = "block" ]; then ok "block     decision=$got"; else bad "block decision=$got"; fi

echo "== an ask keeps its hookSpecificOutput shape =="
got="$(run "cu""rl https://developers.cloud""flare.com/workers/" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(",".join(sorted(d))+"|"+d["hookSpecificOutput"]["permissionDecision"])')"
if [ "$got" = "hookSpecificOutput|ask" ]; then ok "ask       $got"; else bad "ask $got"; fi

echo "== the source has no path left that emits approve/allow =="
# A literal is the only way this file could produce one; a regression re-adding
# `decision: "approve"` or `permissionDecision: "allow"` fails here.
# Comment lines (// and the * of block comments) are skipped: the header cites
# the deprecated spelling on purpose.
PAT='decision: *"approve"|emit\("approve"\)|permissionDecision: *"allow"'
hits="$(grep -nE "$PAT" "$H" | grep -vE '^[0-9]+: *(//|\*)')"
if [ -n "$hits" ]; then
  bad "an approve/allow emitter is back: $(printf '%s' "$hits" | head -3)"
else ok "no approve/allow emitter in $H"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
