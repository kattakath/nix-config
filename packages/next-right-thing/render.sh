#!/usr/bin/env bash
# Render ONE decision into the Übersicht widget's HTML file.
#
# Reads a JSON verdict on stdin, writes a complete standalone HTML document on
# stdout. Rendering is deliberately split from selection: this script contains
# no ranking and makes no network call, so the card can be re-styled and tested
# without spending a model call or touching a mailbox.
#
# Verdict shape:
#   {"found":true,"action":"...","source":"...","why":"...","urgency":"high"}
#   {"found":false}                                  -> art mode
#   optional on either: "degraded":["izzy@silvercreek.ai: invalid_grant"]
#
# Why a single self-contained file: Übersicht runs `cat` on it and injects the
# result into `<iframe srcDoc>`. Relative URLs inside srcDoc resolve against the
# PARENT document, so a sibling .css/.woff2 would 404 — every asset must be
# inlined. srcDoc is also not gzipped, so bytes here are paid raw.
set -euo pipefail

FONT_DIR="${NRT_FONT_DIR:?NRT_FONT_DIR must point at the woff2 directory}"
ART_FILE="${NRT_ART_FILE:-}"

verdict="$(cat)"
j() { printf '%s' "$verdict" | jq -r "$1"; }

# HTML-escape: & first, or it double-escapes the entities added after it.
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

found="$(j '.found // false')"
urgency="$(j '.urgency // "normal"')"
degraded="$(j '(.degraded // []) | join(" · ")')"

roboto="$(base64 < "$FONT_DIR/roboto.woff2" | tr -d '\n')"
mono="$(base64 < "$FONT_DIR/roboto-mono.woff2" | tr -d '\n')"

# Duochrome: ground/ink invert as one surface. The system runs Dark fixed, so
# the dark block is what actually renders; the light block keeps the file honest
# if that ever changes. Signal red is an accent only, never a surface.
cat <<HEAD
<!doctype html>
<meta charset="utf-8">
<title>the next right thing</title>
<style>
  @font-face{font-family:Roboto;font-weight:400 900;font-display:block;
    src:url(data:font/woff2;base64,$roboto) format("woff2")}
  @font-face{font-family:"Roboto Mono";font-weight:400 700;font-display:block;
    src:url(data:font/woff2;base64,$mono) format("woff2")}

  :root{--ground:#fff;--ink:#0a0a0a;--signal:#ff2d16}
  @media (prefers-color-scheme:dark){:root{--ground:#0a0a0a;--ink:#fafafa}}

  *{margin:0;padding:0;box-sizing:border-box}
  html,body{width:100vw;height:100vh;overflow:hidden;background:transparent}

  /* Übersicht absolutely-positions each widget wrapper with inline styles,
     so escaping it needs !important on the geometry. */
  body{position:fixed!important;inset:0!important;
    width:100vw!important;height:100vh!important;
    font-family:Roboto,system-ui,sans-serif;color:var(--ink);
    display:flex;align-items:center;justify-content:flex-start;
    padding:0 0 0 7vw}

  /* Hatch: a Duochrome motif in ~6 lines of CSS rather than 20KB of WebGL.
     A full-screen widget never leaves the viewport, so an animated field would
     run at 30fps forever; this costs nothing after first paint. */
  .field{position:fixed;inset:0;opacity:.055;pointer-events:none;
    background:repeating-linear-gradient(135deg,var(--ink) 0 1px,transparent 1px 9px)}

  /* Duochrome law: text sits on a solid-ink knockout, never on the raw field. */
  .card{position:relative;background:var(--ground);border:2px solid var(--ink);
    padding:3.2vh 3vw;max-width:56vw;box-shadow:12px 12px 0 var(--ink)}

  .eyebrow{font-family:"Roboto Mono",ui-monospace,monospace;font-size:1.45vh;
    font-weight:700;letter-spacing:.42em;text-transform:uppercase;opacity:.62}
  .rule{height:2px;background:var(--ink);margin:1.5vh 0 2.4vh}

  .action{font-size:4.4vh;line-height:1.16;font-weight:800;letter-spacing:-.018em;
    text-wrap:balance}

  .meta{display:flex;align-items:center;gap:.85em;margin-top:2.8vh;
    font-family:"Roboto Mono",ui-monospace,monospace;font-size:1.5vh;
    font-weight:500;letter-spacing:.17em;text-transform:uppercase;opacity:.72}
  .dot{width:.62em;height:.62em;border-radius:50%;background:var(--ink);flex:none}
  .high .dot{background:var(--signal)}
  .high .flag{color:var(--signal);font-weight:700;opacity:1}

  .degraded{position:fixed;left:7vw;bottom:3.4vh;
    font-family:"Roboto Mono",ui-monospace,monospace;font-size:1.25vh;
    letter-spacing:.2em;text-transform:uppercase;opacity:.4}

  /* Art mode: the image IS the surface, so no knockout and no hatch. */
  .art{position:fixed;inset:0;width:100vw;height:100vh;object-fit:cover}
  .sig{position:fixed;right:3vw;bottom:3vh;font-family:"Roboto Mono",monospace;
    font-size:1.2vh;letter-spacing:.34em;text-transform:uppercase;
    color:#fff;mix-blend-mode:difference;opacity:.75}
</style>
HEAD

if [ "$found" = "true" ]; then
  action="$(j '.action' | esc)"
  source="$(j '.source // "—"' | esc)"
  why="$(j '.why // ""' | esc)"
  cls=""; [ "$urgency" = "high" ] && cls=" high"

  printf '<div class="field"></div>\n'
  printf '<div class="card%s">\n' "$cls"
  printf '  <div class="eyebrow">the next right thing</div>\n'
  printf '  <div class="rule"></div>\n'
  printf '  <div class="action">%s</div>\n' "$action"
  printf '  <div class="meta"><span class="dot"></span><span>%s</span>' "$source"
  [ -n "$why" ] && printf '<span>·</span><span class="flag">%s</span>' "$why"
  printf '</div>\n</div>\n'
elif [ -n "$ART_FILE" ] && [ -s "$ART_FILE" ]; then
  # Inlined, not hot-linked: the widget must render with the network down.
  printf '<img class="art" alt="" src="data:image/jpeg;base64,%s">\n' \
    "$(base64 < "$ART_FILE" | tr -d '\n')"
  printf '<div class="sig">nothing needs you</div>\n'
else
  printf '<div class="field"></div>\n'
  printf '<div class="card">\n  <div class="eyebrow">the next right thing</div>\n'
  printf '  <div class="rule"></div>\n'
  printf '  <div class="action">Nothing needs you right now.</div>\n</div>\n'
fi

[ -n "$degraded" ] && printf '<div class="degraded">partial coverage · %s</div>\n' \
  "$(printf '%s' "$degraded" | esc)"
exit 0
