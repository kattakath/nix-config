---
name: userscript-author
description: >
  Author, declare, and gate a Violentmonkey userscript in this repo: the file
  `userscripts/<kebab>.user.js` plus its one-line entry in
  `programs.ungoogledChromium.userScripts.scripts`
  (`modules/shared/home.nix`). Use when asked to "make <site> do X", "write a
  userscript for <site>", "fix my <site> script", "this site's X annoys me",
  or "give me <site>'s compact layout at full width". Delivery belongs to
  `modules/shared/chromium.nix` and the metadata contract to
  `checks.<system>.userscripts` — this skill owns only the judgment neither
  can carry, under one invariant: MEASURE. Never ship a selector, class, or
  breakpoint that was not dumped from the live page.
---

# Userscript author — measure → replay → declare → gate → install

**Floor (already automated):** Nix materialises every declared script to
`$XDG_DATA_HOME/userscripts/<key>.user.js` plus a generated `index.html`
(`modules/shared/chromium.nix`); `checks.<system>.userscripts` runs `node --check` and enforces
the metadata block on every PR, on both systems.

**This skill:** the authoring judgment — is the state you want **already rendered** by the site,
which selectors are **real**, and what gets **asked** instead of guessed.

```
wish → shelf → measure A vs B → diff → replay-or-select → write → git add -A → gate → PR → activate → one click
```

## Standing preferences (thin by design — append, never invent)

| # | Statement | Confidence | Evidence |
|---|---|---|---|
| **UI-1** | Give me **the site's own compact/narrow chrome at full width** — navigation shrinks, content takes the reclaimed space. | **VERIFIED** | the entire purpose of `userscripts/google-photos-icon-nav.user.js` |
| **UI-2** | **Degrade to stock, never mangle.** A script that cannot do its job becomes a no-op. | **VERIFIED** | that script's own comment: "the page renders stock, nothing is mangled" |
| **M-1** | **Never reimplement a state the site already renders** — find its condition and replay it. | **VERIFIED** (method) | the v1.x → v2.0.0 rewrite of that same script |

- **Correction, load-bearing:** the 80px rail, the hover peek-back, the hidden storage footer and
  the 1px `Collections` divider are **Google's own design at its own breakpoint**, inherited as
  **one package** under UI-1 — **not** four separately stated preferences.
- Any preference **not in that table** is **asked via AskUserQuestion** (click-to-select,
  recommended first), never inferred — colour, typography, density, motion and "which furniture
  goes" are unstated. A row is **appended only after a shipped script proves it**.

## Hard rules

1. **Seed from the gated script, delete its body** —
   `cp userscripts/google-photos-icon-nav.user.js userscripts/<kebab>.user.js`. That file is
   checked by CI on every PR, so its header is correct **by construction**; never hand-type a
   metadata block. Keep the block, retarget `@name` / `@description` / `@match`, **reset
   `@version` to `1.0.0`**, and **DELETE THE BODY** — it is a `document-start` CSS-replay
   script, so its `@run-at` and style-injection shape are **wrong** for a DOM script
   (`patterns.md` § `@run-at`).
2. **Never `@require` / `@resource`.** Install-time CDN fetch, **no SRI/integrity field**, Nix
   never pins it, the gate deliberately does not look, and Violentmonkey forbids local files —
   reuse enters as **vendored source** in `userscripts/` or not at all (`patterns.md` § What NOT
   to do).
3. **Every selector shipped is listed in the file's own WHY block with the date it was
   measured** — `userscripts/google-photos-icon-nav.user.js` opens with its measured finding.
   A **template-literal selector containing `${`** is banned: untraceable to a measurement.
4. **`@grant none` is the target.** Every grant must come from the verified value set in
   `patterns.md` § `@grant` — the gate does **not** check grant values, so **a typo grants
   nothing, silently**.
