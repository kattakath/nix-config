#!/usr/bin/env bash
# Rule 1c cases. Kept in a FILE, not on a command line: the block/ cases are
# execution-shaped by construction, so putting them in an argv would trip the
# very rule under test.
set -uo pipefail
H=.claude/hooks/pretooluse-bash-guard.js
pass=0; fail=0

raw() {
  python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | node "$H" 2>/dev/null
}
decide() { raw "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("decision","?"))' 2>/dev/null; }
ck() { # ck <want> <cmd>
  got="$(decide "$2")"
  if [ "$got" = "$1" ]; then printf '  ok    %-8s %s\n' "$got" "$2"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "$2"; fail=$((fail+1)); fi
}

# A THROW is not visible in `decision` alone: the file's own catch-all emits
# {"decision":"approve"} with a "pretooluse-bash-guard error (ignored)" message,
# so a crashed guard is indistinguishable from a healthy approval unless the
# systemMessage is read. That exact silent disarm happened on 2026-09-15. So
# nothrow() asserts a real decision AND the absence of that marker — the shape
# every malformed-input case below needs.
nothrow() { # nothrow <label> <cmd>
  got="$(raw "$2" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("NO-JSON"); raise SystemExit
msg = d.get("systemMessage") or ""
print("THREW" if "error (ignored)" in msg else (d.get("decision") or "NO-DECISION"))
' 2>/dev/null)"
  case "$got" in
    approve | block) printf '  ok    %-8s %s\n' "$got" "$1"; pass=$((pass + 1)) ;;
    *) printf '  FAIL  %-8s %s\n' "$got" "$1"; fail=$((fail + 1)) ;;
  esac
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

echo "== must BLOCK through a WRAPPER PREFIX (the 2026-10-02 bypass class) =="
# Measured: EVERY row below was APPROVED before the per-segment half landed.
# CMD_POS anchors at start-of-string or after a separator, and a wrapper token
# is neither, so one `sudo` walked the leak straight past the rule. For the
# subset Claude Code's own permission matcher strips (timeout/time/nice/command)
# this hook was WEAKER than the `Bash(secret reveal *)` deny rule it backstops.
ck block 'sudo secret reveal K'
ck block 'sudo -u ismail secret reveal K'   # the flag's VALUE must not become argv0
ck block 'sudo -E secret reveal K'
ck block 'sudo -n secret reveal K'          # -n takes NO value — the next token IS the command
ck block 'env FOO=1 secret reveal K'
ck block 'env secret reveal K'
ck block 'timeout 5 secret reveal K'        # the duration is the wrapper's own argument
ck block 'timeout 0.5s secret reveal K'
ck block 'timeout --preserve-status 5 secret reveal K'
ck block 'time secret reveal K'
ck block 'nice secret reveal K'
ck block 'nice -n 5 secret reveal K'
ck block 'nohup secret reveal K'
ck block 'stdbuf -oL secret reveal K'
ck block 'command secret reveal K'
ck block 'builtin secret reveal K'
ck block 'noglob secret reveal K'
ck block 'xargs secret reveal'
ck block 'xargs -n 1 secret reveal'
ck block 'xargs -I {} secret reveal {}'
ck block 'nix develop -c secret reveal K'
ck block 'nix develop --command secret reveal K'
ck block 'nix develop .#default -c secret reveal K'
ck block 'sudo timeout 5 env FOO=1 secret reveal K'   # stacked

echo "== must BLOCK through shell indirection (the sh -c unwrap, reused) =="
ck block "sh -c 'secret reveal K'"
ck block 'bash -lc "secret reveal K"'
ck block 'sudo bash -c "secret reveal K"'
ck block 'setsid sh -c "secret reveal K"'
ck block 'eval "secret reveal K"'
ck block 'eval secret reveal K'

echo "== the security(1) path, same prefixes =="
ck block 'sudo security find-generic-password -s K -w'
ck block 'env X=1 security find-generic-password -s K -w'
ck block 'timeout 5 security find-internet-password -s K -g'
ck block 'sh -c "security find-generic-password -s K -w"'

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

