---
name: userscript-author
description: >
  The FLEET layer for Violentmonkey userscripts — what the portable plugin cannot
  know: how a script reaches this Mac, and why this repo no longer declares or
  gates any. Since 2026-09-14 delivery is PUBLICATION (Greasy Fork, then
  one install click), not a Nix declaration. Use alongside the
  `userscript-lab:userscript-author` skill (or `userscript-lab:site-redesign` for a
  whole-site redesign) when asked to "make <site> do X", "write a
  userscript for <site>", "fix my <site> script", "this site's X annoys me", or
  "can I see my userscript edits live/reflected in the browser" (Violentmonkey
  live-tracking). The authoring METHOD lives in that plugin (published at kattakath/skills);
  this skill owns only the delivery and install reality of this fleet.
---

# Userscript author — the FLEET layer

**Method is not here.** Measuring, routing, diffing, replaying, the code patterns, the probes and
the Greasy Fork rulebook all live in the **`userscript-lab` plugin**
([`kattakath/skills`](https://github.com/kattakath/skills/tree/main/plugins/userscript-lab)),
which is deliberately portable — it stops at a lint-clean, proven `.user.js` and knows nothing
about Nix. Invoke it as the `userscript-lab:userscript-author` skill
(`userscript-lab:site-redesign` for a whole-site redesign).

**The browser rail is Claude in Chrome — the only one.** Measured 2026-11-14: its `computer`
clicks and keys arrive trusted (`isTrusted: true`); it has **no** document-start injection;
`find` + `file_upload` reaches a hidden file input. On a per-site permission wall, **ask the
operator** — never fall back to CDP. (page-lab, its CDP servers and the ungoogled-chromium it
drove were removed 2026-11-14.)

**This skill owns the delivery half** — which, since 2026-09-14, is publication rather than a
Nix declaration.

```
[plugin] wish → shelf → route → measure → diff → write → lint → prove
[here]   → publish to the fork → install once → it self-updates
```

## What this repo stopped doing, and why (2026-09-14, commit 9067dca7)

One commit removed **all three at once**: the `kattakath-userscripts` input, every
`userScripts.scripts` entry of the then-browser module, and `checks.<system>.userscripts`.
[redacted] dropped its `modules/userscripts.nix`, its own `userscripts` input and **both** of
its gates the same day.

- **Publication beat materialisation on one measured fact.** A fork-installed copy is the only
  one that carries an `@updateURL`, so it updates itself; a file materialised into
  `$XDG_DATA_HOME` never could — every change needed an `activate` plus a manual click. The
  last script out, `google-photos-icon-nav`, is `greasyfork.org/scripts/595764`.
- **The gate was deleted, not re-pointed.** Aiming it at `${self}` would have been a green build
  over an empty directory — strictly worse than no gate, and exactly the failure its own comment
  warned about. See the long-form note that replaced it in `modules/parts/checks.nix`.
- **The rulebook did not move off the plugin.** It is
  `plugins/userscript-lab/scripts/userscript-meta-lint.sh`, running in CI in the repositories
  that own the scripts. One rulebook, run where the content is.
- **No userscript option is left.** `infra/google-workspace/chrome.nix` force-installs Violentmonkey
  from the Web Store. There is no Nix path to declare a script.

## Standing preference (thin by design — append, never invent)

| # | Statement | Confidence | Evidence |
|---|---|---|---|
| **UI-1** | Give me **the site's own compact/narrow chrome at full width** — navigation shrinks, content takes the reclaimed space. | **VERIFIED** | the entire purpose of `google-photos-icon-nav`, now `greasyfork.org/scripts/595764` |

- **Correction, load-bearing:** the 80px rail, the hover peek-back, the hidden storage footer and
  the 1px `Collections` divider are **Google's own design at its own breakpoint**, inherited as
  **one package** under UI-1 — **not** four separately stated preferences.
- Any preference **not in that table** is **asked via AskUserQuestion** (click-to-select,
  recommended first), never inferred. A row is **appended only after a shipped script proves it**.
- The plugin's own method rules (degrade-to-stock; never reimplement a state the site already
  renders) are general, and live there rather than here.

## Hard rules (fleet-specific — the plugin carries the rest)

1. **Never a secret.** A published script is world-readable; so was the Nix store copy. There is
   no longer a private lane that changes this: the Nix lane (a pinned input plus its gate) is
   retired, and the scripts' own repo, `ismailkattakath/userscripts`, is public.
2. **A script that must not be public has no path today.** Reviving the Nix lane needs all three
   back together (a pinned input holding the file, one line in `scripts`, the gate restored) —
   **ask the operator**, do not improvise a half of it.
3. If a change here *does* touch `.nix`, follow [git-purity](../../rules/git-purity.md) +
   [pr-title](../../rules/pr-title.md); the index is root [`CLAUDE.md`](../../../CLAUDE.md).
   Authoring and publishing a script touches **no file in this repo at all**.

## Deliver it

- [ ] Lint with `plugins/userscript-lab/scripts/userscript-meta-lint.sh` — the only gate
      left, and the same rulebook the deleted check ran.
- [ ] **Publish** per the plugin's `greasyfork.md`: Greasy Fork.
- [ ] **Updates ship by webhook — push to `main`, nothing else** (since 2026-10-21). Both repos
      run the same pipeline: lint + parse, then a publish job fast-forwards a **`published`**
      branch, but only when both are green. Greasy Fork listens on a push hook and syncs from `published`, never `main`. A pushed file reaches a listing only if it
      **exactly** equals that listing's sync URL (`…/published/<f>.user.js`, plus
      `listings/<f>.md` for the additional info).
      A **new** script never triggers one: the hook reads only *modified* files, not *added*
      ones. So publish the first version by hand, then set both sync URLs on its admin page.
