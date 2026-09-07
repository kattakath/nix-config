# Attaching to a browser

Everything here is from the upstream README and `docs/advanced-usage.md`, **fetched
2026-09-06**. Where upstream states a limit or a warning, it is quoted rather than
paraphrased.

## Mode 1 — let the server launch Chrome (default)

No setup. The server starts Chrome the first time a tool needs a browser; merely
connecting to the MCP server does not launch anything.

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "-y", "chrome-devtools-mcp@latest",
        "--no-usage-statistics",
        "--no-performance-crux"
      ]
    }
  }
}
```

Default profile directory: `$HOME/.cache/chrome-devtools-mcp/chrome-profile` (channel name
appended for non-stable channels). It is **reused between runs and not cleared**, and only
one browser may use it at a time.

Add `--isolated` for a temporary profile that is wiped when the browser closes — required
when running several independent sessions at once, and the right default when the task
should leave no trace.

Add `--headless` for no window, and `--slim` to expose only the basic tool set.

**No extensions are present in a fresh profile, and 1.8.0 cannot add any** — the Extensions
tool group is documented upstream but absent from the published package (measured
2026-09-06; see `references/tools.md`). Exercising extension behaviour therefore requires
attach mode against a browser that already has it installed.

## Mode 2 — attach to an already-running browser

Two routes upstream documents.

### 2a. `--browser-url` (manual port) — DEAD against a consent-mode browser

**Read this before reaching for it.** A browser whose debugging was switched on from
`chrome://inspect/#remote-debugging` serves the CDP WebSocket but **404s every `/json/*`
path**, and `--browser-url` must GET `/json/version` to discover the WebSocket URL. It
therefore cannot attach at all — measured 2026-09-07 on Chromium 152 *and* Opera Air
[F-NO-JSON-HTTP]. Use **2b** unless the browser was started with the launch flag.

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "-y", "chrome-devtools-mcp@latest",
        "--browser-url=http://127.0.0.1:9222",
        "--no-usage-statistics",
        "--no-performance-crux"
      ]
    }
  }
}
```

The browser must already be listening on that port, which means it was **started** with the
flag. On macOS:

```bash
open -na "Chromium" --args --remote-debugging-port=9222
# Google Chrome:
open -na "Google Chrome" --args --remote-debugging-port=9222
```

`--remote-debugging-port` is a **startup** flag: it cannot be added to a process that is
already up, so quit it completely and relaunch. That is a fact about *the flag*, not about
the browser — a running browser **can** be switched into debugging mode from
`chrome://inspect/#remote-debugging` with no relaunch at all (see 2b), it just picks its own
port. Relaunching while an instance of the same profile is still alive silently reuses the
existing process and the port never opens, which reads exactly like the flag being ignored.

`scripts/route-up.sh --tier 1 [--isolated] --yes` performs exactly this launch, refuses when a
portless Chromium is already running, and re-probes afterwards.

Verify before blaming anything else:

```bash
bash scripts/devtools-doctor.sh [--user-data-dir DIR]
```

The doctor probes **both** modes and says which one you are in. Probing by hand is only
valid for a launch-flag browser:

```bash
curl -s http://127.0.0.1:9222/json/version      # classic mode ONLY
```

A JSON body naming the build means that endpoint is live. **A 404 or empty reply does not
mean the browser is down** — in consent mode that is the expected answer [F-NO-JSON-HTTP].
The authority in that mode is the profile's own `DevToolsActivePort` file: line 1 is the
port the browser chose, line 2 is the browser WebSocket path.

**The flag can never be declarative on this fleet** [F-CASK-NOFLAG]: the browser is a Homebrew
cask, so home-manager's own assertion forbids `commandLineArgs`. This is a hand-run wrapper by
construction — not an oversight, and not something to "fix" in Nix.

### Which profile — the decision, and what each costs

Three profiles, and conflating them is the most expensive mistake here. **The fidelity of a
route and the right profile for a job are different questions:** an isolated launch is the
cleanest measurement and the *wrong page* for authoring work.

| Profile | How | Extensions + logins | Right for | What it costs |
|---|---|---|---|---|
| **daily** (cask default) | `open -na "Chromium" --args --remote-debugging-port=9222` — **no** `--user-data-dir` | yes | Picking or authoring against the page that actually annoys the operator | The whole profile is **exposed for the lifetime of the launch** — cookies, sessions, saved passwords. Treat it as compromised-by-default and close it when done |
| **isolated debug** | same, plus `--user-data-dir="$(mktemp -d)"` | no | **Diagnosis of a public site** — the default for this skill | No logins, no extensions, no userscript manager. A site that renders differently when signed in is not the site you measured |
| **the profile the script ships into** | the operator's normal launch, **no port at all** | yes | **The only place a post-install proof means anything** | Not drivable — no port, so every check here is the operator's own, by hand |

Two consequences worth stating rather than rediscovering:

- **A measurement taken in one profile does not prove behaviour in another.** Extension set, CSP
  handling and script injection timing all differ, which is why a userscript is proven by
  re-measuring after a real install rather than by a green measurement in the debug browser.
- **A debug-enabled daily profile is a deliberate, time-boxed trade**, made when login state or
  an installed extension genuinely changes the result — never as a default because it is
  convenient.

