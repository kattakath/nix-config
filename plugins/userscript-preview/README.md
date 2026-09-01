# `userscript-preview` — Claude Code plugin

Re-inject a Violentmonkey `*.user.js` into a **live matching Kapture tab** after
each save, so layout iteration does not wait on `activate` + a click.

In-repo plugin, served from the `kattakath-nix-config` marketplace (`plugins/` at
the repo root) and installed declaratively by `modules/shared/home.nix`.

## Why a plugin

A skill cannot register a `PostToolUse` hook. The unit is: hook + `/userscript-preview`
command + the contract the userscripts must keep (`window.__nix*Teardown`).

## What it is not

- Not a Violentmonkey installer. Persistence is still `activate` then click
  `index.html`. The hook cannot click an extension dialog (user-gesture) and
  must not run `activate --local` (full darwin switch) on every save.

- Not a generic "eval anything" helper. Only `*.user.js`, only `@match` tabs,
  only when Kapture `evalAllowed` is true.

## Contract

Re-injecting the IIFE **duplicates** observers and constructed UI unless the
script tears down first. Each shipped userscript registers `window.__nix<Name>Teardown`
and calls it at the top of the next run.

## Setup

1. Open the site in Chromium with Kapture connected.
2. Enable **Allow JS execution** on that tab.
3. Edit `userscripts/<kebab>.user.js` — the hook POSTs the body to
   `http://127.0.0.1:61822/tab/<id>/evaluate`.

Override the Kapture base with `KAPTURE_URL` if needed.

## Manual

```bash
python3 plugins/userscript-preview/scripts/preview.py userscripts/google-photos-icon-nav.user.js
```

Or `/userscript-preview` from a Claude Code session with the plugin enabled.
