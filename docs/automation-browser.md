# Automation browser — ungoogled-chromium + Keychain storageState

The fleet's **defacto agent automation browser**: a *disposable* ungoogled-chromium instance the
agent drives over CDP via the `playwright` MCP, with its session kept **encrypted in the macOS
Keychain** (a Playwright `storageState`) rather than in a persistent on-disk profile.

## Why this shape (the two axes we separated)

- **Driver** — Playwright over **CDP** (`modules/shared/mcp.nix`, `--cdp-endpoint :9222`). No
  browser extension, no foreground-tab hijack (the failure class that makes the kapture path
  flaky). Chromium refuses `--remote-debugging-port` on a *default* profile, so automation always
  needs a separate `--user-data-dir`.
- **Session storage** — **not** the browser profile. The profile is throwaway (wiped each launch);
  auth lives in the login Keychain as a `storageState`, injected into the live browser after
  launch. So the browser is effectively **ephemeral** and the profile can be nuked freely.

Why storageState in the Keychain and **not** `secret set`: `secret`'s index is exported into every
shell — you don't want a large session blob in every process env. This uses a **dedicated,
non-indexed** Keychain service (`automation-storage-state[-<site>]`), read on demand only.
(`secret ls` won't show it — by design.)

## Pieces

- `packages/chrome-automation.nix` → **`chrome-automation`**: launch ungoogled-chromium
  (`/Applications/Chromium.app`, from the `ungoogled-chromium` cask in `hosts/macos.nix`) on an
  ephemeral profile + CDP :9222. Headed (default) / `CHROME_AUTOMATION_HEADLESS=1`. Env knobs:
  `CHROME_AUTOMATION_{PORT,DIR,PROFILE,BROWSER,PERSIST}` (`BROWSER=chrome` falls back to Google
  Chrome; `PERSIST=1` keeps the profile).
- `packages/automation-session.nix` + `automation-session.js` → **`automation-session`**:
  `login|seed|capture|status`. Talks to the LIVE browser via `chromium.connectOverCDP` (from the
  nixpkgs `playwright-core`, no browser download); reads/writes the Keychain via `/usr/bin/security`.
  `connectOverCDP().close()` only disconnects — it never kills the browser the MCP is using.

## Workflow

```
# first time (per site): capture the session into the Keychain
chrome-automation                 # launch the disposable browser (CDP :9222)
# …log into the site in the Chromium window…
automation-session login sci      # save its storageState → Keychain 'automation-storage-state-sci'

# every run after: launch clean, inject auth, drive
chrome-automation
automation-session seed sci        # inject the Keychain session into the live browser
# …agent drives via the playwright MCP…
automation-session capture sci     # (optional) save refreshed cookies back to the Keychain

automation-session status sci      # is the browser up? is a session stored?
```

Session cookies expire (WordPress: ~2 days, or 14 with "Remember Me"); re-run `login` when a
`seed`-ed session stops working. The stored JSON is credential-grade — it *is* the live session
until expiry; the Keychain (encrypted, ACL-gated) is the right place for it.
