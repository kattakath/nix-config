---
name: page-diagnose
description: >
  This skill should be used when the user asks why a page is slow, to record a
  performance trace, what network requests a page makes, why a request failed,
  to read the browser console, to debug a page in Chrome, to take a screenshot
  of a URL, to test a page at mobile width, or to emulate a slow connection. It
  drives a real Chrome over the DevTools Protocol through the
  `chrome-devtools-mcp` server.
---

# Page diagnosis — what a page actually does at runtime

Start from the **symptom**, not from the tooling:

| The user says | Go to |
|---|---|
| "why is this page slow" · "record a trace" | § Slow page |
| "what requests does it make" · "why did that request fail" | § Failed or slow request |
| "read the console" · "there's an error somewhere" | § What the page logged |
| "test it at mobile width" · "emulate a slow connection" | § Another viewport or device |
| "make this site do X" · "hide that element" · "my script broke" | **Not this skill** — hand to `page-lab:userscript-author` |

This skill measures a page it does **not** modify. Changing what a page does for the operator
is the sibling skill's job, and the two share this plugin's routes and scripts.

## Preflight — before diagnosing a "broken tool"

Most reported tool failures are an unreachable browser, not a bad call.

```bash
scripts/page-route.sh                    # which routes are live at all
scripts/devtools-doctor.sh               # the CDP lane in detail; defaults to http://127.0.0.1:9222
scripts/devtools-doctor.sh <browser-url>
```

The doctor separates the three real causes — **no Node/npx**, **nothing listening**, and
**listening but served by an unsupported build** — and resolves the last from the running
process, because ungoogled-chromium also reports itself as `Chrome/<version>`
[F-UGC-NO-VENDOR]. When it fails, read `references/attaching.md`.

## Two attach modes — pick deliberately

| Mode | Server flag | Use when |
|---|---|---|
| **Launch an isolated Chrome** | *(default)* + `--isolated` | **The default for diagnosis.** A public site needs no login state, and the daily profile stays untouched |
| **Attach to a running browser** | `--browser-url=http://127.0.0.1:9222` | Login state or an installed extension changes the result — the **only** route to an extension today |

Attaching needs the browser **started** with `--remote-debugging-port=9222`; it is a startup
flag, and a browser already running ignores it on a second launch. Full detail, the three
profiles and what each costs: `references/attaching.md`.

**An open debugging port is an unauthenticated control channel** — any local process can drive
that browser and act as the signed-in user. Hand-run only, closed when the work ends, never a
launchd agent or login item.

## Two privacy flags — on every invocation, no exceptions

```
--no-usage-statistics    # usage stats to Google
--no-performance-crux    # the URLs being traced, to the CrUX API
```

The second is the data-egress one: without it, the URL of every traced page leaves the machine.
Set both before tracing anything private, internal or personal.

## Workflows

### Slow page

1. Start a trace with `reload: true` and `autoStop: true`.
2. Let it settle, then stop it.
3. Analyse the **named insight** rather than reading raw trace JSON.

Report the insight's own numbers. **Never present lab data as field data** — one local run is
one sample on one machine, and a trace does not support a verdict about users.

### Failed or slow request

List the waterfall first (filtered by resource type where possible), then fetch the **single**
request for headers, timing and status. A failure is usually visible in the pair — the list
says which request, the detail says why.

### What the page logged

List console messages for the run, then fetch the one entry with its source-mapped stack. **An
empty console where an error was expected usually means the code never executed** — confirm it
loaded before hunting a logic bug.

### Another viewport or device

Setting an **exact viewport** is the precise instrument for a CSS breakpoint: one variable,
repeatable, bisectable. A **device preset** changes several variables at once — right for "does
this work on a slow phone", wrong for "which breakpoint fires". Throttling CPU and network
belongs to the preset tool.

## Rules that prevent wasted turns

- **Snapshot before interacting.** Input tools address elements by **`uid` from a page
  snapshot**, never by CSS selector, and a `uid` goes stale the moment the DOM changes.
- **A blocking dialog has exactly one exit.** A JavaScript dialog freezes the page, so an
  unhandled one makes every later call look hung; the dialog-handling tool is the way out.
- **Wait on a condition, do not sleep.** The automation already waits for action results;
  polling only adds latency and flakiness.
- **One page id per call.** Confirm it from the page list rather than assuming the last-opened
  page is still current.
- **Never build a plan on a documented-but-absent tool.** The published package ships **29**
  tools — upstream's generated docs describe roughly twice that, from `main`
  [F-CDP-29TOOLS]. `references/tools.md` records what exists, what is absent, and how to
  re-measure after a version bump.

## Extensions

**Not possible in the published version.** The entire Extensions tool group is absent from
`chrome-devtools-mcp@1.8.0` [F-CDP-29TOOLS], so the appealing "launch a clean instance and
install a userscript manager into it" route **does not exist**. Exercising extension behaviour
means attaching to a browser that already has it installed.

## Hand-off

Anything shaped like **"make site X do Y"** — hide an element, restyle a page, fix a broken
userscript — goes to **`page-lab:userscript-author`**. This skill can supply the measurement
that skill's method needs (an exact viewport for a state-B measurement, a console read, a
network fact), but it does not decide what to ship.

## Scope boundary

Driving and inspecting a browser, and nothing else: not writing the page's code, not deciding
what to ship, not installing the MCP server into a client — `references/attaching.md` has the
exact configuration JSON for that.

## Additional resources

- **`references/attaching.md`** — both attach modes end to end, the three profiles and what
  each costs, the launch step, the security exposure in full, the unsupported-build caveat, and
  the client configuration JSON.
- **`references/tools.md`** — the measured tool catalogue by group, the documented-but-absent
  table, and the re-measure recipe.
- **`../../references/cdp-extras.md`** — the raw-protocol surface no tool exposes, as
  symptom → command.
- **`../../references/report-format.md`** — the **Diagnosis report** block; end every run with it.
- **`scripts/devtools-doctor.sh`** — connection preflight, plus `--verify-tools` to detect tool
  drift against the measured count.
