#!/usr/bin/env bash
# stop-gate.js must FAIL CLOSED when it cannot talk to git.
#
# Until 2026-09-16 the opening `git rev-parse --is-inside-work-tree` was wrapped
# in a catch that called approve() on ANY failure. Measured that day in a
# cross-owned checkout — a tree owned by one account, worked in as another — git
# refuses with "detected dubious ownership in repository", the catch swallowed
# it, and git-purity, the nix syntax check and the flake check were all reported
# GREEN WITHOUT RUNNING. A gate that cannot fire is worse than no gate: with no
# gate you at least know you are unprotected.
#
# The split under test: "not a git repository" is the legitimate no-op and still
# approves; every other git failure blocks and says no gate ran.
#
# The trigger here is a malformed global git CONFIG rather than a cross-owned
# tree, because ownership cannot be forged without a second uid and this suite
# has to pass in CI too. It exercises the same branch: a git failure whose
# message is not "not a git repository". Probed 2026-09-16 — a malformed .git
# file, an empty .git directory and a bogus GIT_DIR ALL report "not a git
# repository" and so correctly still approve; a bad config line does not.
# The real dubious-ownership case was verified by hand against the cross-owned
# clone at /Users/izzy/…/nix-config the same day.
set -uo pipefail
H=.claude/hooks/stop-gate.js
pass=0; fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# GIT_CONFIG_GLOBAL is passed through so a case can break git itself.
decide() { # decide <project-dir> [bad-config]
  printf '{}' \
    | CLAUDE_PROJECT_DIR="$1" GIT_CONFIG_GLOBAL="${2:-/dev/null}" node "$H" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("decision","?"))' 2>/dev/null
}
ck() { # ck <want> <dir> <label> [bad-config]
  got="$(decide "$2" "${4:-/dev/null}")"
  if [ "$got" = "$1" ]; then printf '  ok    %-8s %s\n' "$got" "$3"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "$3"; fail=$((fail+1)); fi
}

echo "== must APPROVE: genuinely not a git repository (the legitimate no-op) =="
mkdir -p "$TMP/plain"
ck approve "$TMP/plain" "a directory with no .git at all"

echo "== must APPROVE: git is confused but still says \"not a git repository\" =="
mkdir -p "$TMP/broken"
printf 'gitdir: /nonexistent/nowhere\n' > "$TMP/broken/.git"
ck approve "$TMP/broken" "a malformed .git file — git still calls it not-a-repo"

echo "== must BLOCK: git fails for any OTHER reason =="
printf '[bad\n' > "$TMP/badcfg"
ck block "$TMP/plain" "a broken git config (stands in for dubious ownership)" "$TMP/badcfg"

echo "== the block must SAY that nothing was checked =="
reason=$(printf '{}' | CLAUDE_PROJECT_DIR="$TMP/plain" GIT_CONFIG_GLOBAL="$TMP/badcfg" node "$H" 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)
case "$reason" in
  *"NOTHING was checked"*) printf '  ok    reason   names the unchecked gates\n'; pass=$((pass+1));;
  *) printf '  FAIL  reason did not say nothing was checked: %.60s\n' "$reason"; fail=$((fail+1));;
esac

echo "== approve() must not FALL THROUGH into block() =="
# Regression guard for the shape, not just the outcome. The catch used to be a
# bare `if (...) { approve(); }` followed unconditionally by block(). That was
# harmless ONLY because approve() ends in process.exit(0) — control flow
# depending on a side effect in another function. Make approve() returnable
# (unit-testing it is the obvious reason) and every non-git directory would get
# a hard block instead of the legitimate no-op. Asserting exactly ONE decision
# object on stdout catches the fallthrough directly, and would still catch it if
# approve() ever stopped exiting.
raw=$(printf '{}' | CLAUDE_PROJECT_DIR="$TMP/plain" GIT_CONFIG_GLOBAL=/dev/null node "$H" 2>/dev/null)
n=$(printf '%s' "$raw" | grep -o '"decision"' | wc -l | tr -d ' ')
if [ "$n" = "1" ]; then
  printf '  ok    one      exactly one decision object on the approve path\n'; pass=$((pass+1))
else
  printf '  FAIL  want=1 got=%s  stdout: %.60s\n' "$n" "$raw"; fail=$((fail+1))
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
