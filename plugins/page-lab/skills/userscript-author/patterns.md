# Userscript patterns — the pre-vetted ladder

**Reference payload, not procedure.** Read it when choosing an API; the loop lives in
[`SKILL.md`](SKILL.md), the instruments in [`probes.md`](probes.md).

**Everything here was verified against primary docs** (violentmonkey.github.io + MDN) on
**2026-08-30**. The last section lists what could **not** be verified — those stay flagged,
never promoted. Do not re-litigate a settled row; if a row is wrong, re-verify and rewrite it.

## Reuse ladder — stop at the first hit

| Rank | Source | Why it wins |
|---|---|---|
| **1** | **Platform web API** | Zero deps, nothing for Nix to pin, the gate sees every byte |
| **2** | **Violentmonkey metadata key** (`@noframes`, `@run-at`, `@match`) | Declarative — the **manager** enforces it, not your code |
| **3** | **`@grant`ed `GM_*` API** | Only when the platform genuinely cannot (cross-origin, storage, menus) |
| **4** | **Vendored source** in `userscripts/` | Nix content-hashes it; the gate `node --check`s it |
| **5** | **`vite-plugin-monkey` build step** | The **deferred** rung — trigger and STOP rule are in `SKILL.md`, not here |
| **✘** | `@require` / `@resource` CDN, `@violentmonkey/*` runtime deps | Install-time fetch, **no SRI/integrity field**, unpinned, invisible to the gate — see § 9 |

---

## 1 · SPA navigation

Violentmonkey injects on **hard** navigation only. `pushState` / `replaceState` / hash route
changes never re-run the script.

**Answer: the Navigation API** — `navigatesuccess`. Baseline **newly available January 2026**;
it is also Violentmonkey's own documented recommendation on its Matching page.

```js
const onRoute = () => { /* MUST be idempotent — runs many times per document */ };

onRoute();                                     // run once up front; do not assume a replay of the initial load
if (self.navigation) {
  navigation.addEventListener('navigatesuccess', onRoute);
} else {                                       // pre-2026 engines only
  let href = location.href;
  new MutationObserver(() => href !== (href = location.href) && onRoute())
    .observe(document, { subtree: true, childList: true });
}
```

- **`navigatesuccess`, never `navigate`.** `navigate` fires when a navigation is **initiated** —
  act on it and you read the **OLD DOM**. `navigatesuccess` fires when a successful navigation
  has **finished** (and after any `intercept()` promises fulfil).
- **Never call `intercept()`** in a userscript. It hands routing to you and fights the site's
  own router.
- **`self.navigation`, not `window.navigation`** — works in page and content contexts alike.
- Verified surface: events `navigate`, `navigatesuccess`, `navigateerror`, `currententrychange`;
  `navigation.currentEntry`, `.transition`, `entries()`, `navigate()`, `reload()`, `back()`,
  `forward()`, `traverseTo()`, `updateCurrentEntry()`.

**Prevents:** the classic "works on reload, dead after clicking a link", and the
500 ms-`setInterval`-polls-`location.href` tax.

---

## 2 · Waiting for an element that does not exist yet

**Answer: `MutationObserver`.** Two shapes only — pick deliberately.

MDN, verbatim: *"At a minimum, one of `childList`, `attributes`, and/or `characterData` must be
`true` when you call `observe()`. Otherwise, a `TypeError` exception will be thrown."*

**One-shot** (element appears once):

```js
const waitFor = (selector, root = document) => new Promise((resolve) => {
  const hit = root.querySelector(selector);
  if (hit) return resolve(hit);               // query FIRST — never observe for something already there
  const obs = new MutationObserver(() => {
    const el = root.querySelector(selector);
    if (!el) return;
    obs.disconnect();                         // disconnect BEFORE resolve — callbacks are batched, a late batch re-enters
    resolve(el);
  });
  obs.observe(root, { childList: true, subtree: true });
});
```

**Persistent** (element is destroyed and rebuilt — every virtualised list):

```js
let queued = false;
const coalesce = (fn) => {                    // a burst of mutations → one run per frame
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => { queued = false; fn(); });
};
new MutationObserver(() => coalesce(apply)).observe(target, { childList: true });
```

