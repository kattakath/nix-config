# Automation browser — Keychain storageState over CDP

The fleet's browser-automation session model: the agent drives a disposable browser over CDP
via the `playwright` MCP, with its session kept **encrypted in the macOS Keychain** (a Playwright
`storageState`) rather than in a persistent on-disk profile. The browser itself is
[`browservm`](browservm-runbook.md) — an ephemeral NixOS/Chromium microVM (see that runbook for
the VM lifecycle); this doc covers the session/Keychain half, which is browser-agnostic.

## Why this shape (the two axes we separated)

- **Driver** — Playwright over **CDP** (`modules/shared/mcp.nix`, `--cdp-endpoint :9222`). No
  browser extension, no foreground-tab hijack (the failure class that makes the kapture path
  flaky).
- **Session storage** — **not** the browser profile. `browservm` has no persistent disk at all
  (rebuilt from the Nix store every boot); auth lives in the login Keychain as a `storageState`,
  injected into the live browser after launch. So the browser is fully **ephemeral** and can be
  torn down freely.

Why storageState in the Keychain and **not** `secret set`: `secret`'s index is exported into every
shell — you don't want a large session blob in every process env. This uses a **dedicated,
non-indexed** Keychain service (`automation-storage-state[-<site>]`), read on demand only.
(`secret ls` won't show it — by design.)

## Pieces

- [`docs/browservm-runbook.md`](browservm-runbook.md) — the VM itself: boot/stop/ssh, and why CDP
  access needs an SSH local port-forward (Chromium binds DevTools to `127.0.0.1` only — verified
  live, a deliberate hardening, not a config gap).
- `packages/automation-session.nix` + `automation-session.js` → **`automation-session`**:
  `login|seed|capture|status`. Talks to the LIVE browser via `chromium.connectOverCDP` (from the
  nixpkgs `playwright-core`, no browser download) at `127.0.0.1:$CHROME_AUTOMATION_PORT` (default
  `9222`) — browser-agnostic, it doesn't care what's actually listening there, only that
  *something* is. Reads/writes the Keychain via `/usr/bin/security`. `connectOverCDP().close()`
  only disconnects — it never kills the browser the MCP is using.

## Workflow

```bash
# boot the guest + tunnel CDP to the host
nix run .#browservm-vfkit-start
nix run .#browservm-vfkit-ssh -- \
  'nohup chromium --headless=new --no-sandbox --remote-debugging-port=9222 \
     >/tmp/chromium.log 2>&1 & disown'
nix run .#browservm-vfkit-ssh -- -L 9222:127.0.0.1:9222 -N &

# first time (per site): capture the session into the Keychain
automation-session login sci      # save its storageState → Keychain 'automation-storage-state-sci'

# every run after: seed auth, drive
automation-session seed sci        # inject the Keychain session into the live browser
# …agent drives via the playwright MCP…
automation-session capture sci     # (optional) save refreshed cookies back to the Keychain

automation-session status sci      # is the browser up? is a session stored?

nix run .#browservm-vfkit-stop     # tear down when done
```

Session cookies expire (WordPress: ~2 days, or 14 with "Remember Me"); re-run `login` when a
`seed`-ed session stops working — combine `-X` with `-L` on the SSH tunnel for that (see
`browservm-runbook.md`'s "Fresh login" section). The stored JSON is credential-grade — it *is*
the live session until expiry; the Keychain (encrypted, ACL-gated) is the right place for it.