5. **`@match` + `@noframes` by default** (`patterns.md` § `@match` vs `@include`).
   `@downloadURL` / `@updateURL` / `@installURL` are **gate-enforced bans** — the reasoning
   lives in `flake.nix` § `checks.<system>.userscripts`; don't re-derive it.
6. **Never a secret** — `source` is copied into the **world-readable Nix store**, private flake
   or not (`modules/shared/chromium.nix`).
7. Follow [git-purity](../../rules/git-purity.md) + [pr-title](../../rules/pr-title.md); the index
   is root [`CLAUDE.md`](../../../CLAUDE.md), long form
   [`docs/repo-map.md`](../../../docs/repo-map.md) § `userscripts/`.

## Checklist (run in order)

### 0. Check the shelf first — reuse over rebuild

Authoring is the **fallback**, not the default. Both script hosts publish a free, no-auth
**by-site index**, so "has someone already solved this for this domain" is one fetch, not a search:

```
https://greasyfork.org/en/scripts/by-site/<domain>     # verified reachable 2026-08-31
https://sleazyfork.org/en/scripts/by-site/<domain>     # same codebase; where adult-adjacent sites land
```

- [ ] Fetch the **Greasy Fork** index for the bare domain (`civitai.com`, not `www.civitai.com`).
- [ ] If the site is adult-adjacent, fetch the **Sleazy Fork** index too — the two are **one
      codebase** sharing one rule set, and a site's scripts land on **only one** of them, so
      checking Greasy Fork alone can read as "nothing exists" when a script does.
- [ ] A hit is **evidence, not a dependency.** You still cannot `@require` it (hard rule 2) and
      must not paste it unread. Read it for its **measured selectors and its condition** — that is
      the reusable part — then vendor or re-derive under this repo's header.
- [ ] **Do not reach for a paid scraper.** The Apify store's `greasy-fork-scraper` (2 users,
      pay-per-event) buys nothing the by-site URL above gives free. Checked 2026-08-31.
- [ ] Record the outcome — **shelf hit (adapted) / shelf hit (rejected, why) / shelf empty** — in
      the report. "Nobody looked" and "nothing exists" must not read the same.

### A. Frame the wish

- [ ] Which **exact URL** (it becomes `@match`), and which **state is "good"**?
- [ ] Is that good state reachable **without any code** — narrow the window, alternate route,
      a site toggle? If yes, UI-1 + M-1 apply and step D is cheap.
- [ ] Anything the table does not cover → **AskUserQuestion**, recommended option first.

### B. Measure state A (what the site gives you)

- [ ] Run **`dumpSubtree(rootSelector)`** from `probes.md`; keep the JSON.
- [ ] Run **`mediaRules()`**; note the `crossOrigin` count — a high one means the replay
      route may be unavailable.

### C. Measure state B (the good state)

- [ ] Put the page in state B **by hand** (resize / route / toggle), then re-run
      **`dumpSubtree`** on the same root, recording `innerWidth`.

### D. Diff → verdict

- [ ] Run **`diff(a, b)`** from `probes.md`. An **empty diff is the finding**, not a failure.

| Verdict | What it means | What you write |
|---|---|---|
| **DOM-DIFFERS** | the site itself sets an attribute/class/`data-*` | Set **that** attribute — cheapest and most durable |
| **DOM-IDENTICAL** | the switch is a **pure media query**; **no selector can force a media query** | Lift its rules and re-serve them unconditionally |
| **STATE-B-UNREACHABLE** | state B does not exist — you are **constructing** UI | Every invented selector needs its own measured line in the WHY block |

- [ ] Precedent: **v1.x reimplemented the rail and lost** because `overflow-x:hidden` **clips
      rather than hides** — three text blocks still leaked; **v2.0.0** lifts Google's own
      `@media` rules and contains **NOT ONE Google class name**.
- [ ] On DOM-IDENTICAL, lift **by condition in a band, never a hardcoded pixel**, accumulating
      **every block** at each width before picking one (`patterns.md` § Replay).

