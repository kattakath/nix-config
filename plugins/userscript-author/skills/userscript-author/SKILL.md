---
name: userscript-author
description: >
  Author and maintain a Violentmonkey/Tampermonkey userscript for a Chromium
  browser, to a standard that can be published on greasyfork.org. Use when
  asked to "make <site> do X", "write a userscript for <site>", "fix my <site>
  script", "this site's X annoys me", or "publish my userscript". Owns the
  judgment no linter can carry, under one invariant: MEASURE. Never ship a
  selector, class, or breakpoint that was not dumped from the live page.
---

# Userscript author — measure → replay → write → lint → publish

**What this skill is for:** the authoring *judgment* — is the state you want **already
rendered** by the site, which selectors are **real**, and what gets **asked** instead of
guessed. The mechanical half is `scripts/userscript-meta-lint.sh` (bundled); the browser
instruments are [`probes.md`](probes.md); the pre-vetted code shapes are
[`patterns.md`](patterns.md); the publishing rulebook is [`greasyfork.md`](greasyfork.md).

```
wish → shelf → measure A vs B → diff → replay-or-select → write → lint → publish
```

**Delivery is out of scope.** How the file reaches the browser — hand-install, a dotfiles
repo, Nix, a build step — is yours. This skill stops at a lint-clean file.

## Hard rules

1. **Never `@require` / `@resource` from a CDN.** Fetched at install time, **no SRI or
   integrity field exists**, and nothing pins it. Violentmonkey also refuses local files
   ("not allowed to be required due to security concern"). Reuse enters as **vendored
   source** — which Greasy Fork explicitly permits, *provided* the vendored block carries
   name/version/URL attribution ([`greasyfork.md`](greasyfork.md) § The `@require` tension).
2. **Every selector shipped is listed in the file's own WHY block with the date it was
   measured.** A **template-literal selector containing `${`** is banned: untraceable to a
   measurement.
3. **`@grant none` is the target.** Every grant must come from the verified value set in
   [`patterns.md`](patterns.md) § 6 — no linter checks grant *values*, so **a typo grants
   nothing, silently**.
4. **`@match` + `@noframes` by default** ([`patterns.md`](patterns.md) § 7). `@downloadURL` /
   `@updateURL` / `@installURL` are **lint-enforced bans** — see [`greasyfork.md`](greasyfork.md).
5. **Never a secret.** A userscript is plain text that ships to the browser and usually gets
   copied somewhere world-readable. A private repo is not a secret store.

## Checklist (run in order)

### 0. Check the shelf first — reuse over rebuild

Authoring is the **fallback**, not the default. Both script hosts publish a free, no-auth
**by-site index**, so "has someone already solved this for this domain" is one fetch, not a search:

```
https://greasyfork.org/en/scripts/by-site/<domain>
https://sleazyfork.org/en/scripts/by-site/<domain>
```

- [ ] Fetch the **Greasy Fork** index for the bare domain (`civitai.com`, not `www.civitai.com`).
- [ ] If the site is adult-adjacent, fetch the **Sleazy Fork** index too — the two are **one
      codebase** sharing one rule set, and a site's scripts land on **only one** of them, so
      checking Greasy Fork alone can read as "nothing exists" when a script does.
- [ ] A hit is **evidence, not a dependency.** You still cannot `@require` it (hard rule 1) and
      must not paste it unread. Read it for its **measured selectors and its condition** — that
      is the reusable part — then vendor it *with attribution*, or re-derive it.
- [ ] Record the outcome — **shelf hit (adapted) / shelf hit (rejected, why) / shelf empty**.
      "Nobody looked" and "nothing exists" must not read the same.

### A. Frame the wish

- [ ] Which **exact URL** (it becomes `@match`), and which **state is "good"**?
- [ ] Is that good state reachable **without any code** — narrow the window, alternate route,
      a site toggle? If yes, the job may be a bookmark, not a script. Greasy Fork's own
      Functionality rule: a script must "have a reason to be a script".
- [ ] Anything a stated preference does not cover → **ask**, do not infer. Colour, typography,
      density, motion and "which furniture goes" are never obvious.

### B. Measure state A (what the site gives you)

- [ ] Run **`dumpSubtree(rootSelector)`** from [`probes.md`](probes.md); keep the JSON.
- [ ] Run **`mediaRules()`**; note the `crossOrigin` count — a high one means the replay
      route may be unavailable.

### C. Measure state B (the good state)

- [ ] Put the page in state B, then re-run **`dumpSubtree`** on the same root, recording
      `innerWidth`.
- [ ] **Prefer `resize_page`** (the `chrome-devtools` plugin) when the trigger is a width —
      it is exact, repeatable and bisectable, which makes finding the actual breakpoint band
      cheap. `emulate` changes several variables at once, so it answers "does this work on a
      phone", not "which breakpoint fires". Without that server, do it **by hand** (resize /
      route / toggle) — the measurement is what matters, not who took it.

### D. Diff → verdict

- [ ] Run **`diff(a, b)`** from [`probes.md`](probes.md). An **empty diff is the finding**,
      not a failure.

| Verdict | What it means | What you write |
|---|---|---|
| **DOM-DIFFERS** | the site itself sets an attribute/class/`data-*` | Set **that** attribute — cheapest and most durable |
| **DOM-IDENTICAL** | the switch is a **pure media query**; **no selector can force a media query** | Lift its rules and re-serve them unconditionally |
| **STATE-B-UNREACHABLE** | state B does not exist — you are **constructing** UI | Every invented selector needs its own measured line in the WHY block |

- [ ] On DOM-IDENTICAL, lift **by condition in a band, never a hardcoded pixel**, accumulating
      **every block** at each width before picking one ([`patterns.md`](patterns.md) § 5).
