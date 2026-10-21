#!/usr/bin/env bash
# Rule 1e cases — dumping the environment, which holds every ambient Keychain
# secret. Kept in a FILE, not on a command line: the block/ cases are
# execution-shaped by construction, so putting them in an argv would trip the
# very rule under test. Nothing here RUNS a case — raw() hands each string to the
# hook as JSON, so no environment is ever printed by this suite.
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

# A THROW is invisible in `decision` alone: the hook's catch-all emits
# {"decision":"approve"} with a "pretooluse-bash-guard error (ignored)" message,
# so a crashed guard looks like a healthy approval unless the systemMessage is
# read (the 2026-09-15 silent disarm). Same assertion as rule1c's suite.
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

echo "== must BLOCK: the 2026-10-21 incident, byte for byte =="
# `^LANG` is a prefix. It matched LANGCHAIN_API_KEY and LANGFUSE_*; a filter
# never rescues a dump, because judging the pattern is what failed.
ck block "env | grep -E '^(LANG|LC_)'"

echo "== must BLOCK: a bare dump =="
ck block 'env'
ck block 'printenv'
ck block 'set'
ck block 'export'
ck block 'export -p'
ck block 'export -n'
ck block 'declare'
ck block 'declare -x'
ck block 'declare -p'
ck block 'declare -px'
ck block 'declare +x'          # quiet in zsh, but DUMPS in bash 3.2 (measured)
ck block 'typeset'
ck block 'typeset -x'
ck block 'typeset -p'
ck block "typeset -m '*'"      # -m takes a PATTERN: a filter over every name
ck block 'typeset -m LANG*'
ck block 'env -0'
ck block 'printenv -0'         # GNU printenv is first on PATH here, and -0 dumps
ck block 'env -u PATH'         # unsets one, prints the rest
ck block 'env FOO=bar'         # an assignment with NO command prints the env
ck block '/usr/bin/env'
ck block '/run/current-system/sw/bin/printenv'

echo "== must BLOCK: piped, sorted, filtered, redirected =="
ck block 'printenv | sort'
ck block 'env | grep KEY'
ck block 'env|grep -i token'
ck block 'set | grep API'
ck block 'export -p | grep KEY'
ck block 'declare -x | head'
ck block 'env | sort | less'
ck block 'env > /tmp/env.txt'  # into a file is no better: the next `cat` prints it
ck block 'env 2>/dev/null | grep LANG'
ck block 'env 2>&1 | grep LANG'   # `&` splits: arrives as a dangling `2>`
ck block 'true && env'
ck block 'cd /tmp; printenv'

echo "== must BLOCK: through a wrapper prefix or shell indirection =="
ck block 'sudo env'
ck block 'sudo -E env'
ck block 'time env'
ck block 'nohup printenv'
ck block 'command printenv'
ck block 'builtin export -p'
ck block 'noglob set'
ck block 'eval env'
ck block 'eval "env | grep LANG"'
ck block 'exec env'
ck block 'timeout 5 env'
ck block 'xargs env'
ck block 'nix develop -c env'
ck block 'nix develop --command printenv'
ck block "sh -c 'env | grep X'"
ck block 'bash -lc "printenv"'
ck block "zsh -c 'export -p'"
ck block 'sudo timeout 5 env FOO=1'   # stacked, and still no command to run

echo "== must BLOCK: a subshell or a group around the dump =="
ck block '(env)'
ck block '(env | grep LANG)'
ck block '{ env; }'

echo "== must APPROVE: reading ONE named variable =="
ck approve 'printenv LANG'
ck approve 'printenv LANG LC_ALL'
ck approve 'printenv HOME | head -1'
ck approve 'echo "$LANG"'
ck approve 'locale'
ck approve 'export -p LANG'      # measured: prints only the named one
ck approve 'declare -p LANG'
ck approve 'typeset -p PATH'
ck approve '[ -n "${LANG+x}" ] && echo set'

