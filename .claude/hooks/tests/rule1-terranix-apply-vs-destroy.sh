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

# ---- 2026-10-02: the apply rule now covers all FIVE stacks ------------------
# These cases cannot be written with `ck`. Widening the apply regex does not
# change any DECISION — apply was and stays `approve` — so a decision-only
# assertion passes identically before and after the widening and proves nothing.
# What changed is the NUDGE, so that is what gets asserted, in both directions.
nudge() { # nudge <cmd> -> the systemMessage, or "" when there is none
  python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | node "$H" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("systemMessage",""))' 2>/dev/null
}
ckn() { # ckn <substring-that-must-appear> <cmd>
  got="$(nudge "$2")"
  case "$got" in
    *"$1"*) printf '  ok    nudged   %s\n' "$2"; pass=$((pass+1)) ;;
    *) printf '  FAIL  no nudge matching %s  %s\n' "$1" "$2"; fail=$((fail+1)) ;;
  esac
}
ckq() { # ckq <cmd> — must produce NO nudge at all (over-match guard)
  got="$(nudge "$1")"
  if [ -z "$got" ]; then printf '  ok    quiet    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  unexpected nudge: %s  <- %s\n' "$got" "$1"; fail=$((fail+1)); fi
}

echo "== every mutating apply must NUDGE, naming ITS OWN worst case =="
ckn "blanks nixpi's ingress"        "$NR .#cf-tunnel-apply"
ckn "DELETES mail records"          "$NR .#cf-zones-apply"
ckn "auth_domain"                   "$NR .#cf-access-org-apply"
ckn "NO state bucket"               "$NR .#gcp-foundation-apply"
ckn "spend alarm"                   "$NR .#gcp-budget-apply"

echo "== the nudge survives the same evasions the decision does =="
ckn "DELETES mail records" "$NR \".#cf-zones-apply\""
ckn "spend alarm"          "$NR github:kattakath/nix-config#gcp-budget-apply"
ckn "auth_domain"          "secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:api -- $NR .#cf-access-org-apply"

echo "== NO over-match: read-only plans and the two imports stay silent =="
ckq "$NR .#cf-tunnel-plan"
ckq "$NR .#cf-zones-plan"
ckq "$NR .#cf-access-org-plan"
ckq "$NR .#gcp-foundation-plan"
ckq "$NR .#gcp-budget-plan"
# The imports write STATE, never infrastructure — and blocking or nagging them
# would have obstructed the mandatory cf-tunnel-import of 2026-10-02.
ckq "$NR .#cf-tunnel-import"
ckq "$NR .#cf-access-org-import"

echo "-- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
