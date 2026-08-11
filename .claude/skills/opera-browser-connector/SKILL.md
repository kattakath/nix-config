---
name: opera-browser-connector
description: >
  Drive the Opera browser running INSIDE the macvm guest VM (list/read open
  tabs, read page content, screenshot, navigate, close tabs — NOT clicks or
  form fills, see Prerequisites) from Claude Code on the macos host, via
  Opera's remote "Browser Connector" MCP server (connector.mcp.opera.com),
  wired into the gateway as the `opera` server (modules/shared/mcp.nix). Use
  when the user asks to read/screenshot/navigate a page open in Opera, or
  otherwise automate the Opera browser specifically — NOT Chrome (that's
  kapture/playwright) and NOT a headless browser (Opera must actually be
  running inside macvm, with a real logged-in user session).
---

# Opera Browser Connector

No official Anthropic/Opera-published skill exists for this connector as of
2026-08; this is a repo-local skill grounded in Opera's own announcement +
docs (no vendored upstream source — see "Provenance" below).

## What it is

Opera's **Browser Connector** (built on MCP, announced 2026-03 for Opera Neon,
2026-04 for Opera One/GX) exposes an **already-running, already-logged-in**
Opera browser to MCP clients over a remote endpoint,
`https://connector.mcp.opera.com/mcp`. It is NOT a headless/sandboxed browser —
it acts on real tabs and real authenticated sessions, so anything it reads or
does is visible in the actual Opera window.

## DELIBERATELY cross-host in this repo

Unlike `cloudflare` (same-machine OAuth bridge), this repo splits the two
sides of the connector across **different hosts on purpose**:

- **The Opera browser itself** runs inside the **`macvm`** guest VM (the
  `opera` Homebrew cask, `hosts/macvm.nix`) — not on `macos`.
- **The MCP bridge** (`opera` gateway server, `modules/shared/mcp.nix`, same
  `npx -y mcp-remote <url>` shape as `cloudflare`/`cloudflare-docs`) runs on
  **`macos`**, since that's this repo's sole Claude Code/MCP client host.

Both sides authenticate to the **same Opera account** — the browser inside
macvm logs into it directly; `mcp-remote` on macos gets its own OAuth login
(browser popup) against that same account. Opera's connector pairs a client
session to a browser session **via the account**, through Opera's own cloud
relay — not via a local/same-machine handshake — which is what makes driving
a macvm-hosted browser from macos possible at all.

**CONFIRMED working (2026-08-10):** from a macos Claude Code session, `opera`
tools successfully navigated the macvm-hosted Opera to a URL, took a
screenshot showing the real rendered page, switched between multiple signed-in
Google account sessions via `/u/<index>/` URLs, and ran a Google Photos
person-search — all visibly acting on the actual macvm Opera window. Cross-
host, account-paired operation is real, not just a theory (contrast the
original hedge below, kept for context).

If it ever stops working (tools connect/authenticate fine but calls error or
time out with no visible effect in the macvm Opera window), the fallback is
running Opera directly on `macos` instead (undo the cask move) — flag this
clearly to the user rather than silently reverting.

## Prerequisites (one-time, manual — not Nix-managed)

1. `darwin-rebuild switch --flake .#macos` (wires the `opera` MCP server) —
   and separately reactivate **`macvm`** (`nix run .#macvm-tart-ssh -- nix run
   --refresh github:kattakath/nix-config#macvm`, or sync+run from a local
   checkout per docs/macvm-tart-runbook.md) so its `opera` cask installs.
2. **Inside macvm**: open Opera → Settings → search "AI Services" → enable
   **Browser Connector** (built-in already on Opera Neon) → log in with an
   Opera account when prompted. This Settings page only has the coarse
   install/uninstall + master enable toggle — it is NOT where per-tool
   permissions live (see step 3).
3. **Per-tool permissions live behind the Browser Connector's own toolbar
   icon** (a plug icon in the collapsible toolbar tray, inside macvm's Opera)
   → click it → gear/settings icon in the popup. **Empirically confirmed
   (2026-08-10) the full toggle list in this build is only six items** —
   "What the AI can see": *See open tabs*, *Read page content*, *View
   browsing history*; "What the AI can do": *Take screenshots of the page*,
   *Navigate to page*, *Close tabs*. **There is no Mouse clicks, Keyboard
   input, Fill forms, Search Google, or Switch tabs toggle in this build at
   all** — press coverage describing those (see Provenance) does not match
   what's actually shipped. Don't hunt for a hidden toggle; if a tool isn't in
   that list of six, it isn't available yet.
4. **On macos**: the first real MCP call through the `opera` gateway entry
   triggers `mcp-remote`'s browser-based OAuth login (same UX as
   `cloudflare`) — log into the **same** Opera account used in step 2; the
   token then caches in `~/.mcp-auth`.

## Rules

- **Opera must be running inside macvm** with an active, logged-in user
  session — this is not a headless browser, and there is nothing to "start"
  from macos the way `chrome-automation` (packages/chrome-automation.nix)
  launches a dedicated local Chrome. If `macvm` itself is stopped
  (`nix run .#macvm-tart-doctor`), start it first
  (`nix run .#macvm-tart-start`).
- Assume only the six confirmed tools exist (list-tabs, tab-content, history,
  screenshot, go-to-page, close-tab) unless a fresh check of the Browser
  Connector's own toolbar-icon settings shows otherwise — click/keyboard/
  fill-form/search/switch-tab are not just "off by default", they are not
  present in this build at all. Don't loop retrying a tool call for one of
  those; tell the user it isn't shipped yet, and see the macos-side SSH+
  `osascript`/System Events fallback (macos-automator style, but targeting
  the macvm guest) for real click/keyboard automation in the meantime.
- Everything this connector does happens in the **real, authenticated**
  browser session inside macvm — treat it with the same care as
  `macos-automator`/`kapture` (real side effects, no sandbox), and remember
  the side effects land in a window on a different machine than the one
  Claude Code is running on.
- This is Opera-specific. For Chrome automation on macos use `kapture`
  (extension-based) or `playwright` (CDP-attached to the dedicated
  `chrome-automation` profile) — see their own gateway entries in
  `modules/shared/mcp.nix`.

## Provenance

No official skill/plugin ships from Opera for this connector (checked
2026-08-10 — search turned up press/blog coverage only, no `SKILL.md` or
Claude Code plugin).

Press coverage (Opera's own blog/newsroom posts, tech press) describes a
broader write-tool set — Switch tabs, Close tabs, Mouse clicks, Keyboard
input, Go to previous page, Search Google, Navigate to page, Fill forms —
than what is actually live in this build: **only Navigate and Close tabs
exist as write tools**, alongside the three read tools and history. Don't
trust the press-derived list for what's actually callable; always defer to
a live check of the Browser Connector's own toolbar-icon settings panel
(see Prerequisites step 3) over anything documented here or in outside
coverage, since Opera is actively shipping new tools to this surface.

The cross-host, account-paired design is **empirically confirmed**, not
just an inference (see the "DELIBERATELY cross-host" section above) — a
live `opera` tool call from macos was watched acting on the macvm Opera
window on 2026-08-10.
