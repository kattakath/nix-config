#!/usr/bin/env bash
# Rule 1 (terranix family) cases, added with the 2026-09-22 split.
#
# The split under test: `*-destroy` is hard-blocked unconditionally; `*-apply`
# is a non-blocking nudge (RULE1_TERRANIX_APPLY_BLOCKING = false). Both halves
# are asserted, because a rule that only ever proves its BLOCK cases cannot
# tell you it has stopped approving the things it should approve.
#
# Every case was `mcp-public-*` until 2026-10-02: that stack and its five apps
# were deleted (PR #737), so those cases asserted a verdict on a flake attr that
# no longer resolves. They are re-pointed at `cf-tunnel-*` — the only surviving
# terranix family with both an apply and a destroy app — keeping each evasion
# shape (quoted ref, `github:` ref, a `secret exec` prefix, extra tofu args, a
# compound command) rather than dropping coverage with the names.
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

echo "== must BLOCK (teardown: no readable plan, and it drops nixpi's only remote ingress) =="
ck block "$NR .#cf-tunnel-destroy"
ck block "$NR \".#cf-tunnel-destroy\""
ck block "$NR github:kattakath/nix-config#cf-tunnel-destroy"
ck block "secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:nixpi-tunnel -- $NR .#cf-tunnel-destroy"

echo "== must stay APPROVED (apply: the wrapper's own guards + a plan run first) =="
ck approve "$NR .#cf-tunnel-apply"
ck approve "$NR .#cf-tunnel-apply -- -parallelism=2 -auto-approve"
ck approve "secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:nixpi-tunnel -- $NR .#cf-tunnel-apply"
ck approve "$NR github:kattakath/nix-config#cf-tunnel-apply"

echo "== an apply must not launder a destroy sitting next to it =="
ck block "$NR .#cf-tunnel-apply $AND $NR .#cf-tunnel-destroy"

echo "== read-only and unrelated apps are untouched by either half =="
ck approve "$NR .#cf-tunnel-plan"
ck approve "$NR .#nixvm"

echo "-- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