### E. Write the body

- [ ] Work **down the reuse ladder** in `patterns.md`, stopping at the first hit: platform web
      API → metadata key → granted `GM_*` → vendored source. Take the navigation, waiting,
      CSS-injection and idempotence shapes from there; do not improvise them.
- [ ] Open the WHY block with the **measured finding, one sentence**, then the dated selectors.

### F. Declare it

- [ ] Add **exactly one line** — `<kebab> = ../../userscripts/<kebab>.user.js;` — inside the
      existing `scripts = { … };` attrset of `modules/shared/home.nix`. Nothing else changes.
- [ ] A `../../` **source literal is repo-relative, correct and idiomatic — never "fix" it to a
      home path.**
- [ ] **Key collision:** nix-personal's private keys are **invisible from this repo**, and the
      module system treats a repeated key as a **conflict, not an override** — **ASK the
      operator** before claiming a plausible name.

### G. Gate

```bash
git add -A
nix build .#checks.aarch64-darwin.userscripts
nix fmt
git add -A                        # fmt may rewrite
git status --porcelain '*.nix'    # clean of ??
nix flake check
```

- [ ] If `nix` is unavailable: `node --check` the script, `nix-instantiate --parse` the changed
      `.nix`, and state the rest is **CI-deferred**.
- [ ] **A private (nix-personal) script is NOT covered by that check.** It globs
      `${self}/userscripts/*.user.js` — this repo's tree only. Owning the *option* does not gate
      the consumer, and **the build still goes green**, which is the trap. Measured 2026-08-31:
      nix-personal's `civitai-declutter` had shipped with **no `@license`** and the check never
      saw it. For a private script, run `node --check` **and** mirror the metadata assertions by
      hand — required keys are `@name @namespace @version @description @license @match`
      (`@match` specifically, **not** `@include`), `@version` must be plain dotted-numeric, and
      `@downloadURL`/`@updateURL`/`@installURL` are banned.

### H. Prove it after install

- [ ] Re-run **`assertEffect()`** + **`dumpSubtree`** from `probes.md` and **diff against the
      recorded state B**. Eyeballing is not a check.
- [ ] A missing marker usually means the script **never ran** — check the toggles in § Install
      reality before touching code.

### I. Escalation trigger (do not grow a bundler)

- [ ] `ls userscripts/*.user.js | wc -l` at **≥ 4**, **or** the first TS/JSX need, **or** `GM_*`
      plus a settings UI ⇒ **STOP.** Ship nothing; propose adopting **`vite-plugin-monkey`** as
      its **own PR**.
- [ ] Never hand-roll a build step, never commit minified or bundled output.

## Editing an existing script

- [ ] **Bump `@version` first** — dotted-numeric; a same-version re-install is a **silent no-op**.
- [ ] **Re-measure before re-writing** (steps B–D) — the page changed, your memory of it did not.
- [ ] Re-run the gate (step G) and re-prove it (step H).

## Install reality (no Nix↔Violentmonkey bridge)

- Activation is the operator's move: **`activate`** from nix-personal — **NEVER**
  `darwin-rebuild switch --flake .#macos` from this repo.
- It rewrites `~/.local/share/userscripts/` + `index.html`, and **never touches Violentmonkey's DB.**
- One-time per profile, in `chrome://extensions`: **Allow User Scripts** + **Allow access to
  file URLs** (Chrome 138+ refuses to let policy set the first).
- A **click-through in `index.html` is required for a new script and after every edit** — Claude
  cannot install a script, flip a toggle, or drive Violentmonkey's dialog. Fallback if the
  `file://` install is refused: paste the file into Violentmonkey's editor.
- That per-edit click-through is the **untracked** default. § Live-edit loop removes it for the
  duration of an authoring session.

## Live-edit loop (Violentmonkey tracks the repo file)