| Discipline | Why |
|---|---|
| **Query before you observe** | The node is usually already there at `document-end`/`document-idle` |
| **Narrowest root that can work** | `document` + `subtree: true` over a ~1.8 MB virtualised DOM fires **thousands of times per scroll** |
| **`childList` only** unless you need attrs | `attributes: true` with no `attributeFilter` observes every class flip |
| **Your own writes must not re-trigger you** | Write only when the value differs: `if (el.textContent !== next) el.textContent = next` |
| **Coalesce into one `rAF`** | Caps layout thrash and caps re-entry cost |
| Verified option names | `childList` `subtree` `attributes` `attributeFilter` `attributeOldValue` `characterData` `characterDataOldValue` |

**Prevents:** a leaked observer that outlives the route and burns CPU for the tab's lifetime, and
the self-feeding observer (you mutate → it fires → you mutate → …).

---

## 3 · `@run-at`

Violentmonkey's guarantees, **verbatim**:

| Value | Guarantee | Reach for it when |
|---|---|---|
| `document-start` | *"`document.documentElement` is present, but may be without either `document.head` or `document.body` or both"* | You must beat first paint — CSS injection, patching a global |
| `document-body` (v2.12.10+) | *"Run after `document.body` appears, possibly with some child elements inside, because detection is asynchronous (using a one-time MutationObserver)"* | You need `body` and nothing else |
| `document-end` **(default)** | *"Run when `DOMContentLoaded` is fired, synchronously"* | Ordinary DOM work |
| `document-idle` | *"Run after `DOMContentLoaded` is fired, asynchronously"* | *"Prefer this mode for scripts that take more than a couple of milliseconds to compile and run"* |

- **`document-start` is NOT "runs before the site's JS."** Violentmonkey documents a
  **six-condition** list (page injection mode, Synchronous/Alternative page mode enabled, no CSP
  block, not incognito, cookies not blocked) before it beats page scripts — and that list is
  **MV2-only**. Treat beating the site's own JS as **not guaranteed**.
- At `document-start` there is **no `head`**. Either wait for it, or use `adoptedStyleSheets`
  (§ 4), which needs only `document`.
- Wrapping a `document-start` script in `DOMContentLoaded` **is** `document-end` with extra
  steps. Change the `@run-at` instead.

**Prevents:** flash-of-unstyled-site, `document.head is null` on line 1, and a script that
measurably delays the page becoming usable.

---

## 4 · CSS injection

**Verdict: `document.adoptedStyleSheets` beats both alternatives and needs no grant.**
Baseline **widely available since March 2023**. MDN, verbatim: *"Where the resolution of rules
considers stylesheet order, **`adoptedStyleSheets` are assumed to be ordered after those in
`Document.styleSheets`**."*

```js
// @grant none — no GM API needed
const sheet = new CSSStyleSheet();            // must be the constructor, and this Document's
sheet.replaceSync(css);
document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
// later: sheet.replaceSync(nextCss);         // no DOM churn, no re-append, order preserved
```

| Route | Grant | Cascade position | Cost of an update |
|---|---|---|---|
| **`document.adoptedStyleSheets`** | **none** | **After every `document.styleSheets`** — wins order-based ties permanently | `replaceSync()`, **no DOM mutation** |
| `GM_addStyle(css)` | `@grant GM_addStyle` (returns a `<style>`) | A `<style>` in `head` — **loses to any sheet the site appends later** | Rewrite `.textContent` |
| Hand-appended `head.appendChild(style)` | none | Same as above | Needs a **head observer** just to stay last |

**Gotchas:**
- **`@import` is silently dropped.** MDN: *"If any of the rules passed in `text` are an external
  stylesheet imported with the `@import` rule, those rules will be removed, and a warning printed
  to the console."* Strip/ignore `@import` when lifting site CSS.
- **`replaceSync()` throws `NotAllowedError`** if the sheet was not made with
  `new CSSStyleSheet()`, or is flagged unmodifiable.

**Standing note on `google-photos-icon-nav` v2.0.1:** its head `MutationObserver` exists **only
to fight sheet order** (it re-appends the `<style>` whenever it is no longer `head`'s last
child). `adoptedStyleSheets` makes ordering **structural**, so that observer could shrink to
watching for **new breakpoint rules** — a **v2.1.0 gated on measuring `adoptedStyleSheets` at
`document-start` before `head` exists** (see the flagged list). **Not a change to make blind.**