### 2b. `--autoConnect` + `--userDataDir` — THE route on this fleet

Chrome/Chromium ≥ M144 (and Opera Air) accept connections without a fixed port: enable
remote debugging at `chrome://inspect/#remote-debugging`, then run the server with
`--autoConnect`. The browser shows a permission dialog, picks its own port, and writes both
the port and the browser WebSocket path into `DevToolsActivePort` at the root of its
user-data dir.

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "-y", "chrome-devtools-mcp@latest",
        "--autoConnect",
        "--userDataDir=/Users/you/Library/Application Support/com.operasoftware.OperaAir",
        "--no-usage-statistics",
        "--no-performance-crux"
      ]
    }
  }
}
```

**`--userDataDir` redirects where `--autoConnect` looks for `DevToolsActivePort`**
[F-AUTOCONNECT-USERDATADIR]. Without it the lookup goes to the stable Chrome channel dir and
fails with `Could not find DevToolsActivePort for chrome at …/Google/Chrome/DevToolsActivePort`
— that error message is itself the proof the flag is doing the redirect. Pass the **user-data
dir** (the one holding `DevToolsActivePort` and `Default/`), not the `Default/` profile inside it.

This is the only attach route that survives a browser restart, because the port **and** the
browser WebSocket UUID both change every launch. It is what `modules/shared/mcp.nix`
declares, and why that module configures a directory rather than a port.

With multiple profiles it connects to the **default** profile and can reach every open
window in it.

### 2c. `--wsEndpoint` (one-shot, exact)

```bash
npx -y chrome-devtools-mcp@latest \
  --wsEndpoint "ws://127.0.0.1:61867/devtools/browser/<uuid>" \
  --no-usage-statistics --no-performance-crux
```

Takes the browser WebSocket URL directly, skipping `/json/version` entirely — so it works
against a consent-mode browser where 2a cannot. `--wsHeaders '{"Authorization":"…"}'` adds
headers, and only works with this flag.

**Both halves of that URL are per-launch**, so this is a debugging tool, never a declaration:
read them from lines 1 and 2 of `<user-data-dir>/DevToolsActivePort`, or from the doctor.

## The security exposure — read before enabling either

Upstream's own warning about the debugging port:

> Enabling the remote debugging port opens up a debugging port on the running browser
> instance. **Any application on your machine can connect** […]

That is the whole risk in one line. An open port is an unauthenticated control channel to
that browser: any local process can read page content, cookies and session state, and drive
the browser as the signed-in user.

Consequences that follow directly:

- **Bind to loopback and keep it there.** `127.0.0.1`, never `0.0.0.0`, and never forwarded.
- **Treat a debug-enabled daily profile as compromised-by-default** for the lifetime of that
  launch. Password-manager integrations, authenticated sessions and saved cookies are all in
  reach.
- **Close the window when finished.** Quit and relaunch normally; the port dies with the
  process.
- **Prefer mode 1 whenever the real profile is not actually required.** Most debugging,
  performance and layout work does not need real logins.

Upstream also notes the general exposure: the server "exposes content of the browser
instance to the MCP clients allowing them to inspect, debug, and modify any data in the
browser or DevTools. Avoid sharing sensitive or personal information."

## Supported browsers

> `chrome-devtools-mcp` officially supports Google Chrome and Chrome for Testing only.
> Other Chromium-based browsers may work, but this is not guaranteed, and you may encounter
> unexpected behavior.

**ungoogled-chromium and Opera Air are therefore both unsupported** — and both work.
Measured 2026-09-07: the server attached to **Opera Air** (`OPR/135`, Chromium 151) and
`list_pages` returned its real tabs [F-UGC-ATTACHES]. Treat the caveat as "first suspect
when something is odd", not "will not work".

One trap when identifying the build: **ungoogled-chromium reports
`"Browser": "Chrome/152.0.7977.64"`**, indistinguishable in shape from Google Chrome, and
there is no vendor field [F-UGC-NO-VENDOR]. The name cannot settle which build is serving
the port. Neither can `pgrep -fl -- '--remote-debugging-port'` any more — a consent-mode
browser has no such flag in its argv. The honest discriminator is **who holds the listening
socket**, which is what the doctor script now reads:

```bash
lsof -nP -iTCP:<port> -sTCP:LISTEN
```

## Telemetry

| Default | Flag to disable | What it sends |
|---|---|---|
| Usage statistics **on** | `--no-usage-statistics` | Tool invocation success rates, latency, environment info |
| CrUX lookups **on** | `--no-performance-crux` | **Trace URLs** to the Google CrUX API |

Env vars also suppress collection: `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS`, or `CI`.
Update checks are disabled with `CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS`.

The CrUX flag is the one with a data-egress consequence: without it, the URL of every traced
page can leave the machine. Set both by default and treat their absence as a bug in the
configuration.

## Concurrency

One server per conversation is the normal shape. When a single server instance is shared
across concurrent agents or subagents, start it with `--experimentalPageIdRouting` so
page-scoped tools carry a `pageId` and each agent addresses its own tab. Combine with
`--isolated` when each session should also get its own profile.
