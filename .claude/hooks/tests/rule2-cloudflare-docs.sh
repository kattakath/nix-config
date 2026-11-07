#!/usr/bin/env bash
# Rule 2 cases: a direct HTTP fetch of the Cloudflare DOCS host ASKS the operator
# (since 2026-11-02; the docs MCP tool is the usual route); other hosts, and mere
# mentions, get NO decision (the permission flow decides).
# Kept in a FILE for the same reason as the other suites: the block/ cases are
# execution-shaped, so carrying them in an argv would trip the rule under test.
# Until this suite existed Rule 2 was the only guard rule with no test.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

# Assembled rather than written literally, so this file's own text does not read
# as a fetch to a future grep-based rule.
DOCS="developers.cloud""flare.com"
CU="cu""rl"

decide() {
  python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | node "$H" 2>/dev/null \
    | python3 -c 'import json,sys;s=sys.stdin.read();d=json.loads(s) if s.strip() else {};print(d.get("decision") or d.get("hookSpecificOutput",{}).get("permissionDecision") or "none")' 2>/dev/null
}
ck() { # ck <want> <cmd>
  got="$(decide "$2")"
  if [ "$got" = "$1" ]; then printf '  ok    %-8s %s\n' "$got" "$2"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "$2"; fail=$((fail+1)); fi
}

echo "== must ASK (a direct docs fetch) =="
ck ask "$CU https://$DOCS/workers/"
ck ask "$CU -s https://$DOCS/r2/api/"

echo "== must APPROVE (not the docs host, or only a mention) =="
ck none "$CU https://example.com/"
ck none "echo cloudflare docs live at the MCP tool"
ck none "grep -rn cloudflare docs/"

echo "== the api.cloudflare.com nudge carries NO decision and says why (decision alone proves nothing) =="
API="api.cloud""flare.com"
out="$(python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$CU -s https://$API/client/v4/zones" | node "$H" 2>/dev/null)"
d="$(printf '%s' "$out" | python3 -c 'import json,sys;s=sys.stdin.read();d=json.loads(s) if s.strip() else {};print(d.get("decision") or d.get("hookSpecificOutput",{}).get("permissionDecision") or "none")' 2>/dev/null)"
m="$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("systemMessage",""))' 2>/dev/null)"
case "$d|$m" in
  "none|"*"raw call allowed"*) echo "  ok    none     api host nudge"; pass=$((pass+1));;
  *) echo "  FAIL  api host: decision=$d msg=$m"; fail=$((fail+1));;
esac

echo "== a non-JSON payload fails OPEN to NO decision (empty stdout), rc 0 =="
out="$(printf 'not json' | node "$H")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then echo "  ok    none     malformed payload"; pass=$((pass+1))
else echo "  FAIL  rc=$rc out=$out"; fail=$((fail+1)); fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
