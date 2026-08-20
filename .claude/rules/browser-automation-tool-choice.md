# Browser Automation — Which Tool, Deterministically

This session/repo has **three** distinct browser-automation-capable tool paths
available at once (plus `mobile-mcp`, a different category — native apps, not
browser tabs, listed below for completeness but not part of the "three").
Without a fixed decision order, a generic "do this in the browser" ask forces
an agent to guess between them. Pick by the table below; do not improvise.

## Decision order

1. **`claude-in-chrome`** (the Chrome extension driving the user's own,
   already-running, already-logged-in Chrome) — **the default** for any
   browser task: reading a page, filling a form, clicking through a flow, or
   checking an authenticated site. Zero setup, and it is the only path here
   that can actually click/type outside Opera-in-macvm. It is the user's real
   session, though — be correspondingly careful (see the top-level
   action-category rules on sending messages, submitting forms, entering
   credentials, etc.).

2. **`opera-browser-connector`**: only for tasks specifically about Opera
   running inside `macvm`. It is **read-only**
   (list/read/navigate/screenshot — no click, no type). If the task needs
   clicking or typing, use `claude-in-chrome` instead.

3. **`kapture`**: **never auto-invoke.** Use it only when the user explicitly
   types "Kapture," or for the documented Kapture-only cases (a Vast.ai
   instance log-tail, the Grok tunnel — see the relevant skills/docs). This
   drives the user's real, currently-open Chrome with full read/write
   control; treat an unprompted use of it the same as an unprompted use of
   any other real-session tool.

4. **`mobile-mcp`** is a different category entirely — native Android/iOS
   *apps*, not browser tabs. Not a candidate for a "browser automation" ask.

## Why

An isolated, disposable automation-VM path (`browservm`, a NixOS/vfkit guest
with its own headless Chromium) was built and thoroughly hardened here, then
removed (2026-08-20) after every real attempt to use it hit walls its own
architecture couldn't fix: sites with bot-management (Cloudflare, etc.)
correctly flag generic headless Chromium regardless of what's driving it, VM
or not. `claude-in-chrome` — a real, already-trusted browser session — covers
the actual need with zero maintenance surface in this repo. Keep the decision
order fixed anyway: without it, an agent either asks the user to disambiguate
every time, or silently guesses (a real risk of picking the read-only
`opera` path for a job that needs clicks/typing).

## Quick check

If a task doesn't clearly say "Opera" or "Kapture," it's a
`claude-in-chrome` job.