**Prevents:** the identical-specificity arms race, `!important` inflation, and an observer whose
whole job is stylesheet position.

---

## 5 · Replay the site's own condition

**The lesson, generalised:**

> If the site **already renders the state you want** under some condition **it** controls, do
> **not** reimplement that state. Find the condition and **replay it unconditionally**.

Precedent: `userscripts/google-photos-icon-nav.user.js` v1.x rebuilt the rail by hand and lost
(`overflow-x: hidden` **clips** rather than hides, so every text block had to be hunted; three
still leaked). v2.0.0 lifts Google's own `@media` rules and re-serves them — so the file contains
**not one Google class name**, and JSCompiler churn cannot break it.

**Band, not a pixel** — the reusable shape:

```js
const BAND_MIN = 800, BAND_MAX = 1200;        // excludes the phone layout below and incidental queries above
const CONDITION = /^screen\s+and\s+\(max-width:\s*(\d+)px\)$/;
// walk document.styleSheets → keep every CSSRule.MEDIA_RULE whose conditionText matches and
// whose width lands in the band → bucket ALL matching blocks per width in a Map (several
// separate @media blocks share one breakpoint) → take Math.max(...byWidth.keys()) → join cssText
```

Hardcoding one pixel breaks the day the site retunes its breakpoint; a band survives it.

**Two failure modes to keep handled:**

| Failure | Handling |
|---|---|
| **Cross-origin sheet** — `sheet.cssRules` **throws** (it does **not** return `null`) | `try { … } catch { continue }`, and **degrade to a no-op**: the page renders stock, nothing is mangled. That is the *correct* failure. |
| **Site measures its own geometry** (tile size, thumbnail request width) | Changing pane width leaves the grid laid out for the old one — dispatch **one `rAF`-coalesced** `new Event('resize')` so it re-measures. |

**Two verdicts, from the diff:** **DOM differs** ⇒ set the attribute/class the site itself sets
(cheapest, most durable). **DOM identical** ⇒ the switch is a media query, and **no selector can
force a media query** — lift its rules and re-serve them (§ 4 for delivery).

**Prevents:** the guessed-selector trial-and-error loop, a reimplementation that leaks, and a
script that dies at the site's next compiler run.

---

## 6 · `@grant` selection

**Aim for `@grant none`.** It is the target because reaching it means you found a platform
answer.

Violentmonkey, verbatim: *"If no `@grant` is present, the script is sandboxed with minimum API
access: `GM_info`, `GM.info`, and `unsafeWindow` … this behavior was only introduced in
Violentmonkey 2.32.0"* · *"**In case any special API is used, it must be explicitly granted.**"* ·
`@grant none`: *"Sandbox is disabled in this mode, meaning the script can add/modify globals
directly without the need to use `unsafeWindow`."*

| Need | Grant | Platform alternative |
|---|---|---|
| Inject CSS | `GM_addStyle` | ✅ `document.adoptedStyleSheets` (§ 4) |
| Inject a `<script>`/`<link>` | `GM_addElement` | ✅ `document.createElement` (page context) |
| Persist a setting | `GM_getValue` / `GM_setValue` | ⚠️ `localStorage` — same-origin, site-visible, site-clearable |
| Cross-origin fetch | `GM_xmlhttpRequest` **+ `@connect`** | ✘ none — `fetch` is CORS-bound |
| Toolbar menu command | `GM_registerMenuCommand` | ✘ none |
| OS notification | `GM_notification` | ⚠️ `Notification` — needs a permission prompt |
| Clipboard write | `GM_setClipboard` | ⚠️ `navigator.clipboard` — needs transient activation |
| Open a tab | `GM_openInTab` | ⚠️ `window.open` — popup-blocked without a gesture |
| Download a file | `GM_download` | ⚠️ `<a download>` + `URL.createObjectURL` |
| Read a `@resource` | `GM_getResourceText` / `GM_getResourceURL` | ✘ — and `@resource` is a CDN dep (§ 9) |
| Close / focus the tab | `window.close` (VM 2.6.2+) / `window.focus` (VM 2.12.10+) | ✘ none |

