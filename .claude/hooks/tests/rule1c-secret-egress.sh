#!/usr/bin/env bash
# Rule 1c cases. Kept in a FILE, not on a command line: the block/ cases are
# execution-shaped by construction, so putting them in an argv would trip the
# very rule under test.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

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

echo "== must BLOCK (the value would reach stdout) =="
ck block 'secret reveal K'
ck block 'echo $(secret reveal K)'
ck block 'X=`secret reveal K`'
ck block '/usr/bin/security find-generic-password -a x -s K -w'
ck block 'v=$(security find-generic-password -s K -w)'
ck block 'true && secret reveal K'
ck block 'security find-generic-password -s K -g'

echo "== must BLOCK: an escaped BACKSLASH before a REAL pipe is not an escaped pipe =="
# The bypass a bare lookbehind allows: here `\\` is a literal backslash and the
# `|` after it is a genuine pipeline. A lookbehind cannot count backslashes, so
# the command is matched against a pair-collapsed copy instead.
# TIGHT shape — the backslash must be IMMEDIATELY before the separator, or the
# lookbehind never engaged and the case proves nothing. Here the literal text is
# `a` backslash backslash pipe: an escaped backslash, then a real pipeline.
ck block 'printf a\\| secret reveal K'
ck block 'echo x\\;secret reveal K'
# Loose shape (space before the pipe) — blocked by the plain separator branch.
ck block 'printf "a\\\\" | secret reveal K'

echo "== must APPROVE: an ESCAPED pipe is a regex alternation, not a pipe =="
# A grep alternation blocked a search for this rule's own call sites.
ck approve "grep -rn 'secret get \|secret reveal ' ."
ck approve "rg 'foo\|secret reveal' docs/"

echo "== must APPROVE (text about it, or a non-printing verb) =="
ck approve 'git commit -m "secret reveal is the printing verb"'
ck approve "grep -rn 'secret reveal' docs/"
ck approve 'echo "use secret reveal only as a last resort"'
ck approve 'secret copy K'
ck approve 'secret fp K'
ck approve 'secret exec K -- glab auth status'
ck approve 'secret ls --long'
ck approve 'pbpaste | secret set K'
ck approve 'security find-generic-password -s K'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