For an **iterative** session — many saves against one page — Violentmonkey's *Track external
edits* turns each `Cmd-S` into an auto-reinstall plus a tab reload, so step H's re-measure is
one save away instead of one click-through away.
Upstream: <https://violentmonkey.github.io/posts/how-to-edit-scripts-with-your-favorite-editor/>

**Track the repo file, never the materialised one** (measured 2026-08-31):

| Path | Mode | Track it? |
|---|---|---|
| `userscripts/<kebab>.user.js` (repo) | `-rw-r--r--` | **YES** — the only writable copy |
| `$XDG_DATA_HOME/userscripts/<kebab>.user.js` | symlink → `/nix/store/…` | **no** — read-only build artifact |
| `$XDG_DATA_HOME/userscripts/index.html` | symlink → `/nix/store/…` | **no** — that is the *install* path, and it installs the read-only copy |

**Setup** — drag-and-drop, which needs **no** "Allow access to file URLs":

1. Open Violentmonkey's **Dashboard**.
2. **Drag** `userscripts/<kebab>.user.js` onto that page.
3. In the installer: **Track external edits**, then tick **Reload tab**.

`FileSystemObserver` (instant, no polling) requires **Chrome/Chromium 133+**; this host measured
**152.0.7977.64** on 2026-08-31. On an older build the same drag still works, just polled.

**Gotchas, in the order they bite:**

1. **Stop tracking before switching git branches.** A checkout rewrites the file underneath
   Violentmonkey, which installs whatever the other branch held. Branch churn in this repo is
   routine, so this is the common failure — not a hypothetical.
2. **The gate cannot see an unstaged edit.** `checks.<system>.userscripts` globs
   `${self}/userscripts/*.user.js` — the **git tree**. Finish with step G (`git add -A` first),
   not with a green browser.
3. **The materialised copy is stale for the whole session.** Expected. Reconcile at the end:
   step G, then `activate`.
4. **Stop tracking when done**, or the next `activate` / branch switch fights it.
5. **`@version` still gets bumped for the committed state** (§ Editing an existing script).
   Whether a *tracked* save needs a bump to take effect is **unverified** — if a save appears to
   do nothing, bump and re-save before suspecting the code.

Alternative if the drag is awkward — a localhost server, polled rather than observed:

```bash
cd userscripts && python3 -m http.server 8080   # then open http://localhost:8080/<kebab>.user.js
```

## Anti-patterns

1. `@require` / `@resource` from a CDN — `patterns.md` § What NOT to do.
2. `setInterval` polling for a URL or an element — § SPA navigation, § Waiting for an element.
3. `document` + `subtree: true` on a virtualised list — § Waiting for an element.
4. `!important` escalation to win the cascade — § CSS injection.
5. Hardcoded generated class names when a condition exists — § Replay the site's own condition.

## Report format (always end with this)

```markdown
## Userscript report
- **Wish:** (URL + the state asked for)
- **Shelf:** hit-adapted | hit-rejected (why) | empty — (which index/indices were fetched)
- **Measured:** (probes run, `innerWidth` A/B, cross-origin sheet count)
- **Diff verdict:** DOM-DIFFERS | DOM-IDENTICAL | STATE-B-UNREACHABLE
- **Approach:** (attribute set | rules lifted by condition in band X–Y | constructed UI)
- **Selectors shipped:** (each one, with the date measured — or "none")
- **Files:** userscripts/<kebab>.user.js · modules/shared/home.nix
- **Gates:** userscripts ✅/❌ · fmt ✅/❌ · flake check ✅/❌
- **Operator action:** activate, then click <kebab> in index.html and confirm
- **Verdict:** SHIPPED | BLOCKED (why) | ESCALATED (vite-plugin-monkey)
```

## Compose with existing automation

```
/userscript <site> <wish>  → this skill (measure → write → declare → gate)
/eval                      → eval only
/hygiene                   → doc/index drift after the PR lands
```
