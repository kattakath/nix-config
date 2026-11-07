#!/usr/bin/env bash
# Rule 1 wrangler cases: a `wrangler` invocation in any segment ASKS the operator
# (since 2026-11-02; the Cloudflare MCP API tools are the usual route). A mention,
# or a word that merely contains "wrangler", is approved. Until this suite existed
# the branch had no test.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

# Assembled so this file's own text never reads as a wrangler call.
W="wran""gler"

decide() {
  python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | node "$H" 2>/dev/null \
    | python3 -c 'import json,sys;s=sys.stdin.read();d=json.loads(s) if s.strip() else {};print(d.get("decision") or d.get("hookSpecificOutput",{}).get("permissionDecision") or "none")' 2>/dev/null
}
reason() {
  python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | node "$H" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("hookSpecificOutput",{}).get("permissionDecisionReason",""))' 2>/dev/null
}
ck() { # ck <want> <cmd>
  got="$(decide "$2")"
  if [ "$got" = "$1" ]; then printf '  ok    %-8s %s\n' "$got" "$2"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "$2"; fail=$((fail+1)); fi
}

echo "== must ASK (a $W call) =="
ck ask "$W deploy"
ck ask "/opt/homebrew/bin/$W r2 bucket list"
ck ask "cd site && $W pages deploy dist"
ck ask "npx --yes true; $W whoami"

echo "== must APPROVE (a mention, not a call) =="
ck none "echo use $W later"
ck none "grep -rn $W docs/"
ck none "ls ${W}-config"

echo "== the ask reason is ONE line =="
r="$(reason "$W deploy")"
if [ -n "$r" ] && [ "$(printf '%s' "$r" | wc -l | tr -d ' ')" = "0" ]; then
  echo "  ok    one-line reason"; pass=$((pass+1))
else echo "  FAIL  reason empty or multi-line: $r"; fail=$((fail+1)); fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