echo "== must APPROVE: a SEARCH whose own pattern names this rule =="
# The exact class that broke this rule twice — it blocked its own commit, then
# blocked the command that tried to fix it. A pattern is data, never a command,
# and widening the rule must never undo that. Through `xargs` too: that wrapper
# is now peeled, so the peel must leave `grep` as the command and the pattern as
# its argument. `git ls-files | xargs grep` is the shape this repo actually
# writes, because a bare `grep -r` triples counts here (.claude/worktrees/ holds
# full file copies).
ck approve 'grep -rn "secret reveal" .claude/hooks/pretooluse-bash-guard.js'
ck approve 'git grep -n "secret reveal"'
ck approve 'git ls-files | xargs grep -n "secret reveal"'
ck approve 'git ls-files | xargs rg "security find-generic-password"'
ck approve 'xargs -n 1 grep -l "secret reveal"'
# Editing, staging and committing the hook itself, and reading the rule's lines.
ck approve 'git add .claude/hooks/pretooluse-bash-guard.js'
ck approve 'git commit -m "claude: make secret reveal detection survive a wrapper prefix"'
ck approve 'sed -n "250,300p" .claude/hooks/pretooluse-bash-guard.js'

echo "== must APPROVE: a \`secret\` subcommand that prints NO value =="
# `secret copy` is the SANCTIONED handover shape — it hands the value to the
# human via a concealed pasteboard, and the block message recommends it by name.
# Blocking it would break the approved workflow, so a wrapper in front of a
# non-printing verb must not promote it either.
ck approve 'secret set K'
ck approve 'secret ls'
ck approve 'secret rm K'
ck approve 'secret bind K'
ck approve 'secret unbind K'
ck approve 'sudo secret set K'
ck approve 'timeout 5 secret copy K'
ck approve 'xargs secret copy'
ck approve 'command -v secret'

echo "== must APPROVE: security(1) WITHOUT -w/-g prints attributes, not the value =="
ck approve 'sudo security find-generic-password -a x -s K'
ck approve 'security find-internet-password -s example.com'
ck approve 'security list-keychains'

echo "== malformed input must still DECIDE, and must not THROW (a throw fails OPEN) =="
# The peel loop and the payload unwrap are new parsing, and parsing is where a
# crash comes from. A crash here is a SILENT DISARM of every rule at once, so
# each case asserts a real decision and the absence of the catch-all's marker.
nothrow 'empty command' ''
nothrow 'whitespace only' '   '
nothrow 'lone single quote' "'"
nothrow 'lone double quote' '"'
nothrow 'unterminated substitution' 'echo $(secret reveal K'
nothrow 'unterminated backtick' 'echo `secret reveal K'
nothrow 'trailing backslash' 'secret reveal K\'
nothrow 'separators only' ';;||&&(('
nothrow 'bare wrapper, nothing after' 'sudo'
nothrow 'wrapper flag, nothing after' 'sudo -u'
nothrow 'unterminated quoted payload' "sh -c 'secret reveal K"
nothrow 'nested quote soup' 'sh -c "sh -c '"'"'sh -c \"true\"'"'"'"'
# Length, to prove the peel loop and the lazy `nix develop` regex do not blow
# up: a long un-peelable token, a long `nix develop` with no `-c` to find, and a
# deep wrapper stack (which the 256-iteration bound covers with room to spare).
nothrow '200k-char single token' "$(python3 -c 'print("x" * 200000)')"
nothrow '4000-token nix develop, no -c' "$(python3 -c 'print("nix develop " + "tok " * 4000)')"
nothrow '64 stacked wrappers' "$(python3 -c 'print("sudo " * 64 + "true")')"
# And the stack must still be SEEN through, not merely survived.
ck block "$(python3 -c 'print("sudo " * 64 + "secret reveal K")')"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
