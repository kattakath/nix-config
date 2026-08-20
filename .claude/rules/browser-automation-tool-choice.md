# Browser Automation — Which Tool, Deterministically

This session/repo has **four** distinct browser-automation-capable tool paths
available at once. Without a fixed decision order, a generic "do this in the
browser" ask forces an agent to guess between them — and different sessions
guess differently, producing exactly the kind of AI-client back-and-forth this
rule exists to eliminate. Pick by the table below; do not improvise.

## Decision order

1. **`browservm` + the `playwright` MCP — the default** for any autonomous,
   potentially multi-step web job (click, type, fill forms, navigate through a
   flow) that is not specifically about the user's own already-open browser.
   Bootstrap with the single one-shot command:

   ```bash
   nix run .#browservm-vfkit-up   # boot (if needed) + tunnel + wait for CDP
   ```

   then drive it with the `playwright` MCP tools, and use `automation-session
   status|seed|capture|login [site]` (`packages/automation-session.nix`) to
   check/restore/save the Keychain-encrypted session. See
   `docs/browservm-runbook.md` and `docs/automation-browser.md`.

2. **`claude-in-chrome`** (the Chrome extension driving the user's own,
   already-running, already-logged-in Chrome): use when the task is
   explicitly about *their* browser — "check my open tabs," "what's on the
   page I have open," a quick unauthenticated read that doesn't justify
   booting a VM. Zero setup, but it is the user's real session — be
   correspondingly careful (see the top-level action-category rules on
   sending messages, submitting forms, etc.).

3. **`opera-browser-connector`**: only for tasks specifically about Opera
   running inside `macvm`. It is **read-only** (list/read/navigate/screenshot
   — no click, no type). Never reach for it to complete an interactive,
   multi-step flow; if the task needs clicking or typing, use browservm instead.

4. **`kapture`**: **never auto-invoke.** Use it only when the user explicitly
   types "Kapture," or for the documented Kapture-only cases (a Vast.ai
   instance log-tail, the Grok tunnel — see the relevant skills/docs). This
   drives the user's real, currently-open Chrome with full read/write
   control; treat an unprompted use of it the same as an unprompted use of
   any other real-session tool.

5. **`mobile-mcp`** is a different category entirely — native Android/iOS
   *apps*, not browser tabs. Not a candidate for a "browser automation" ask.

## Why

Four overlapping paths with no stated precedence means an agent either asks
the user to disambiguate every time (friction) or silently guesses (drift
between sessions, and a real risk of picking a read-only tool — `opera` — for
a job that needs clicks/typing, discovering the gap mid-task). A fixed,
mandatory order removes both failure modes. `browservm` is the default
specifically because it's the only path built for unattended, authenticated,
multi-step jobs with session persistence — the other three are either
read-only, or tied to a real human session that shouldn't be driven without
being named explicitly.

## Quick check

If a task doesn't clearly say "my browser" / "my Chrome" / "Opera" /
"Kapture," it's a `browservm` job. Start with `nix run .#browservm-vfkit-up`.
