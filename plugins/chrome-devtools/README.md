# chrome-devtools

Drive and inspect a real Chrome over the **Chrome DevTools Protocol**, through Google's
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) server.

Performance traces, network waterfalls, console output with source-mapped stacks, viewport
and device emulation, and real browser automation — with the parts that are easy to get
wrong written down: the two attach modes, the privacy flags, and **which tools actually
exist in the published package**.

Standalone. Nothing in it is specific to any one repo.

## What's in it

| Piece | What it owns |
|---|---|
| `skills/chrome-devtools/SKILL.md` | Core workflows, the two attach modes, privacy flags, the rules that prevent wasted turns |
| `skills/chrome-devtools/references/attaching.md` | Both modes end to end, the `--remote-debugging-port` launch step, the security exposure, the supported-browser caveat, client JSON |
| `skills/chrome-devtools/references/tools.md` | The **measured** tool catalogue, and what is documented upstream but absent |
| `skills/chrome-devtools/references/userscript-loop.md` | The measure-A/B/diff loop shared with the `userscript-author` plugin |
| `scripts/devtools-doctor.sh` | Connection preflight |
| `commands/devtools.md` | `/devtools` — investigate a page in the right order |

## Three things measured, not assumed

All on **2026-09-06**, against `chrome-devtools-mcp@1.8.0` (npm latest, published
2026-08-25):

1. **The published package exposes 29 tools, not the ~57 upstream documents.** Identical in
   attach and launch mode. The generated `docs/tool-reference.md` is written from `main`, so
   it describes tools the release does not have — including the **entire Extensions group**
   (`install_extension` and friends) and 12 of 13 Memory tools. Plans built on those fail at
   the first call.
2. **It attaches to ungoogled-chromium successfully**, despite upstream supporting "Google
   Chrome and Chrome for Testing only". `list_pages` returned the real tab. Treat the caveat
   as a first suspect when something is odd, not as "will not work".
3. **ungoogled-chromium reports `"Browser": "Chrome/152.0.7977.64"`** on `/json/version` —
   shaped exactly like Google Chrome, with no vendor field. The build name **cannot** tell
   you which browser is serving the port; the running process path can, which is what the
   doctor script reads.

Re-measure after a version bump. `references/tools.md` says how, in one handshake.

## The doctor

```bash
scripts/devtools-doctor.sh                       # defaults to http://127.0.0.1:9222
scripts/devtools-doctor.sh http://127.0.0.1:9333
```

Almost every "the DevTools tools are broken" report is one of three unrelated things, each
with a different fix — no Node, nothing listening on the port, or a browser upstream does
not officially support. The doctor separates them in one command instead of several turns.

Requires `bash`; uses `curl` and `pgrep` when present and degrades gracefully without them.
Exit 0 when an endpoint answered, 1 otherwise.

## Two safety rules the skill will not let you skip

- **Telemetry is on by default.** Always pass `--no-usage-statistics` **and**
  `--no-performance-crux`. The second is the one with data egress: performance tools
  otherwise send **the URLs being traced** to Google's CrUX API.
- **A debugging port is an unauthenticated control channel.** Upstream's own warning: "Any
  application on your machine can connect". Anything local can then read that browser's page
  content, cookies and session state, and act as the signed-in user. Prefer a launched
  isolated instance whenever the real profile is not genuinely required, and close the window
  when finished.

## Pairs with `userscript-author`

`resize_page` automates the state-B measurement that userscript authoring otherwise hands to
a human with a mouse. `references/userscript-loop.md` maps each manual step to its tool.

The two plugins are independent — either installs and works alone.

## Licence

MIT. The MCP server itself is Google's, under its own licence.