- [ ] **Reimplementing a state the site already renders is the classic loss.** `overflow-x:hidden`
      *clips* rather than hides, so every text-only block has to be chased by hand and some always
      leak. Lifting the site's own `@media` rules ships with **not one** of its class names.

### E. Write the body

- [ ] Work **down the reuse ladder** in [`patterns.md`](patterns.md), stopping at the first hit:
      platform web API → metadata key → granted `GM_*` → vendored source. Take the navigation,
      waiting, CSS-injection and idempotence shapes from there; do not improvise them.
- [ ] Open the WHY block with the **measured finding, one sentence**, then the dated selectors.
- [ ] **Degrade to stock, never mangle.** A script that cannot do its job becomes a no-op.

### F. Lint

```bash
scripts/userscript-meta-lint.sh <file.user.js>      # or a directory
```

Checks `node --check`, the required and banned metadata keys, dotted-numeric `@version`,
minified/bundled output, and vendored-code attribution. What it **cannot** check is in
[`patterns.md`](patterns.md) § 10 — carry that yourself.

### G. Prove it after install

- [ ] Re-run **`assertEffect()`** + **`dumpSubtree`** from [`probes.md`](probes.md) and **diff
      against the recorded state B**. Eyeballing is not a check.
- [ ] A missing marker usually means the script **never ran** — check the browser toggles in
      § Install reality before touching code.

### H. Publish

See [`greasyfork.md`](greasyfork.md) — the rulebook, the metadata contract, adult-content
marking, and how to make a `git push` the release without `@updateURL`.

### I. Escalation trigger (do not grow a bundler)

- [ ] **≥ 4 scripts**, **or** the first TS/JSX need, **or** `GM_*` plus a settings UI ⇒ **STOP.**
      Ship nothing; propose adopting **`vite-plugin-monkey`** as its own change.
- [ ] Never hand-roll a build step, never commit minified or bundled output (Greasy Fork
      rejects it, and the lint fails it).

## Editing an existing script

- [ ] **Bump `@version` first** — dotted-numeric; a same-version re-install is a **silent no-op**.
- [ ] **Re-measure before re-writing** (steps B–D) — the page changed, your memory of it did not.
- [ ] Re-run the lint (step F) and re-prove it (step G).

## Install reality (Chromium)

- One-time per profile, in `chrome://extensions` → the script manager's details page:
  **Allow User Scripts** and, for a `file://` install, **Allow access to file URLs**.
  Chrome **138+** gates the first behind a per-extension toggle a policy cannot set; before
  138 it rides on **Developer mode**. This is the `chrome.userScripts` API's own requirement —
  it is what the *manager extension* uses to inject, not something a script author calls.
- An agent **cannot** install a script, flip a toggle, or drive the manager's dialog. That
  click is always the operator's.

## Live-edit loop (Violentmonkey tracks a file on disk)

Violentmonkey's *Track external edits* turns each save into an auto-reinstall plus a tab
reload, so step G is one save away instead of one install away.
Upstream: <https://violentmonkey.github.io/posts/how-to-edit-scripts-with-your-favorite-editor/>

1. Open Violentmonkey's **Dashboard** and **drag** the `.user.js` onto that page.
2. Tick **Reload tab**, then click the **`+ Track external edits`** BUTTON (or `⌘Enter`).
3. **Leave the installer tab open** for the whole session — upstream: it is "used to read the
   contents of the file".

**Click the button, NOT `Install`.** `+ Track…` is an install **variant**, not a checkbox that
modifies `Install`: ticking it and then pressing `Install` installs **without** tracking,
silently. No error, no indicator — saves simply never land, which reads exactly like a broken
script.

**Gotchas, in the order they bite:**

1. **Any git write to the tracked file KILLS tracking — silently.** Not just a branch switch:
   `checkout`, `pull`, `stash`, `rebase`, a revert. Git does not rewrite in place, it **unlinks
   and replaces**, and the manager's handle stays bound to the dead inode. Nothing reports it.
   Re-drag to resume. On a day with git traffic, serve the file over HTTP instead
   (`python3 -m http.server`) — a URL is re-fetched and does not care about inodes.
2. **A tracked save does NOT need a `@version` bump** — upstream: "each time you save the file
   in your external editor the changes are automatically incorporated". So a save that does
   nothing is *not* a version problem: check gotcha 1 and the `Install`-vs-`+ Track` trap first.
   The committed state still gets a bump (§ Editing an existing script).
3. **Stop tracking when done**, or the next install fights it.

`FileSystemObserver` (instant, no polling) needs **Chromium 133+**; older builds poll.

## Anti-patterns

1. `@require` / `@resource` from a CDN — [`patterns.md`](patterns.md) § 9.
2. `setInterval` polling for a URL or an element — § 1, § 2.
3. `document` + `subtree: true` on a virtualised list — § 2.
4. `!important` escalation to win the cascade — § 4.
5. Hardcoded generated class names when a condition exists — § 5.

## Report format (always end with this)

```markdown
## Userscript report
- **Wish:** (URL + the state asked for)
- **Shelf:** hit-adapted | hit-rejected (why) | empty — (which index/indices were fetched)
- **Measured:** (probes run, `innerWidth` A/B, cross-origin sheet count)
- **Diff verdict:** DOM-DIFFERS | DOM-IDENTICAL | STATE-B-UNREACHABLE
- **Approach:** (attribute set | rules lifted by condition in band X–Y | constructed UI)
- **Selectors shipped:** (each one, with the date measured — or "none")
- **Lint:** ✅/❌
- **Operator action:** (install / toggle / publish — whatever a human must click)
- **Verdict:** SHIPPED | BLOCKED (why) | ESCALATED (vite-plugin-monkey)
```
