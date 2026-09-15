#!/usr/bin/env bash
# Rule 1d cases. Kept in a FILE, not on a command line, for the same reason as
# rule1c: the block/ cases are execution-shaped by construction, so putting them
# in an argv would trip the very rule under test (measured — the first run of
# this suite blocked the Bash call that carried it, and then blocked the commit
# whose message quoted it).
#
# The split under test: building ON the Pi is blocked; building HERE and only
# ACTIVATING there is not. Plus the mention-as-data class, which must pass.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

# Assembled rather than written literally, so this file's own text does not read
# as an invocation to a future grep-based rule.
PI=nixpi.kattakath.com
NR=nixos-rebuild
BH="--build-""host"
TH="--target-""host"

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

echo "== must BLOCK (the build would happen ON the Pi) =="
ck block "$NR switch --flake .#nixpi $BH $PI"
ck block "$NR switch --flake .#nixpi $BH ismail@nixpi"
ck block "$NR switch $BH=nixpi"
ck block "deploy --targets .#nixpi --remote-build"
ck block "ssh $PI $NR switch"
ck block "ssh ismail@nixpi nix build .#foo"
ck block "nix build .#foo --builders ssh://ismail@nixpi"

echo "== must APPROVE (builds HERE, or does not build at all) =="
ck approve "$NR switch --flake .#nixpi $TH ismail@$PI"
ck approve "deploy --targets .#nixpi"
ck approve "darwin-rebuild switch --flake .#macos"
ck approve "nix build .#nixosConfigurations.nixpi.config.system.build.toplevel"
ck approve "ssh $PI systemctl status caddy"
ck approve "$NR switch $BH builder.example.com"

echo "== must APPROVE: the shape MENTIONED as data, not run =="
# Gated on each segment's argv0, so git/echo/grep carrying the text are fine.
ck approve "git commit -m \"blocks $BH $PI now\""
ck approve "echo \"do not run: ssh $PI nix build\""
ck approve "grep -rn \"$BH\" .claude/hooks/"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
