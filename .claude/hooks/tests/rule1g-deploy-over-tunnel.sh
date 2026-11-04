#!/usr/bin/env bash
# Rule 1g cases: a nixpi deploy WITHOUT `--hostname` rides the Cloudflare tunnel
# it may restart (2026-10-21 self-cut, 13 min down), so it NUDGES.
#
# The rule never changes a DECISION — every case here is `approve` — so a
# decision-only `ck` would pass identically with the rule deleted. The NUDGE is
# what changes, so that is what gets asserted, in both directions (the same
# reason rule1-terranix-apply-vs-destroy.sh asserts its apply nudge).
#
# Same file-not-argv discipline as rule1c/rule1d: the strings below are
# execution-shaped.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

DEP="dep""loy"
ND="nix develop -""c"
AND="&""&"

nudge() { # nudge <cmd> -> "<decision>|<systemMessage>"
  python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | node "$H" 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("decision","?")+"|"+d.get("systemMessage",""))' 2>/dev/null
}
ckn() { # ckn <cmd> — must APPROVE and carry the Rule 1g nudge
  got="$(nudge "$1")"
  case "$got" in
    "approve|"*"--hostname <pi-lan-ip>"*) printf '  ok    nudged   %s\n' "$1"; pass=$((pass+1)) ;;
    *) printf '  FAIL  want approve+nudge, got %s  <- %s\n' "$got" "$1"; fail=$((fail+1)) ;;
  esac
}
ckq() { # ckq <cmd> — must APPROVE with NO Rule 1g nudge
  got="$(nudge "$1")"
  case "$got" in
    "approve|"*"pi-lan-ip"*) printf '  FAIL  unexpected nudge: %s  <- %s\n' "$got" "$1"; fail=$((fail+1)) ;;
    "approve|"*) printf '  ok    quiet    %s\n' "$1"; pass=$((pass+1)) ;;
    *) printf '  FAIL  want approve, got %s  <- %s\n' "$got" "$1"; fail=$((fail+1)) ;;
  esac
}

echo "== without --hostname: NUDGE (the documented form and its spellings) =="
ckn "$ND $DEP --targets .#nixpi"
ckn "$DEP --targets .#nixpi"
ckn "$DEP .#nixpi"
ckn "$DEP --targets .#nixpi.system"
ckn "$DEP --targets '.#nixpi'"
ckn "$DEP --targets github:kattakath/nix-config#nixpi"
ckn "$DEP --dry-activate --targets .#nixpi"
# Extra nix build args after `--` are not deploy's own: a hostname there is not one.
ckn "$DEP --targets .#nixpi -- --hostname x"
ckn "$ND $DEP --targets .#nixpi -- --narinfo-cache-negative-ttl 0"
ckn "cd /tmp $AND $ND $DEP --targets .#nixpi"

echo "== with --hostname: SILENT (the LAN path) =="
ckq "$ND $DEP --targets .#nixpi --hostname 192.168.0.42"
ckq "$DEP --hostname 192.168.0.42 --targets .#nixpi"
ckq "$DEP --targets .#nixpi --hostname=192.168.0.42"
ckq "$ND $DEP .#nixpi --hostname nixpi.local"

echo "== a non-nixpi target: SILENT =="
ckq "$DEP --targets .#nixvm"
ckq "$DEP --targets .#nixpi-staging"
ckq "$DEP --targets .#othernode.system"

echo "== a MENTION is not a run: SILENT =="
ckq "git commit -m \"docs: $ND $DEP --targets .#nixpi\""
ckq "echo \"$DEP --targets .#nixpi\""
ckq "grep -rn '$DEP --targets .#nixpi' docs/"

echo "== Rule 1d still wins over the nudge =="
got="$(nudge "$DEP --targets .#nixpi --remote-build")"
case "$got" in
  block\|*) printf '  ok    block    remote-build\n'; pass=$((pass+1)) ;;
  *) printf '  FAIL  want block, got %s\n' "$got"; fail=$((fail+1)) ;;
esac

echo "-- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
