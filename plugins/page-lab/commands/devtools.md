---
description: Drive a real Chrome over the DevTools Protocol — trace performance, inspect network, read the console, or reproduce at a given viewport.
argument-hint: <url-or-page> <what to investigate>
---

Run the **`page-diagnose`** skill from this plugin for: `$ARGUMENTS`

## Order of operations

1. **Preflight before diagnosing.** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/page-route.sh` says which
   routes are up at all; `bash ${CLAUDE_PLUGIN_ROOT}/scripts/devtools-doctor.sh` triages the CDP
   lane in detail. Run them **before** theorising — most failures are an unreachable browser, not
   a bad call. The doctor separates "no Node", "nothing listening", and "listening but an
   unsupported build".
2. **Choose the profile deliberately.** Launch an **isolated** instance for a public site; attach
   to the daily browser only when login state or an installed extension changes the result.
   `skills/page-diagnose/references/attaching.md` has both modes and the already-running trap.
3. **Check what exists.** The published package ships far fewer tools than upstream's generated
   docs describe [F-CDP-29TOOLS]. Consult `skills/page-diagnose/references/tools.md` rather than
   assuming a documented tool is callable — **never build a plan on an absent tool**.
4. **Snapshot before interacting.** Input tools address elements by `uid` from the page snapshot,
   never by CSS selector, and a `uid` goes stale the moment the DOM changes.
5. **Investigate with the narrow instrument** — a performance trace for slowness, the network
   request list for a failed request, the console log for errors, a viewport override for a
   breakpoint. One page id per call; wait on a condition rather than sleeping; a blocking dialog
   has exactly one exit.

## Non-negotiable

- **Always pass `--no-usage-statistics` and `--no-performance-crux`.** Telemetry is on by default
  and the CrUX lookup sends **trace URLs** off-machine.
- **Never leave a debugging port open on a daily profile.** It is an unauthenticated control
  channel — any local process can drive that browser and act as the signed-in user. Close it when
  the session ends, and never make it a launchd agent or a login item.
- **Every override ships with its clear.** Emulation and overlay state is sticky and shared with
  the operator's own DevTools window.
- **Report what was measured.** A local trace is one sample on one machine — never present lab
  data as field data.

End with the **Diagnosis report** block from `references/report-format.md`.

For authoring rather than diagnosing — anything shaped like *make this site do X* — hand off to
the sibling skill **`page-lab:userscript-author`** (`/userscript`), and use `/pick` when the
operator needs to point at the element they mean.