- [ ] Install from the fork page, once. `@updateURL` is MEANT to do the rest — **this is the
      whole reason the fleet stopped materialising files**, so never hand the operator a raw file
      to install when a fork listing is possible.
- [ ] **But do not rely on Violentmonkey's update check to land a release** (measured
      2026-10-31): with the fork already serving the new version, both the dashboard's "check for
      updates" and its internal `CheckUpdate` command left civitai-declutter on the OLD version, with
      no error in the service-worker console. So after each push, install the release yourself:
      1. Wait until the fork's API reports the new version
         (`api.greasyfork.org/en/scripts/<id>.json`, field `version`).
      2. In a fresh `about:blank` tab, open the script's `update.greasyfork.org/.../*.user.js`
         URL. The stored `custom.lastInstallURL` in Violentmonkey's `scr:<n>` record holds it.
         Starting from an extension page swallows the navigation.
      3. Violentmonkey's confirm page opens. Wait for the heading to show the new version (it
         reads "Loading script data…" briefly), then make one Claude in Chrome `computer` click
         on **Reinstall** — trusted, so the page accepts it.
      4. Verify the installed version on the Violentmonkey dashboard row.
      If Claude in Chrome cannot reach the `chrome-extension://` page, ask the operator to click
      **Reinstall**; do not reach for CDP.
- [ ] **A changed `@name` installs a NEW entry** (Violentmonkey matches by namespace + name), so
      the old version keeps running beside it. Remove the old entry from the dashboard: its trash
      icon is the row's last `.btn-ghost` (`<use href="#trash">`). That moves it to the recycle bin
      (`config.removed = 1`), so it can be restored. Confirm with the operator first; it is their
      extension.
- [ ] The script's source of truth is its own repo/listing, **not this tree**. The old sync URL
      `raw.githubusercontent.com/kattakath/nix-config/main/userscripts/<kebab>.user.js` is
      **dead** — there is no `userscripts/` directory here.

## Install reality on this Mac

- **Violentmonkey is force-installed** (`infra/google-workspace/chrome.nix`, Web Store id) into every
  Chrome profile, even though zero scripts are declared.
- **`~/.local/share/userscripts/` no longer exists**, and nothing writes it. Installing means
  navigating to the fork listing.
- One-time per profile, in `chrome://extensions`: **Allow User Scripts** (a manual toggle; no
  policy for it is declared). Add **Allow access to file URLs** only to install from `file://`.
- **Activation is no longer part of the loop.** Publishing changes nothing in the Nix closure, so
  a userscript needs no `activate` at all.

## Live loop — Violentmonkey's own tracking, not injection

The authoring loop runs against a local `file://` copy, tracked by Violentmonkey itself:

1. Open the script's `file://` path in Chrome. Violentmonkey redirects it to its
   `chrome-extension://…/confirm/index.html#<token>` page.
2. On that page click **Track external edits**, then check **Reload tab**. This tab must **stay
   open** — the tracking loop lives in it; closing or navigating it stops detection.
3. Bring the target site's tab to the front. "Reload tab" reloads only the tab Chrome considers
   **active**, a separate axis from window focus — a background tab detects every edit and
   never reloads, which reads like a broken cache and is not one.
4. Edit the file; the tab reloads within tens of seconds.

If Claude in Chrome cannot click on the extension page, the operator clicks steps 1–2 once.
There is **no** document-start injection on this rail, so never "preview" a script by
evaluating its body in a loaded page and call that proof — it runs late, after the site's own
code. Prove it installed.

**Verifying the edit actually landed:** don't only check `document.styleSheets` / `<style>`
tags. A script using **Constructable Stylesheets** (`document.adoptedStyleSheets`) injects CSS
in a way that is invisible to both. Check both surfaces:
```js
[...document.querySelectorAll('style')].some(s => s.textContent.includes(MARKER))
|| [...(document.adoptedStyleSheets||[])].some(s => [...s.cssRules].some(r => r.cssText.includes(MARKER)))
```
Checking only the first gives a false "still stale" reading while the real mechanism already
worked.

## Report format (always end with this)

```markdown
## Userscript report
- **Wish:** (URL + the state asked for)
- **Shelf:** hit-adapted | hit-rejected (why) | empty — (which index/indices were fetched)
- **Measured:** (probes run, `innerWidth` A/B, cross-origin sheet count)
- **Diff verdict:** DOM-DIFFERS | DOM-IDENTICAL | STATE-B-UNREACHABLE
- **Approach:** (attribute set | rules lifted by condition in band X–Y | constructed UI)
- **Selectors shipped:** (each one, with the date measured — or "none")
- **Lint:** `userscript-lab` `userscript-meta-lint.sh` ✅/❌
- **Published:** Greasy Fork | not yet (why) — with the listing URL
- **Operator action:** install from the listing once; it self-updates thereafter
- **Verdict:** SHIPPED | BLOCKED (why) | ESCALATED (vite-plugin-monkey, in the script's own repo)
```

## Compose with existing automation

```
/userscript <site> <wish>  → this skill + userscript-lab:userscript-author
/eval                      → only if a .nix was actually touched (authoring touches none)
/hygiene                   → doc/index drift, if a PR here ever lands
```
