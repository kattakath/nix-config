#!/usr/bin/env bash
# Rule 1 (terranix family) cases, added with the 2026-09-22 split.
#
# The split under test: `*-destroy` is hard-blocked unconditionally; `*-apply`
# is a non-blocking nudge (RULE1_TERRANIX_APPLY_BLOCKING = false). Both halves
# are asserted, because a rule that only ever proves its BLOCK cases cannot
# tell you it has stopped approving the things it should approve.
#
# Same file-not-argv discipline as rule1c/rule1d: the strings below are
# execution-shaped, so writing them on a command line would trip the rule that
# carries them.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

NR="nix ""run"
AND="&""&"

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

echo "== must BLOCK (teardown: no readable plan, and it cannot even clean up fully) =="
ck block "$NR .#mcp-public-destroy"
ck block "$NR .#cf-tunnel-destroy"
ck block "$NR github:kattakath/nix-config#cf-tunnel-destroy"
ck block "secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:mcp-public -- $NR .#mcp-public-destroy"

echo "== must stay APPROVED (apply: the wrapper's own guards + a plan run first) =="
ck approve "$NR .#mcp-public-apply"
ck approve "$NR .#cf-tunnel-apply"
ck approve "$NR .#mcp-public-apply -- -parallelism=2 -auto-approve"
ck approve "secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:mcp-public -- $NR .#mcp-public-apply"
ck approve "$NR github:kattakath/nix-config#mcp-public-apply"

echo "== an apply must not launder a destroy sitting next to it =="
ck block "$NR .#mcp-public-apply $AND $NR .#cf-tunnel-destroy"

echo "== unrelated apps are untouched by either half =="
ck approve "$NR .#mcp-public-token"
ck approve "$NR .#nixvm"

echo "-- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
