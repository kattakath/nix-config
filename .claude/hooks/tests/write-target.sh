#!/usr/bin/env bash
# pretooluse-write-target.js cases: a Write/Edit ASKS on OS system paths, a literal
# '../' escaping the project, and login/credential files; it says nothing (normal
# permission flow) on the session scratchpad, sibling repos and data folders.
# A gh-clones-<session> dir under /var/folders is a system root like any other
# since 2026-11-02 (its carve-out went with the disabled gh-cli plugin). A malformed payload must exit 0 with no output (fail open).
set -uo pipefail
H=.claude/hooks/pretooluse-write-target.js
P=/Users/x/Developer/github.com/o/repo
pass=0; fail=0

decide() { # decide <file_path>
  out="$(python3 -c 'import json,sys;print(json.dumps({"tool_input":{"file_path":sys.argv[1]}}))' "$1" \
    | HOME=/Users/x CLAUDE_PROJECT_DIR="$P" node "$H" 2>/dev/null)"
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo "?"
}
ck() { # ck <want> <path>
  got="$(decide "$2")"
  if [ "$got" = "$1" ]; then printf '  ok    %-5s %s\n' "$got" "$2"; pass=$((pass+1))
  else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "$2"; fail=$((fail+1)); fi
}

echo "== must ASK =="
ck ask /tmp/skills-purge/purge.py
ck ask /private/tmp/x.txt
ck ask /etc/hosts
ck ask /var/log/x
ck ask /Library/LaunchDaemons/x.plist
ck ask /var/folders/ns/abc123/T/gh-clones-sess42/repo/README.md
ck ask /Users/x/.zshrc
ck ask /Users/x/.ssh/config
ck ask /Users/x/Library/LaunchAgents/evil.plist
ck ask /Users/x/.config/git/config
ck ask "$P/../../../../../.profile"
# APFS is case-insensitive: a case variant names the same file. The hook folds case
# on darwin only (Linux filesystems are case-sensitive, and CI runs on Linux).
if [ "$(uname -s)" = Darwin ]; then
  ck ask /Users/x/.ZSHRC
  ck ask /ETC/hosts
  ck ask /Users/x/library/launchagents/evil.plist
else
  ck none /Users/x/.ZSHRC
fi

echo "== must stay SILENT =="
ck none /private/tmp/claude-501/-Users-x-repo/0f3a-session/scratchpad/notes.md
ck none /tmp/claude-501/-Users-x-repo/0f3a-session/scratchpad/wt/file.nix
ck none "$P/modules/home/default.nix"
ck none /Users/x/Developer/github.com/other/skills/plugins/a.js
ck none /Users/x/Downloads/report.md
ck none /Users/x/Library/CloudStorage/GoogleDrive-a/My\ Drive/f.md
ck none /Users/x/.claude/plans/p.md
ck none "$P/docs/../CLAUDE.md"

echo "== a symlink into a system path is judged by its target =="
link="$PWD/.write-target-test-link"
rm -f "$link"; ln -s /etc "$link"
out="$(python3 -c 'import json,sys;print(json.dumps({"tool_input":{"file_path":sys.argv[1]}}))' "$link/hosts" \
  | CLAUDE_PROJECT_DIR="$PWD" node "$H" 2>/dev/null)"
rm -f "$link"
case "$out" in *'"ask"'*) echo "  ok    ask   symlink -> /etc"; pass=$((pass+1));;
  *) echo "  FAIL  symlink -> /etc not asked: $out"; fail=$((fail+1));; esac

echo "== a symlink planted in the allowlisted scratchpad still asks =="
# A real allowlist-shaped path (claude-<digits>/<slug>/<session>/scratchpad), so the
# case proves the allowlist is bypassed, not merely missed.
sp="/tmp/claude-9$$${RANDOM}"
mkdir -p "$sp/proj/sess/scratchpad"
touch "$sp/proj/sess/scratchpad/plain.md"
out0="$(python3 -c 'import json,sys;print(json.dumps({"tool_input":{"file_path":sys.argv[1]}}))' "$sp/proj/sess/scratchpad/plain.md" \
  | CLAUDE_PROJECT_DIR="$PWD" node "$H" 2>/dev/null)"
if [ -z "$out0" ]; then echo "  ok    none  real scratchpad file (control)"; pass=$((pass+1))
else echo "  FAIL  real scratchpad file asked: $out0"; fail=$((fail+1)); fi
ln -s /etc "$sp/proj/sess/scratchpad/sneaky"
out="$(python3 -c 'import json,sys;print(json.dumps({"tool_input":{"file_path":sys.argv[1]}}))' "$sp/proj/sess/scratchpad/sneaky/hosts" \
  | CLAUDE_PROJECT_DIR="$PWD" node "$H" 2>/dev/null)"
rm -rf "$sp"
case "$out" in *'"ask"'*) echo "  ok    ask   scratchpad symlink -> /etc"; pass=$((pass+1));;
  *) echo "  FAIL  scratchpad symlink -> /etc not asked: $out"; fail=$((fail+1));; esac

echo "== fail open on a malformed payload =="
out="$(printf 'not json' | node "$H")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then echo "  ok    fail-open"; pass=$((pass+1))
else echo "  FAIL  rc=$rc out=$out"; fail=$((fail+1)); fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