echo "== must APPROVE: running a command with a modified environment =="
ck approve 'env FOO=bar make'
ck approve 'env -i PATH=/usr/bin:/bin bash --norc -c true'
ck approve 'env -i'               # an emptied env prints nothing (measured)
ck approve 'env -i FOO=1'
ck approve 'env - FOO=1'
ck approve 'env --ignore-environment FOO=1'
ck approve 'env -u FOO make'
ck approve 'sudo env PATH=/usr/bin make'
ck approve 'nix develop -c env FOO=1 make'
ck approve '/usr/bin/env python3 -V'
ck approve 'env --help'
ck approve 'printenv --version'

echo "== must APPROVE: shell options and declarations that print no values =="
ck approve 'set -euo pipefail'
ck approve 'set -x'
ck approve 'set -o'
ck approve 'set +o pipefail'
ck approve 'set +'
ck approve 'set --'
ck approve 'export FOO=bar'
ck approve 'export PATH="$HOME/bin:$PATH"'
ck approve 'export -f myfn'
ck approve 'declare -f'
ck approve 'declare -F'
ck approve 'typeset -f'
ck approve 'declare -a arr=(1 2)'
ck approve 'readonly'
ck approve 'secret ls --long'

echo "== must APPROVE: the shape MENTIONED as data =="
# A pattern or a message is text, never a command. This is the class that blocked
# Rule 1c's own carrier commit twice; this rule must not repeat it.
ck approve 'git commit -m "claude: block env dumps (env, printenv, set, export -p)"'
ck approve "git commit -m 'env | grep matched LANGCHAIN_API_KEY'"
ck approve 'grep -rn printenv .'
ck approve "grep -rn 'env | grep' docs/"
ck approve "rg -n 'declare -x|typeset -x' ."
ck approve 'git grep -n -e "printenv" -e "export -p"'
ck approve 'git ls-files | xargs grep -n "env"'
ck approve 'echo env'
ck approve 'echo "run env to see it"'
ck approve 'command -v env'
ck approve 'command -V printenv'
ck approve 'type printenv'
ck approve 'which env'
ck approve 'man env'
ck approve 'sed -n "1,40p" .claude/hooks/tests/rule1e-env-dump.sh'
# The heredoc commit shape Claude Code itself writes. The body sits inside the
# outer double quotes, so splitTopLevel keeps it ONE segment whose argv0 is git.
ck approve "$(printf '%s\n' 'git commit -m "$(cat <<'"'"'EOF'"'"'' \
  'claude: Rule 1e blocks environment dumps' '' \
  'env | grep -E LANG matched LANGCHAIN_API_KEY.' 'printenv' 'export -p' 'EOF' ')"')"

echo "== known FALSE POSITIVE, asserted so a change to it is deliberate =="
# A TOP-LEVEL heredoc body is split into lines (splitTopLevel's documented
# limit), so a body line that IS a bare dump verb blocks even though `cat` only
# writes it. The block message routes this case to the Write tool.
ck block "$(printf '%s\n' "cat > /tmp/notes.md <<'EOF'" 'env' 'EOF')"

echo "== malformed input must still DECIDE, and must not THROW (a throw fails OPEN) =="
nothrow 'empty command' ''
nothrow 'lone paren' '('
nothrow 'lone brace' '{'
nothrow 'only redirect' '>'
nothrow 'dangling redirect after env' 'env 2>'
nothrow 'redirect with no command' '2>/dev/null'
nothrow 'unterminated quote after env' "env '"
nothrow 'unterminated payload' "sh -c 'env"
nothrow 'command with no name' 'command -v'
nothrow 'separators only' ';;||&&(('
nothrow '200k-char single token' "$(python3 -c 'print("x" * 200000)')"
nothrow '64 stacked wrappers then env' "$(python3 -c 'print("sudo " * 64 + "env")')"
# The stack must be SEEN through, not merely survived.
ck block "$(python3 -c 'print("sudo " * 64 + "env")')"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
