---
description: Point at an element in the browser and get a dated, verified selector back — the operator clicks, the agent measures the exact node that was clicked.
argument-hint: [what you are about to point at]
---

Take a pick for: `$ARGUMENTS`

This is the two-way handoff verb. The operator points at something in a real page; the agent
measures **that** node — box, reachability, cascade, scored selector candidates — and hands back
one `page-lab/pick@1` envelope. Nobody guesses a selector, and nobody describes an element in
prose that the other side has to re-find.

Call it on its own, or as the first move of `/userscript` step 2.

## Sequence

- **1 — Route.** Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/page-route.sh`. It prints
  `ROUTE_SHELL=cdp|kapture|none` plus an `AGENT-MUST-CHECK:` block naming the two checks a
  shell cannot make. Make those two checks, then re-run with
  `--tools kapture-eval=yes|no,cic=yes|no` for the final `ROUTE=`. Read
  `../references/routes.md` for what each tier can and cannot do.
- **2 — Open the gate if it is shut.** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/route-up.sh --tier <n>`
  prints the exact step; only tier 1 can be opened without the operator, and only with `--yes`.
  **Do not improvise past a dark gate.**
- **3 — Warn, then arm.** Say the sentence in *The cost of arming* below **before** arming, not
  after. On tier 1: `page-lab-pick --expect-origin <origin>` (the fleet wrapper; outside this
  fleet, `node ${CLAUDE_PLUGIN_ROOT}/scripts/pick-element.mjs`). On tiers 2–4 follow the call
  shapes in `../references/pick-protocol.md`. On tier 5, print the snippet, let the operator run
  it in their own console, and pipe what they paste through
  `pick-normalize.mjs --route operator-paste`.
- **4 — Confirm back.** Point at what was measured — the highlight on tier 1, a screenshot of the
  selector on tiers 2–3, a zoom on the rect on tier 4 — so the operator can see the agent
  understood the right element before anything is written.
- **5 — Report.** Hand back the envelope's `target`, every candidate **with its match count**,
  `fidelity`, and `shipBlockers`. Then either continue into `/userscript`, or stop.

## What the operator sees

- The browser comes to the front on its own (otherwise the app-switching click *is* the pick).
- One line on stderr: `ARMED on N tab(s). Click the element you mean in Chromium. Ctrl-C here
  cancels and disarms. 45s timeout.`
- The DevTools inspect highlight follows the cursor — the same overlay the DevTools arrow drives,
  with no DevTools window open.
- After the click, the chosen element is highlighted back for about 1.2 s. That flash is the
  agent saying *this one?*

**Ctrl-C is the only documented cancel.** Whether `Escape` also cancels from a non-DevTools
client is unmeasured [F-UNMEASURED-ESC], so do not promise it.

## The cost of arming — say this out loud first

**An armed picker swallows the next click on every armed tab** [F-ARMED-SWALLOWS]. Every page
target is armed, not just one, because the operator clicks in whichever tab they happen to be
looking at [F-TARGETS-13-3]. So while the picker is armed:

- The next click in **any** tab is consumed by inspect mode. A link will not navigate; a button
  will not fire.
- That is the mechanism working, not a bug — but the operator must know it before it happens,
  and must not be left holding it.

## It always disarms

Disarm is unconditional and layered, because a stranded arm silently breaks clicking in every
tab: `finally` · the hard timeout · `SIGINT` · `SIGTERM` · `uncaughtException` · a detached
watchdog that survives `kill -9` · a stale-arm sweep at the start of every `page-route.sh` run.
Each clear is guarded on its own and carries `highlightConfig`, which the disarm call also
requires [F-DISARM-HIGHLIGHTCONFIG].

If a disarm ever fails, the picker exits **loudly** — say so, and give the operator the two
recoveries in this order:

1. `node ${CLAUDE_PLUGIN_ROOT}/scripts/pick-element.mjs --disarm-only` — sweeps every page target
   and clears the stamp.
2. Quit the browser. Inspect mode lives in the browser process, so quitting ends it outright.

## What counts as a pick

A returned envelope is **not** automatically a measurement. It is one only when
`fidelity == "verified"`, at least one candidate has `matches == 1`, and `shipBlockers` is empty.
Anything else is a lead, and the report must say which:

| Blocker | What it means | Next move |
|---|---|---|
| `kapture-minted-selector` | the selector was stamped onto the page and evaporates on reload | re-pick on a non-mutating route; it can never enter a `.user.js` |
| `shadow-root-target` / `cross-frame-target` | `document.querySelector` cannot reach it | use the host-piercing or frame pattern in `../skills/userscript-author/patterns.md` |
| `generated-classname` | the class looks build-generated and will churn | re-score against an attribute or a positional path |
| `origin-unconfirmed` | the clicked tab's origin was never checked | confirm the URL with the operator before using the selector |
| `sanitizer-drift` | the tier-4 canary came back wrong | demote to the paste route and re-measure |

Never read a field the fidelity table in `../references/pick-protocol.md` says is absent — a
missing `matches` means **not verified**, never *one match*.

## Non-negotiable

- **Never invent, complete, or prettify a selector.** If no route is reachable, say so and stop.
  Asking the operator to paste a probe is a measurement; writing a plausible selector is not.
- **Never arm silently.** The warning above precedes the arm, every time.
- **Never leave a debugging port open on a daily profile** past the end of the work — any local
  process can drive that browser as the signed-in user.
