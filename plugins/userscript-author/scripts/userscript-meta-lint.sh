#!/usr/bin/env bash
# userscript-meta-lint.sh — Greasy Fork readiness lint for Violentmonkey userscripts.
#
# WHY THIS EXISTS. A .user.js is never parsed by a build: a manager copies it into
# extension storage verbatim. So a syntax error ships silently and surfaces as
# Violentmonkey's useless "Syntax error?" toast with no line number, and a missing
# metadata key is only noticed at upload — months after authoring, if ever.
#
# Every rule below is either a parse check or a rule Greasy Fork actually enforces
# (https://greasyfork.org/en/help/code-rules). Sleazy Fork shares the codebase and
# the rule set, so "publishable" needs no per-site variant.
#
#   usage: userscript-meta-lint.sh <file.user.js|dir> [more...]
#
# Exits 0 if everything passes, 1 otherwise. EVERY problem in EVERY file is
# reported in one run — a lint that exits on the first ✘ turns a five-key
# omission into five round trips.

set -uo pipefail

rc=0
found=0
name=""

fail() {
  echo "  ✘ $name: $1" >&2
  rc=1
}

# Only the metadata block, so a @key mentioned in prose or in a regex further down
# the file can neither satisfy nor trip a rule.
meta_has() { printf '%s\n' "$meta" | grep -qE "^// @$1([[:space:]]|$)"; }

lint_file() {
  local f="$1"
  name=$(basename "$f")
  found=1
  echo "checking $name"

  # Parse-only: no execution, so the GM_* globals a userscript relies on are
  # irrelevant — exactly the right depth of check.
  if command -v node >/dev/null 2>&1; then
    node --check "$f" || fail "does not parse (node --check)"
  else
    echo "  … node not on PATH — skipping the syntax check" >&2
  fi

  local meta
  meta=$(sed -n '/^\/\/ ==UserScript==/,/^\/\/ ==\/UserScript==/p' "$f")
  if [ -z "$meta" ]; then
    fail "no ==UserScript== metadata block"
    return
  fi

  # name/namespace/version are Greasy Fork's required set; description is its
  # Functionality rule ("users must know what a script will do before installing
  # it"); match keeps a script from claiming pages it does not serve; license is
  # how Greasy Fork and OpenUserJS read copyright — omit it and OpenUserJS
  # silently implies MIT on the author's behalf. homepageURL/supportURL are what
  # give a published script somewhere to send a bug that is not the author's DMs.
  local k
  for k in name namespace version description license match homepageURL supportURL; do
    meta_has "$k" || fail "missing @$k"
  done

  # Updating is the script manager's job. Greasy Fork STRIPS these on upload,
  # forbids "alternate download URLs", and notes outright that "most user script
  # managers will handle automatic updates, so doing it in the script is
  # unnecessary". Pointed at your own repo they also let a push to the default
  # branch mutate an installed script with no review.
  for k in downloadURL updateURL installURL; do
    ! meta_has "$k" || fail "@$k is banned — stripped on upload, and it lets a push mutate an installed copy"
  done

  # Greasy Fork rejects a @version it cannot order, and warns when one fails to
  # increment. Stricter than Violentmonkey's own grammar on purpose: a plain
  # dotted-numeric is unambiguous to every manager and to humans.
  local ver
  ver=$(printf '%s\n' "$meta" | sed -n 's|^// @version[[:space:]]*\([^[:space:]]*\).*|\1|p' | head -1)
  printf '%s' "$ver" | grep -qE '^[0-9]+(\.[0-9]+)*$' ||
    fail "@version '$ver' is not dotted-numeric (e.g. 2.0.1)"

  # Greasy Fork Code rule: code "must not be obfuscated or minified. Users must be
  # given the opportunity to inspect and understand a script before installing it."
  # A line this long is not hand-written. 500 is >2x the longest line measured
  # across the real scripts this lint was built against (240), so it flags bundler
  # output without arguing about formatting taste.
  local longest
  longest=$(awk '{ if (length > m) m = length } END { print m+0 }' "$f")
  [ "$longest" -le 500 ] ||
    fail "longest line is $longest chars — reads as minified/bundled output, which Greasy Fork rejects"

  # Greasy Fork Code rule: "In the case that a library is included inline, it must
  # include information as to the source of the library (e.g. a comment indicating
  # URL and/or name and version)." Vendoring is the sanctioned alternative to
  # @require, but ONLY with attribution — so if a file announces vendored code,
  # a URL has to be within reach of the announcement.
  local ln
  while IFS=: read -r ln _; do
    [ -n "$ln" ] || continue
    if ! sed -n "${ln},$((ln + 5))p" "$f" | grep -qE 'https?://'; then
      fail "vendored-code marker on line $ln has no source URL within 5 lines — Greasy Fork requires attribution for inline libraries"
    fi
  done < <(grep -niE '(^|[^a-z])vendored|/\*!' "$f" | cut -d: -f1 | sed 's/$/:/')
}

for target in "$@"; do
  if [ -d "$target" ]; then
    shopt -s nullglob
    for f in "$target"/*.user.js; do lint_file "$f"; done
    shopt -u nullglob
  elif [ -f "$target" ]; then
    lint_file "$target"
  else
    echo "✘ no such file or directory: $target" >&2
    rc=1
  fi
done

# A glob that matched nothing would otherwise pass vacuously.
[ "$found" = 1 ] || { echo "no .user.js files found — the path or glob is stale" >&2; exit 1; }
[ "$rc" = 0 ] || { echo "userscript metadata lint FAILED — see ✘ above" >&2; exit 1; }
echo "userscript metadata lint passed"
