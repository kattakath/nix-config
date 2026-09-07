---
name: chrome-devtools
description: >
  This skill should be used when the user asks to "check the performance of
  <page>", "why is this page slow", "record a performance trace", "what network
  requests does this page make", "read the browser console", "debug this page in
  Chrome", "take a screenshot of <url>", "test this at mobile width", or "emulate
  a slow connection". It drives a real
  Chrome over the Chrome DevTools Protocol through the `chrome-devtools-mcp`
  server, and covers attaching to an already-running browser, the privacy flags
  that must be set, and the failure modes that look like a broken tool.
---

# Chrome DevTools for agents

`chrome-devtools-mcp` is an **MCP server**, not a browser extension. It drives Chrome
with Puppeteer over the Chrome DevTools Protocol, either by launching its own instance
or by attaching to one that is already running. Nothing gets sideloaded into the browser
to make it work.

Use it for what a page **does at runtime** — performance traces, network waterfalls,
console errors with source-mapped stacks, viewport and device emulation, and driving a
real browser to reproduce a bug.

**Measure the tool list before planning.** The published package ships fewer tools than
upstream's docs describe (29 in 1.8.0, measured 2026-09-06). `references/tools.md` records
what actually exists and what is documented-but-absent.

## Before anything else: verify the connection

Most reported "the tool is broken" cases are an unreachable browser, not a bad tool call.
Run the bundled doctor first:

```bash
scripts/devtools-doctor.sh              # defaults to http://127.0.0.1:9222
scripts/devtools-doctor.sh <browser-url>
```

It reports Node, the server package, whether the debugging endpoint answers, and which
browser build is actually listening. Read `references/attaching.md` when it fails.

## Two attach modes — pick deliberately

| Mode | Server flag | Use when |
|---|---|---|
| **Launch its own Chrome** | *(default)*, plus `--isolated` for a throwaway profile | Clean-room measurement; nothing to set up. No extensions, and 1.8.0 cannot add any |
| **Attach to a running browser** | `--browser-url=http://127.0.0.1:9222` | The real profile, real logins, or an installed extension matter — the **only** way to reach an extension in 1.8.0 |

Attaching requires the browser to have been **started** with
`--remote-debugging-port=9222`. It is a startup flag: enabling it on a browser that is
already running is not possible — quit and relaunch.

**Security, non-negotiable to mention:** an open debugging port lets **any local process**
drive that browser and read its data. Never leave it enabled on a daily profile beyond the
session that needs it. Details and the exact commands: `references/attaching.md`.

## Privacy flags — set them every time

Telemetry is **on by default**. Two flags turn it off, and both belong in every
configuration:

```
--no-usage-statistics    # stops usage stats going to Google
--no-performance-crux    # stops trace URLs going to the CrUX API
```

The second matters most: performance tools otherwise send **the URLs being traced**
off-machine. Set it before tracing anything private, internal, or personal.

## Core workflows

### Diagnose a slow page

1. `performance_start_trace` with `reload: true` and `autoStop: true`.
2. Let it settle, then `performance_stop_trace`.
3. `performance_analyze_insight` on the named insight rather than reading raw trace JSON.

Report the insight's own numbers. Do not convert a trace into a verdict the trace does not
support — a single local run is one sample on one machine.

### Find why a request failed

1. `list_network_requests` to see the waterfall, filtered by resource type where possible.
2. `get_network_request` on the specific one for headers, timing and status.

### Read what the page actually logged

`list_console_messages` for the run, `get_console_message` for one entry with its
source-mapped stack. An empty console after an expected failure usually means the script
never executed — check that it loaded before assuming a logic bug.

### Reproduce at a different viewport or device

`resize_page` sets an exact viewport. `emulate` covers device, CPU throttling and network
conditions. Prefer `resize_page` when the goal is a specific CSS breakpoint, because it is
exact and repeatable; a device preset changes several variables at once.

### Work with extensions

**Not possible in the published version.** The Extensions tool group is documented upstream
but absent from `chrome-devtools-mcp@1.8.0` — measured 2026-09-06, in both attach and launch
mode. Testing extension behaviour therefore means **attaching to a browser that already has
the extension installed**, not loading one into a clean instance. See `references/tools.md`.

## Authoring userscripts with it

This skill pairs with the **`userscript-author`** plugin, whose method requires measuring a
page in two states and diffing them. `resize_page` automates the state-B measurement that
otherwise requires a human to resize a window by hand.

Read `references/userscript-loop.md` for that exact loop. Consult it whenever the task is
"make site X do Y" rather than "debug site X".

## Rules that prevent wasted turns

- **Take a snapshot before interacting.** Input tools address elements by `uid` from a page
  snapshot, not by CSS selector. A stale `uid` fails; re-snapshot after the DOM changes.
- **Never open a dialog blindly.** A JavaScript dialog blocks the page until handled;
  `handle_dialog` is the way out.
- **Prefer `wait_for` over sleeping.** The automation already waits for action results;
  polling adds latency and flakiness.
- **One page id per call.** Page-scoped tools take `pageId`; confirm it with `list_pages`
  rather than assuming the last page is still current.
- **Do not present lab data as field data.** A local trace measures this machine.

## Scope boundary

This skill covers driving and inspecting a browser. It does not cover writing the page's
code, deciding what to ship, or installing the MCP server into a particular client — the
last of those is a configuration task, and `references/attaching.md` gives the exact JSON.

## Additional resources

### Reference files

- **`references/attaching.md`** — both attach modes end to end, the `--remote-debugging-port`
  launch step, the security exposure in full, the supported-browser caveat, and the client
  configuration JSON.
- **`references/tools.md`** — the verified tool catalogue by group, with the parameters that
  are easy to get wrong and the tools worth reaching for first.
- **`references/userscript-loop.md`** — the measure-A/B/diff loop shared with the
  `userscript-author` plugin, and which tool replaces which manual step.

### Scripts

- **`scripts/devtools-doctor.sh`** — connection preflight. Run it before diagnosing a tool
  failure; it distinguishes "no Node", "nothing listening", and "listening, but served by a
  build upstream does not officially support" — which it resolves from the running process,
  because ungoogled-chromium reports itself as `Chrome/<version>` too.
