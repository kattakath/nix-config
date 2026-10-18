#!/usr/bin/env bash
# Rule 2 cases: a direct HTTP fetch of the Cloudflare DOCS host is blocked
# (use the docs MCP tool instead); other hosts, and mere mentions, are not.
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
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("decision","?"))' 2>/dev/null
}
ck() { # ck <want> <cmd>
  got="$(decide "$2")"
  if [ "$got" = "$1" ]; then printf '  ok    %-8s %s\n' "$got" "$2"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "$2"; fail=$((fail+1)); fi
}

echo "== must BLOCK (a direct docs fetch) =="
ck block "$CU https://$DOCS/workers/"
ck block "$CU -s https://$DOCS/r2/api/"

echo "== must APPROVE (not the docs host, or only a mention) =="
ck approve "$CU https://example.com/"
ck approve "echo cloudflare docs live at the MCP tool"
ck approve "grep -rn cloudflare docs/"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
