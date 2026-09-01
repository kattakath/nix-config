---
name: userscript-preview
description: >
  Live-preview a Violentmonkey userscript in a connected Kapture tab after each
  save, without activate + click. Use when editing userscripts/*.user.js, when
  asked to "preview the userscript", "inject into the tab", or "make the
  userscript change show up now".
---

# Userscript live preview (Kapture)

This plugin re-injects `*.user.js` into a matching Chromium tab through Kapture
(`http://127.0.0.1:61822/tab/<id>/evaluate`).

**Preview ≠ install.** Violentmonkey still owns persistence. `activate` + a
click in `index.html` is what survives a new profile / Cmd-R. The hook only
mutates the **already-open** document. It will **not** run `activate` and
**cannot** click Violentmonkey (extension install is a user gesture).



## When it fires

- **Automatic:** PostToolUse on `Write|Edit|StrReplace` of a `*.user.js`.
- **Manual:** `/userscript-preview path/to/file.user.js`

Skip unless the path ends in `.user.js`. No matching tab, Kapture down, or
`evalAllowed=false` → a `systemMessage`, never a hard fail.

## Script contract (must hold or the tab duplicates)

Every userscript this hook will re-inject **must**:

1. Call a previous `window.__nix<Name>Teardown()` at the top of its IIFE.
2. Register a new teardown that disconnects observers, removes constructed
   nodes / adopted sheets / style tags, and deletes the function.
3. **Not** early-return on a "already init" `data-*` flag — that is what made
   re-inject a no-op.

Shipped:

| File | Teardown key |
|---|---|
| `userscripts/google-photos-icon-nav.user.js` | `window.__nixGooglePhotosTeardown` |

A new script that is not idempotent must not be previewed until it is.

## Operator setup

1. Kapture extension connected to the tab.
2. Toggle **Allow JS execution** (resets on disconnect).
3. Tab URL matches an `@match` in the file.

## Do not

- Drive Violentmonkey. The click-through stays manual.
- `@require` a live-reload helper. The plugin POSTs the file body.
- Treat a successful inject as "gated". Still `git add` + `checks.*.userscripts`.