**Complete verified value set** — `none`, `window.close`, `window.focus`, plus:
`GM_info` `GM_cookie` `GM_getValue` `GM_getValues` `GM_setValue` `GM_setValues` `GM_deleteValue`
`GM_deleteValues` `GM_listValues` `GM_addValueChangeListener` `GM_removeValueChangeListener`
`GM_getResourceText` `GM_getResourceURL` `GM_addElement` `GM_addStyle` `GM_openInTab`
`GM_registerMenuCommand` `GM_unregisterMenuCommand` `GM_notification` `GM_setClipboard`
`GM_xmlhttpRequest` `GM_download` — and the `GM.*` aliases (VM 2.12.10+): `GM.addStyle`
`GM.addElement` `GM.cookie` `GM.registerMenuCommand` `GM.deleteValue` `GM.deleteValues`
`GM.download` **`GM.getResourceUrl`** (note the lowercase `rl`) `GM.getValue` `GM.getValues`
`GM.info` `GM.listValues` `GM.notification` `GM.openInTab` `GM.setClipboard` `GM.setValue`
`GM.setValues` `GM.xmlHttpRequest`.

**Two traps:**
- **`GM_log` is not documented** by Violentmonkey. Use `console.log`.
- **`@grant unsafeWindow` is not a documented Violentmonkey privilege** — `unsafeWindow` is
  already in the default sandboxed set. Tampermonkey accepts it; VM's page does not list it.

