#!/usr/bin/env bash
# SwiftBar plugin: the ACTIONABLE surface for the next right thing.
#
# WHY THE MENU BAR IS PRIMARY — measured, not preference. This operator runs one
# fullscreen app per desktop. Übersicht draws at kCGDesktopWindowLevel, so a
# fullscreen app covers it completely; it is also setIgnoresMouseEvents:YES, so
# it can never be clicked. The menu bar's 32pt strip is the one surface that
# survives: verified on this Mac, `_HIHideMenuBar = 0` and
# `AppleMenuBarVisibleInFullscreen = 1`.
#
# THIS SCRIPT MAKES NO MODEL CALL. It reads the verdict run.sh already published.
# The launchd agent decides; this just draws. Two surfaces, one decision.
#
# Menu bar width is the real constraint, not fullscreen: this is a notched
# MacBook Pro, status items live right of the notch, and overflow items VANISH
# rather than truncate. So the title is short and `length=` trims it; the full
# sentence lives in the dropdown.
set -euo pipefail

VERDICT="${NRT_VERDICT:-$HOME/.local/share/ubersicht/verdict.json}"

# No verdict yet, or nothing worth saying: emit NOTHING. SwiftBar then shows no
# item at all — zero pixels is the calmest possible "nothing needs you", and it
# costs no design decision.
[ -s "$VERDICT" ] || exit 0

found="$(jq -r '.found // false' "$VERDICT" 2>/dev/null || echo false)"
[ "$found" = "true" ] || exit 0

action="$(jq -r '.action // ""' "$VERDICT")"
source="$(jq -r '.source // ""' "$VERDICT")"
why="$(jq -r '.why // ""' "$VERDICT")"
urgency="$(jq -r '.urgency // "normal"' "$VERDICT")"
url="$(jq -r '.url // ""' "$VERDICT")"
degraded="$(jq -r '(.degraded // []) | length' "$VERDICT")"

[ -n "$action" ] || exit 0

# A pipe would be read as SwiftBar's own param separator and silently eat the
# rest of the line, so strip it from every field that reaches output.
clean() { printf '%s' "$1" | tr '|' '/' | tr -d '\n'; }

glyph="◆"; colour="";        [ "$urgency" = "high" ] && { glyph="●"; colour=" color=#ff2d16"; }

printf '%s %s | length=38%s\n' "$glyph" "$(clean "$action")" "$colour"
printf -- '---\n'
printf '%s\n' "$(clean "$action")"
printf -- '---\n'
[ -n "$source" ] && printf '%s%s | color=#888888 size=12\n' "$(clean "$source")" \
  "$([ -n "$why" ] && printf ' · %s' "$(clean "$why")")"
[ -n "$url" ] && printf 'Open | href=%s\n' "$url"
[ "$degraded" -gt 0 ] 2>/dev/null && \
  printf 'partial coverage · %s source(s) down | color=#cc7722 size=12\n' "$degraded"
exit 0
