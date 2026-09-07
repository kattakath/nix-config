---
description: Drive a real Chrome over the DevTools Protocol — trace performance, inspect network, read the console, or reproduce at a given viewport.
argument-hint: <url-or-page> <what to investigate>
---

Run the **`chrome-devtools`** skill from this plugin for: `$ARGUMENTS`

## Order of operations

1. **Preflight before diagnosing.** If any tool call fails, run
   `scripts/devtools-doctor.sh` before theorising — most failures are an unreachable
   browser, not a bad call. It separates "no Node", "nothing listening", and "listening but
   an unsupported build".
2. **Check what exists.** The published package ships fewer tools than upstream documents
   (29 in 1.8.0). Consult `references/tools.md` rather than assuming a documented tool is
   callable.
3. **Snapshot before interacting.** Input tools address elements by `uid` from
   `take_snapshot`, never by CSS selector, and a `uid` goes stale when the DOM changes.
4. **Investigate**, choosing the narrow instrument: `performance_*` for slowness,
   `list_network_requests` for a failed request, `list_console_messages` for errors,
   `resize_page` for a breakpoint.

## Non-negotiable

- **Always pass `--no-usage-statistics` and `--no-performance-crux`.** Telemetry is on by
  default and the CrUX lookup sends **trace URLs** off-machine.
- **Never leave a debugging port open on a daily profile.** Any local process can drive that
  browser and read its data. Close the window when the session ends.
- **Report what was measured.** A local trace is one sample on one machine — never present
  lab data as field data.

For userscript authoring rather than debugging, read `references/userscript-loop.md` and
defer the authoring judgment to the `userscript-author` plugin.
