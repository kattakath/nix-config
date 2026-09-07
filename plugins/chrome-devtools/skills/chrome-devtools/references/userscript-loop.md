# The userscript measure loop

Companion to the **`userscript-author`** plugin. That plugin owns the authoring judgment —
what to measure, how to read the diff, what to write. This file covers only which DevTools
tool replaces which manual step.

Neither plugin depends on the other. `userscript-author` works with any browser-automation
route; this one is useful for debugging and performance with no userscript in sight.

## What this replaces

`userscript-author`'s method measures a page in two states and routes on the difference:

- **state A** — what the site gives by default
- **state B** — the state wanted (usually the site's own narrow-viewport layout)

Reaching state B has been a **manual step**: a human resizes the window, changes route, or
toggles something, then the probe re-runs. `resize_page` removes the manual step for the
common case, because most state-B triggers are a CSS media query.

| Step | Manual | With this server |
|---|---|---|
| Run a probe | paste into DevTools console | `evaluate_script` |
| Reach state B by width | drag the window | `resize_page` |
| Reach state B by device | DevTools device toolbar | `emulate` |
| Confirm the script ran | eyeball the page | `evaluate_script` + `list_console_messages` |
| Capture evidence | manual screenshot | `take_screenshot` |

## The loop

1. **Attach or launch.** For measuring a public site, a launched isolated instance is enough
   and leaves the daily profile alone. Attach only when real login state changes the layout.
2. **Navigate** with `navigate_page`, then `wait_for` a stable marker rather than sleeping.
3. **Measure state A** — `evaluate_script` with the plugin's `dumpSubtree(rootSelector)`
   probe. Keep the JSON.
4. **Cross the breakpoint** — `resize_page` to a width on the other side of the suspected
   media query. Change **one** variable: width alone, not a device preset.
5. **Measure state B** — the same probe on the same root, recording the new `innerWidth`.
6. **Diff** with the plugin's `diff(a, b)` and take its verdict:
   - **DOM-DIFFERS** → the site sets an attribute or class; set that.
   - **DOM-IDENTICAL** → a pure media query. No selector can force a media query; lift the
     site's own rules and re-serve them. `mediaRules()` collects them, and its
     `crossOrigin` count says whether that route is available at all.
   - **STATE-B-UNREACHABLE** → the state does not exist; the work is construction, and every
     invented selector needs its own measured justification.
7. **Find the exact breakpoint** by bisecting with `resize_page` — cheap now that resizing is
   a tool call. Record the band, not a single pixel: a script pinned to one width breaks on
   the next site tweak.
8. **Verify after install** — `evaluate_script` the plugin's `assertEffect()`, re-run
   `dumpSubtree`, and diff against the recorded state B. Eyeballing is not a check.

## Testing the script in a real manager

**The clean-room route does not exist yet.** Loading a userscript manager into a fresh
isolated instance would need `install_extension`, which is documented upstream but **absent
from `chrome-devtools-mcp@1.8.0`** (measured 2026-09-06, both modes — see
`references/tools.md`).

So testing against a real manager means **attaching to a browser that already has one
installed**, with everything that implies: it is a real profile, so the debugging port
exposure in `references/attaching.md` applies in full.

The alternative that needs no manager at all: inject the script body with `evaluate_script`
and verify with `assertEffect()`. That measures the script's *effect* without exercising the
manager's install path, `@match` handling or `@run-at` timing — enough for iterating on
selectors, not enough to call a script shipped.

## Cautions specific to this pairing

- **`resize_page` is not a real window resize.** It sets the viewport. Anything keyed to
  screen size, device pixel ratio or actual chrome dimensions can behave differently from a
  dragged window. When a result looks impossible, confirm once by hand.
- **Measure with the userscript disabled.** State A means the site untouched. A previously
  installed copy of the script under development silently poisons the baseline.
- **Cross-origin stylesheets cannot be read.** `mediaRules()` reports the count for exactly
  this reason; a high number means the replay route may be unavailable no matter which tool
  drives the browser.
- **Never let convenience replace measurement.** The invariant is unchanged: no selector,
  class or breakpoint ships that was not dumped from the live page. These tools make
  measuring cheaper, not optional.
