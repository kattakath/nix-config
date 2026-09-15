#!/usr/bin/env bash
# Orchestrator: refresh art -> decide -> render -> publish atomically.
#
# ATOMIC WRITE IS LOAD-BEARING. Übersicht `cat`s this file on its own schedule,
# so a partial write would render a half-document. Rename(2) within one
# filesystem is atomic, so the widget only ever sees a complete file.
#
# NEVER leaves a stale card on screen: every failure path below still publishes
# something — the art fallback or the neutral string — because a confidently
# wrong instruction that persists for hours is worse than no instruction.
set -euo pipefail

OUT="${NRT_OUT:?NRT_OUT required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NRT_ART_FILE="${NRT_ART_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/ubersicht/art.jpg}"

mkdir -p "$(dirname "$OUT")"

"$HERE/art.sh" || true

# Gate the expensive half. probe.sh exits 9 when no source moved since last run;
# in that case the existing card is still correct, so leave it alone and spend
# nothing. Measured: the model call is ~$3.45 unguarded, and most 20-minute
# windows contain no new signal at all.
STATE="${NRT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/next-right-thing/state.json}"
probe_rc=0
"$HERE/probe.sh" >/dev/null 2>&1 || probe_rc=$?
case "$probe_rc" in
  0) : ;;                       # something moved — fall through and re-decide
  9) printf '%s  no change — card left in place, no model call\n' "$(date -Iseconds)"
     exit 0 ;;
  *) # A CRASHED probe is not the same as "nothing changed". Failing closed here
     # would freeze the card forever behind a broken probe and look like calm.
     printf '%s  probe failed (rc=%s) — deciding anyway\n' "$(date -Iseconds)" "$probe_rc" >&2 ;;
esac

verdict="$("$HERE/decide.sh" 2>/dev/null || printf '{"found":false,"degraded":["ranker: crashed"]}')"

# Merge the probe's own coverage findings into the verdict. The model can only
# report sources it was ABLE to reach; a grant that is dead before the call is
# invisible to it, and silently shrunken coverage is the failure this whole
# design most needs to surface.
probe_deg="$(jq -c '(.degraded // [])' "$STATE" 2>/dev/null || echo '[]')"
verdict="$(printf '%s' "$verdict" | jq -c --argjson p "$probe_deg" \
  '.degraded = ((.degraded // []) + $p | unique)' 2>/dev/null || printf '%s' "$verdict")"

# Next to $OUT, not in $TMPDIR: rename(2) is atomic only WITHIN a filesystem,
# and macOS puts $TMPDIR on a different volume from $HOME — so a $TMPDIR temp
# would make `mv` a copy, reintroducing the torn-read this guards against.
# Explicit XXXXXX because GNU mktemp shadows BSD here and rejects `-t name`.
# Persist the verdict itself, not just the rendered HTML. The menu bar plugin
# reads THIS — so a second surface costs a `cat`, never a second model call, and
# a restyle re-renders with no spend at all.
VERDICT_FILE="${NRT_VERDICT:-$(dirname "$OUT")/verdict.json}"
vtmp="$(mktemp "$(dirname "$VERDICT_FILE")/.verdict.XXXXXX")"
printf '%s\n' "$verdict" > "$vtmp"; chmod 600 "$vtmp"; mv -f "$vtmp" "$VERDICT_FILE"

tmp="$(mktemp "$(dirname "$OUT")/.nrt-html.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

if printf '%s' "$verdict" | "$HERE/render.sh" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  chmod 600 "$tmp"
  mv -f "$tmp" "$OUT"
  printf '%s  published  %s\n' "$(date -Iseconds)" \
    "$(printf '%s' "$verdict" | jq -c '{found, urgency: (.urgency // "-")}')"
else
  printf '%s  render FAILED, previous card left in place\n' "$(date -Iseconds)" >&2
  exit 1
fi
