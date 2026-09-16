#!/usr/bin/env bash
# Rule 1d cases. Kept in a FILE, not on a command line, for the same reason as
# rule1c: the block/ cases are execution-shaped by construction, so putting them
# in an argv would trip the very rule under test (measured — the first run of
# this suite blocked the Bash call that carried it, and then blocked the commit
# whose message quoted it; adding the wrapper cases below blocked it a third
# time, which is why `&&` is assembled too).
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
SH=ba"sh"
DC="-""c"
LC="-l""c"          # the combined-flag spelling, e.g. a login shell
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

echo "== must BLOCK (the build would happen ON the Pi) =="
ck block "$NR switch --flake .#nixpi $BH $PI"
ck block "$NR switch --flake .#nixpi $BH ismail@nixpi"
ck block "$NR switch $BH=nixpi"
ck block "deploy --targets .#nixpi --remote-build"
ck block "ssh $PI $NR switch"
ck block "ssh ismail@nixpi nix build .#foo"
ck block "nix build .#foo --builders ssh://ismail@nixpi"

echo "== must BLOCK through a wrapper (the 2026-09-16 bypass class) =="
# argv0 used to resolve to the WRAPPER, so every per-argv0 rule fell through to
# `default: false` and the guard approved a build on the SD card.
ck block "$SH $DC '$NR switch --flake .#nixpi $BH $PI'"
ck block "/bin/$SH $LC \"ssh nixpi nix build .#foo\""
ck block "env $NR switch $BH=nixpi"
ck block "sudo -u ismail $NR switch $BH=nixpi"
# A payload containing `&&` proves the wrapper's payload is re-segmented.
ck block "$SH $DC 'true $AND nix build .#foo --builders ssh://nixpi'"
# A QUOTED payload on a remote shell. The old splitter was quote-blind and the
# ssh regex stopped at `[^\n|;&]`, so the `&&` inside the quotes cut the match
# short and this was APPROVED — a build on the SD card.
ck block "ssh $PI 'true $AND nix build .#foo'"
# A REAL second line that RUNS the shape (as opposed to quoting it) still blocks.
ck block "echo hi
$SH $DC '$NR switch $BH nixpi'"

echo "== must APPROVE (builds HERE, or does not build at all) =="
ck approve "$NR switch --flake .#nixpi $TH ismail@$PI"
ck approve "deploy --targets .#nixpi"
ck approve "darwin-rebuild switch --flake .#macos"
ck approve "nix build .#nixosConfigurations.nixpi.config.system.build.toplevel"
ck approve "ssh $PI systemctl status caddy"
ck approve "$NR switch $BH builder.example.com"
ck approve "$SH $DC '$NR switch --flake .#nixpi $TH ismail@$PI'"
ck approve "$SH $DC 'echo hi'"

echo "== must APPROVE: the shape MENTIONED as data, not run =="
# Gated on each segment's argv0, so git/echo/grep carrying the text are fine.
ck approve "git commit -m \"blocks $BH $PI now\""
ck approve "echo \"do not run: ssh $PI nix build\""
ck approve "grep -rn \"$BH\" .claude/hooks/"
# A wrapper quoted INSIDE a message is part of that message's segment, so it is
# never mistaken for one that would RUN.
ck approve "git commit -m \"$SH $DC '$NR switch $BH nixpi' is blocked\""
# The MULTI-LINE version, which is the shape this repo actually writes. Until
# quote-aware splitting (2026-09-16) the body's newline was read as a command
# boundary, so this exact commit message was BLOCKED — the third time this rule
# would have blocked its own carrier commit.
ck approve "git commit -m \"fix the guard

$SH $DC '$NR switch $BH nixpi' is blocked now\""

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
