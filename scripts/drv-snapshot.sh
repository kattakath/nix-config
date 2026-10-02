#!/usr/bin/env bash
# drv-snapshot.sh — the acceptance test for the ADR-002 collapse waves.
#
# A wave is allowed to move code; it is NOT allowed to change what the fleet
# BUILDS. This captures the derivation identity of every output, so a wave can
# be accepted on `diff baseline after` being empty rather than on reading a
# 4,000-line patch and hoping.
#
# It used to ALSO evaluate the private nix-personal composition, because this
# repo's outputs could be byte-identical while that flake broke on a seam only
# declared here; nix-personal was retired 2026-09-15 and its values folded in, so
# that leg is gone. `--compare` therefore derives its file set from the capture it
# has just taken rather than from a second hand-maintained list, so a file this
# script stopped writing (a pre-retirement baseline's `personal.tsv`) cannot make
# a clean run report REJECTED.
#
# WHY THIS IS NOT A FLAKE PACKAGE. Adding it to `packages` would add a row to
# `nix flake show`, i.e. perturb the very baseline it exists to measure. It is a
# dev tool, not a fleet artifact, so it stays a plain script.
#
# It is still SHELLCHECKED, by `checks.<system>.drv-snapshot-lint`
# (modules/parts/checks.nix) — not, as this header said until 2026-10-02, by the
# operator remembering to run `nix develop -c shellcheck` by hand. Unpackaged does
# not have to mean ungated: that check shellchecks this file as a source path, so
# nothing is added to `packages` and its drvPath tracks this file alone rather than
# `self`. Expect one `checks:<system>:drv-snapshot-lint` row per system in
# outputs.tsv below; it moves only when this file does.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=""
COMPARE=""

usage() {
  cat >&2 <<'USAGE'
usage: drv-snapshot.sh --out DIR        capture a snapshot into DIR
       drv-snapshot.sh --compare DIR    capture to a temp dir and diff against DIR
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --compare) COMPARE="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$OUT" ] || [ -n "$COMPARE" ] || usage

# ---- The honest exclusion list -------------------------------------------
# These change on EVERY commit for reasons that have nothing to do with a wave,
# and a harness that flags them gets disabled within a day:
#
#   formatting / ast-grep / userscripts / page-lab / pre-commit — take `self`
#     as a source input, so their drv hash tracks the working tree, not their
#     definition.
#   apps.macos — an activation app built from `self`.
#
# Excluded here means "compared by NAME only": their presence and absence still
# registers, only their hash is ignored.
EXCLUDE_RE='^(formatting|ast-grep|userscripts|page-lab|pre-commit)$'
EXCLUDE_PKG_RE='^macos$'

emit() { # emit <label> <expr>  — prints "label<TAB>drvpath" or "label<TAB>ERROR"
  local label="$1" expr="$2" v
  if v=$(cd "$REPO" && nix eval --raw --impure --expr "$expr" 2>/dev/null); then
    printf '%s\t%s\n' "$label" "$v"
  else
    printf '%s\t<EVAL-FAILED>\n' "$label"
  fi
}

capture() {
  local dir="$1"
  mkdir -p "$dir"

  echo "  flake show ..." >&2
  (cd "$REPO" && nix flake show --json 2>/dev/null) \
    | python3 -c 'import json,sys;json.dump(json.load(sys.stdin),sys.stdout,indent=1,sort_keys=True)' \
    > "$dir/flake-show.json"

  echo "  host toplevels ..." >&2
  {
    emit "darwin:macos" 'let f = builtins.getFlake (toString '"$REPO"'); in f.darwinConfigurations.macos.config.system.build.toplevel.drvPath'
    emit "nixos:nixpi"  'let f = builtins.getFlake (toString '"$REPO"'); in f.nixosConfigurations.nixpi.config.system.build.toplevel.drvPath'
    emit "nixos:nixvm"  'let f = builtins.getFlake (toString '"$REPO"'); in f.nixosConfigurations.nixvm.config.system.build.toplevel.drvPath'
  } | sort > "$dir/hosts.tsv"

  echo "  packages / checks ..." >&2
  : > "$dir/outputs.tsv"
  for cat in packages checks; do
    for sys in aarch64-darwin aarch64-linux; do
      (cd "$REPO" && nix eval --json ".#${cat}.${sys}" \
        --apply 'builtins.mapAttrs (n: v: v.drvPath or "<not-a-drv>")' 2>/dev/null || echo '{}') \
      | python3 -c "
import json,sys,re
ex_c=re.compile('''$EXCLUDE_RE'''); ex_p=re.compile('''$EXCLUDE_PKG_RE''')
d=json.load(sys.stdin)
for k,v in sorted(d.items()):
    skip = ex_c.search(k) or ex_p.search(k)
    print('%s:%s:%s\t%s' % ('$cat','$sys',k,'<excluded-by-design>' if skip else v))
" >> "$dir/outputs.tsv"
    done
  done
  sort -o "$dir/outputs.tsv" "$dir/outputs.tsv"

}

if [ -n "$COMPARE" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "capturing current state ..." >&2
  capture "$tmp"
  rc=0
  n=0
  # The fresh capture is the single source of truth for WHICH files a snapshot
  # consists of, so the compare set cannot drift from what capture() writes.
  for path in "$tmp"/*; do
    [ -f "$path" ] || continue
    f="${path##*/}"
    n=$((n + 1))
    if [ ! -f "$COMPARE/$f" ]; then
      printf '  ABSENT     %s — not in the baseline; re-capture it\n' "$f"; rc=1
    elif diff -u "$COMPARE/$f" "$path" > /dev/null; then
      printf '  IDENTICAL  %s\n' "$f"
    else
      printf '  CHANGED    %s\n' "$f"; rc=1
      diff -u "$COMPARE/$f" "$path" | sed 's/^/      /' || true
    fi
  done
  # Zero comparable files would otherwise print ACCEPTED on having proved nothing.
  if [ "$n" -eq 0 ]; then
    echo "REJECTED: the capture produced no files to compare." >&2
    exit 1
  fi
  [ "$rc" -eq 0 ] && echo "ACCEPTED: every output is derivation-identical." \
                  || echo "REJECTED: see the diff above. A wave must not change what is built."
  exit "$rc"
fi

echo "capturing baseline into $OUT ..." >&2
capture "$OUT"
echo "done: $(wc -l < "$OUT/outputs.tsv" | tr -d ' ') outputs, $(wc -l < "$OUT/hosts.tsv" | tr -d ' ') hosts" >&2