Also: `@grant none` puts you in **page context**, so a `window.__myFlag` guard is shared with the
page; sandboxed, it lands on the sandbox global (§ 8). `@inject-into` values are `page` /
`content` / `auto` (default — *"Try to inject into context of the web page. If blocked by CSP
rules, inject as a content script"*); leave it unset unless CSP forces your hand.

**Prevents:** a silently-ineffective typo'd grant (the gate does **not** check grant values), and
a `GM_*` dependency where a no-grant platform API existed.

---

## 7 · `@match` vs `@include`, and frames

Violentmonkey: *"It is recommended to use `@match` / `@exclude-match` rather than `@include` /
`@exclude` because the match rules are safer and more strict."* `@include` is *"the old way"*.

**`@match` semantics, verbatim:** *"match patterns only work on scheme, host and path, i.e. match
patterns always **ignore query string and hash**"*. VM ≥ 2.10.4 adds: `http*` matches `http` or
`https`; host-part `*` at any position (`www.google.*`); host-part `.tld` matches any TLD suffix.

**⇒ You cannot match on `?query` or `#hash` — gate the query in code**, or the script runs
broader than the header reads.

**Precedence, verified order:**

1. Any `@exclude-match` / `@exclude` matches → **no match** (excludes always win).
2. Else if any `@match` is defined → matches only if some `@match` matches.
3. Else fall back to `@include`.
4. **Neither defined ⇒ the script matches EVERYTHING.**

| Trap | Consequence |
|---|---|
| No `@match` and no `@include` | Runs on **every page**, including your bank |
| `@include /regex/` | A slash-delimited value is compiled as a **regular expression** — a stray `/` changes the meaning entirely |
| Omitting `@noframes` | Runs in **every nested iframe** — ad frames, embeds, OAuth popups. N copies, N observers. |

**`@noframes` is the declarative idempotence lever:** *"When present, the script will execute only
in top level document, but not in nested frames."* Default to present unless the job **is** inside
a frame.

**Prevents:** a script that quietly runs everywhere, and N duplicate observers from iframes.

---

## 8 · Idempotence / double-injection guards

**Assume top-level code runs more than once per tab** — nested frames without `@noframes`, a VM
script reload after an edit, a second script manager installed, a `bfcache` restore.

| Layer | Mechanism | Catches |
|---|---|---|
| **Declarative** | **`@noframes`** | Frame duplication — do this first |
| **Realm-crossing** | **`data-*` marker on `documentElement`** | Two injections in different JS realms |
| Same realm | `window.__nixFoo` flag | Same-realm re-run — **unreliable under the sandbox** (§ 6) |
| Per-node | `if (el.dataset.nixDone) return; el.dataset.nixDone = ''` | Re-processing rows in a virtualised list |
| Write-guard | `if (el.textContent !== next) el.textContent = next` | Your own observer feeding itself |

```js
if (document.documentElement.dataset.nixFooBar !== undefined) return;
document.documentElement.dataset.nixFooBar = '';
```

Also: **hold ONE `sheet` / ONE `styleEl` at module scope and reuse it.** Creating one per run is
how a tab ends up with 40 stylesheets.

**Prevents:** duplicated buttons, N-times-firing handlers, observer feedback loops, and unbounded
memory growth on a long-lived tab.

---

## 9 · What NOT to do

| Anti-pattern | Why it is rejected |
|---|---|
| **`@require <cdn url>`** | Fetched **at install time** into extension storage ⇒ **nothing pins it and no lint sees it**. **No SRI/integrity field exists.** And VM: *"Local files are not allowed to be required due to security concern."* Reuse must enter at **build** time or as **vendored** source. |
| **`@resource <cdn url>`** | Same channel, same hole — install-time fetch, unpinned, invisible to any lint. |
| **`@violentmonkey/dom`'s `VM.observe`** | A ~6-line `MutationObserver` wrapper — § 2 is the wrapper. Not worth a runtime CDN dep. |
| **`@violentmonkey/url`'s `onNavigate`** | Superseded by the Navigation API (§ 1). Use the platform. |
| **Minified / bundled output** | Unreviewable in review, unreadable in a diff, and **Greasy Fork rejects it outright** (its Code rule: scripts "must not be obfuscated or minified"). Ship readable source. |
| **`@downloadURL` / `@updateURL` / `@installURL`** | **Banned by `userscript-meta-lint.sh`.** Greasy Fork strips them on upload, so they are inert once shared; pointed at your own repo they let a push to the default branch mutate an installed script with no review. VM falls back to `lastInstallURL` — wherever the file was installed from. |
| **Any secret, token, or cookie value** | A userscript is plain text that ships to the browser, and most delivery mechanisms copy it somewhere world-readable (the Nix store, a public repo, Greasy Fork itself). A private repo is not a secret store. |
| **Hardcoded site class names when a condition exists** | § 5. JSCompiler churn breaks it on the site's next deploy. |
| **`setInterval` polling for a URL or an element** | § 1 and § 2 are the event-driven answers. |
| **`document` + `subtree: true` on a virtualised list** | Thousands of callbacks per scroll. |
| **`!important` escalation** | § 4 — `adoptedStyleSheets` gives you **order**, which is what you actually wanted. |
| **`@version 1.2a.3`** | Violentmonkey's own grammar allows an alpha suffix; **`userscript-meta-lint.sh` does not** (`^[0-9]+(\.[0-9]+)*$`), because Greasy Fork rejects a `@version` it cannot order. Copying VM's example fails the lint. |

**Prevents:** an unpinned supply chain no lint can see, an unreviewable diff, a script that a
`git push` can mutate under you, and a secret shipped in plain text.

---

## 10 · Lint contract — mechanised vs author discipline

**`scripts/userscript-meta-lint.sh` (bundled with this plugin) mechanises:** `node --check`; the
`==UserScript==` block **only** (so a `@key` in prose or in a regex neither satisfies nor trips a
rule); **requires** `@name` `@namespace` `@version` `@description` `@license` `@match`
`@homepageURL` `@supportURL`; **bans** `@downloadURL` `@updateURL` `@installURL`; `@version` must
be **dotted-numeric**; and any **vendored** third-party block must carry a source attribution
comment (Greasy Fork's Code rule). Run it in your own CI — see the plugin README.

**Not mechanised — carry it yourself:**

| Unchecked | Rule to self-apply |
|---|---|
| `@grant` **values** | Must come from § 6's verified set — a typo grants nothing, **silently** |
| `@match` over `@include` | § 7 |
| Blank line before code | After `// ==/UserScript==` |
| `@noframes` presence | § 7 / § 8 — default to present |
| `@connect` alongside `GM_xmlhttpRequest` | Required for cross-origin; not gated |
| `@require` **absence** | § 9 — the gate deliberately does not look |

`eslint-plugin-userscripts` covers roughly this same residue; it is **not** adopted here (its
rule ids are not re-verified — see below), so the rules above are prose discipline.

**Prevents:** believing a green gate proved something it never looked at.

---

## 11 · Targets `document.querySelector` cannot reach

A selector that is unique and correct in the picker can still be **unreachable from a
userscript**, because `document.querySelector` does not cross a shadow boundary or a frame
boundary. The pick envelope's **`reachability`** field is what routes this decision —
`document` · `shadow` · `frame` · `shadow-in-frame` — and anything but `document` arrives
carrying its own ship blocker ([`SKILL.md`](SKILL.md) hard rule 6).

### Shadow-root targets (`reachability: "shadow"`)

Walk in explicitly, one hop per boundary, and **guard every hop** — the host may not exist
yet, and the root may not be open:

```js
const host = document.querySelector('media-player');   // measured, dated in the WHY block
const root = host && host.shadowRoot;                  // null on a CLOSED root
const el   = root && root.querySelector('.volume');
if (!el) return;                                       // degrade to stock, never mangle (§ 5)
```

- **A closed shadow root is unreachable, full stop.** `host.shadowRoot` is `null` and no
  userscript API opens it. The pick is **abandoned or re-scoped to the host** — style the host,
  or use a `::part()` / custom-property hook if the component exposes one. Do not ship a
  selector that can only ever match `null`.
- **CSS does not pierce either.** A `document`-level stylesheet — including
  `adoptedStyleSheets` (§ 4) — does not style inside a shadow root. To style in, adopt onto
  **that root**: `root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet]`.
- **The host is the durable half.** A component's internals are its private API and churn
  freely; the host element's tag name rarely does. Prefer the outermost node that achieves the
  wish.

### Cross-frame targets (`reachability: "frame"`)

The node lives in a nested document, so a top-level script never sees it. Two changes, both
required, neither sufficient alone:

1. **`@match` the frame's own URL** — the envelope's `frameUrl` is that value. The top page's
   `@match` does not cover its frames.
2. **Drop the default `@noframes`** (§ 7), or the script is declined in the very frame it
   targets.

Consequences to accept before doing this, not after:

- Dropping `@noframes` means the script runs in **every** matching frame — ad frames, embeds,
  OAuth popups. The `@match` must be narrow enough that this is the frame you meant, and § 8's
  idempotence guards become load-bearing rather than belt-and-braces.
- **`@match` ignores query string and hash** (§ 7). A frame identified only by its query is not
  addressable by `@match`; gate it in code (`location.search`) and expect the script to be
  *loaded* into sibling frames it then no-ops in.
- `shadow-in-frame` is both problems at once: match the frame, drop `@noframes`, then walk the
  shadow chain inside it.

**Prevents:** shipping a measured, verified, genuinely-unique selector that returns `null` on
every real page load — the failure that looks hardest like "the site changed".

---

## 12 · Live-edit loop — Violentmonkey tracks a file on disk

*Track external edits* turns each save into an auto-reinstall plus a tab reload, so post-install
proof (`SKILL.md` step G) is one save away instead of one install away.
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
   nothing is *not* a version problem: check gotcha 1 and the `Install`-vs-`+ Track` trap
   first. The committed state still gets a bump (`SKILL.md` § Editing an existing script).
3. **Stop tracking when done**, or the next install fights it.

`FileSystemObserver` (instant, no polling) needs **Chromium 133+**; older builds poll.

**Prevents:** a debugging session spent on code that the browser never re-read.

---

## Flagged — NOT verified from primary docs

**Unverified. Do not promote a row without re-verifying it, and do not cite one as settled.**

| Claim | Status |
|---|---|
| Whether `navigation` is exposed in the **content-script isolated world** (`@inject-into content`) | **Not documented** by VM or MDN. The `self.navigation` guard in § 1 makes it moot; measure empirically if a script must use `content`. |
| Whether `navigate` / `navigatesuccess` fires for the **initial document load** | MDN does not state it either way. VM's own snippet calls the handler once up front, so treat **"does not replay the initial load"** as the safe contract. |
| `document.adoptedStyleSheets` **at `document-start`**, before `head` exists | Spec-wise it needs only `document`, which exists at `document-start` — but **not measured on a live page**. This is the gate on the § 4 v2.1.0 note. |
| `eslint-plugin-userscripts` **exact rule ids** | Carried from earlier ecosystem notes, **not re-verified**. Never quote a rule id as exact. |
