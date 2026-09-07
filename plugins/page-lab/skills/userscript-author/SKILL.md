---
name: userscript-author
description: >
  This skill should be used when the user asks to make a site do X, write a
  userscript for a site, fix a broken userscript, remove or restyle an element
  that annoys them ("this site's sidebar annoys me", "hide this banner"), or
  publish a userscript to Greasy Fork. It authors a lint-clean Violentmonkey
  `.user.js` by measuring the live page first — never by guessing a selector —
  and can hand the operator a click-to-point element picker.
---

# Userscript author — measure → replay → write → lint → prove

**The invariant is MEASURE.** Never ship a selector, class or breakpoint that was not dumped
from the live page. **If no route is reachable, say so and stop** — asking the operator to
paste a probe result is a measurement; inventing a selector is not.

This skill owns the *judgment*: is the state you want **already rendered** by the site, which
selectors are **real**, what gets **asked** instead of guessed.

```
wish → shelf → route → measure A vs B → diff → replay-or-select → write → lint → prove
```

**Delivery is out of scope.** This skill stops at a lint-clean, proven file.

## Hard rules

1. **Never `@require` / `@resource` from a CDN.** Fetched at install time, **no SRI or
   integrity field exists**, nothing pins it; Violentmonkey also refuses local files. Reuse
   enters as **vendored source**, which Greasy Fork permits *provided* the block carries
   name/version/URL attribution ([`greasyfork.md`](greasyfork.md)).
2. **Every shipped selector is listed in the file's WHY block with the date it was measured.**
   A **template-literal selector containing `${`** is banned — untraceable to a measurement.
3. **`@grant none` is the target.** Every grant comes from the verified set in
   [`patterns.md`](patterns.md) § 6 — no linter checks grant *values*, so **a typo grants
   nothing, silently**. Portability: [`gm-api.md`](gm-api.md).
4. **`@match` + `@noframes` by default** ([`patterns.md`](patterns.md) § 7). `@downloadURL` /
   `@updateURL` / `@installURL` are **lint-enforced bans** ([`greasyfork.md`](greasyfork.md)).
5. **Never a secret.** A userscript is plain text that ships to the browser and usually gets
   copied somewhere world-readable. A private repo is not a secret store.
6. **A picked element is a measurement only when** the envelope's `fidelity` is `verified`,
   `candidates[].matches == 1`, and `shipBlockers` is empty. Anything else is a **lead** —
   act on it to keep looking, never to write a selector into a file.

## Checklist (run in order)

### 0. Check the shelf first — reuse over rebuild

Authoring is the **fallback**. Both hosts publish a free, no-auth **by-site index**, so "has
someone already solved this" is one fetch. Mechanics and the Sleazy Fork split:
[`greasyfork.md`](greasyfork.md) § The shelf check.

- [ ] Fetch `https://greasyfork.org/en/scripts/by-site/<domain>` for the **bare** domain
      (`civitai.com`, not `www.civitai.com`), and Sleazy Fork too if the site is adult-adjacent.
- [ ] A hit is **evidence, not a dependency.** You still cannot `@require` it (rule 1) and must
      not paste it unread. Read it for its **measured selectors and its condition**, then vendor
      *with attribution* or re-derive.
- [ ] Record: **shelf hit (adapted) / hit (rejected, why) / empty**. "Nobody looked" and
      "nothing exists" must not read the same.

### A. Frame the wish

- [ ] Which **exact URL** (it becomes `@match`), and which **state is "good"**?
- [ ] Is that state reachable **without code** — a narrower window, another route, a site
      toggle? Then the job may be a bookmark. Greasy Fork's Functionality rule: a script must
      "have a reason to be a script".
- [ ] Anything a stated preference does not cover → **ask**. Colour, typography, density and
      "which furniture goes" are never obvious.

### A.5 Route preflight — before the first probe

```bash
scripts/page-route.sh
```

- [ ] It prints which routes are **live**, plus an `AGENT-MUST-CHECK:` block for the two it
      cannot see from a shell. Answer those, then re-run with `--tools`.
- [ ] Only `operator-paste` live ⇒ offer `scripts/route-up.sh --tier <n>` to **open** a gate.
      **Do not improvise past a dark gate**; a down route is a stop, not a licence to guess.
- [ ] Ladder, gates, and what no fallback can do:
      [`../../references/routes.md`](../../references/routes.md).

### B. Measure state A (what the site gives you)

- [ ] Run **`dumpSubtree(rootSelector)`** ([`probes.md`](probes.md)); keep the JSON.
- [ ] Run **`mediaRules()`**; note `crossOrigin` — a high count means the replay route may be
      unavailable.
- [ ] **May begin with `/pick`** when the operator is pointing rather than describing. Record
      the envelope — it is the measurement of record for that element. **A non-empty
      `shipBlockers` is resolved before anything is written:**

| Ship blocker | Resolution |
|---|---|
| `kapture-minted-selector` | Re-pick on a non-mutating route — the minted id evaporates on reload |
| `shadow-root-target` | The host-piercing shape, [`patterns.md`](patterns.md) § 11 |
| `cross-frame-target` | `@match` the frame's own URL **and** drop the default `@noframes` (§ 11) |
| `origin-unconfirmed` | Re-pick; a pick from the wrong tab is not a pick |

### C. Measure state B (the good state)

- [ ] Put the page in state B, re-run **`dumpSubtree`** on the same root, record `innerWidth`.
- [ ] **Prefer setting the viewport to an exact width** when the trigger is a width: repeatable
      and bisectable, so finding the real breakpoint band is cheap. A device preset moves
      several variables at once — it answers "does this work on a phone", not "which breakpoint
      fires". That capability lives in the sibling skill; the tool carrying it is named in
      [`../page-diagnose/references/tools.md`](../page-diagnose/references/tools.md).
- [ ] Otherwise resize / route / toggle **by hand** — the measurement matters, not who took it.

### D. Diff → verdict

- [ ] Run **`diff(a, b)`** ([`probes.md`](probes.md)). An **empty diff is the finding**, not a
      failure. Probe 3's own table maps the counts to the three verdicts — **DOM-DIFFERS**,
      **DOM-IDENTICAL**, **STATE-B-UNREACHABLE** — and what each one licenses you to write.
- [ ] On DOM-IDENTICAL, **no selector can force a media query**: lift the site's rules **by
      condition in a band, never a hardcoded pixel**, accumulating **every block** at each width
      before picking one ([`patterns.md`](patterns.md) § 5). Reimplementing a state the site
      already renders is the classic loss.
- [ ] **Prototype the override live before writing a file.** Inject the candidate CSS into the
      running page (a scratch stylesheet, or the protocol's own stylesheet API where the route
      allows), **reload**, and promote only what survived. A rule that needed `!important` in
      the prototype needs it in the file — one that did not **must not** carry it.

### E. Write the body

- [ ] Work **down the reuse ladder** in [`patterns.md`](patterns.md), first hit wins: platform
      web API → metadata key → granted `GM_*` → vendored source. Take the navigation, waiting,
      CSS-injection and idempotence shapes from there; do not improvise them.
- [ ] Open the WHY block with the **measured finding, one sentence**, then the dated selectors.
- [ ] **Degrade to stock, never mangle.** A script that cannot do its job becomes a no-op.

### F. Lint

```bash
scripts/userscript-meta-lint.sh <file.user.js>      # or a directory
```

`node --check`, required/banned metadata keys, dotted-numeric `@version`, minified or bundled
output, vendored attribution, and that no minted `kapture-` selector reached the file. What it
**cannot** check: [`patterns.md`](patterns.md) § 10.

### G. Prove it after install

- [ ] Re-run **`assertEffect()`** + **`dumpSubtree`** and **diff against the recorded state B**.
      Eyeballing is not a check.
- [ ] **No route replaces this step at any tier.** The protocol measures the *page*, never the
      userscript runtime — and never in the profile the script ships into.
- [ ] A missing marker usually means the script **never ran** — check § Install reality first.

### H. Publish

[`greasyfork.md`](greasyfork.md) — rulebook, metadata contract, adult-content marking, and how
to make a `git push` the release without `@updateURL`.

### I. Escalation trigger (do not grow a bundler)

- [ ] **≥ 4 scripts**, **or** the first TS/JSX need, **or** `GM_*` plus a settings UI ⇒ **STOP.**
      Ship nothing; propose adopting **`vite-plugin-monkey`** as its own change.
- [ ] Never hand-roll a build step; never commit minified or bundled output (Greasy Fork
      rejects it, the lint fails it).

## Editing an existing script

**Bump `@version` first** — dotted-numeric; a same-version re-install is a **silent no-op**.
**Re-measure before re-writing** (B–D): the page changed, your memory of it did not. Then
re-lint (F) and re-prove (G).

## Install reality (Chromium)

One-time per profile on the manager's `chrome://extensions` details page: **Allow User
Scripts**, plus **Allow access to file URLs** for a `file://` install. An agent **cannot**
install a script, flip a toggle, or drive the manager's dialog — that click is the operator's.
Why the toggle exists and why policy cannot set it: [`gm-api.md`](gm-api.md).

**Iterating without re-installing by hand:** Violentmonkey's *Track external edits* turns each
save into an auto-reinstall plus a tab reload. Setup, and the three silent ways tracking dies
(a git write to the file being the worst): [`patterns.md`](patterns.md) § 12.

## Anti-patterns

CDN `@require`/`@resource` ([`patterns.md`](patterns.md) § 9) · `setInterval` polling for a URL
or an element (§ 1, § 2) · `document` + `subtree: true` on a virtualised list (§ 2) ·
`!important` escalation to win the cascade (§ 4) · hardcoded generated class names where a
condition exists (§ 5) · shipping a selector whose envelope still carries a ship blocker
(rule 6).

## Where to read next

- [`../../references/routes.md`](../../references/routes.md) — routes, gates, opening one.
- [`../../references/pick-protocol.md`](../../references/pick-protocol.md) — envelope + disarm.
- [`probes.md`](probes.md) — the four probe bodies, the verdict table.
- [`patterns.md`](patterns.md) — reuse ladder, vetted code shapes, live-edit loop.
- [`gm-api.md`](gm-api.md) — `GM_*` portability, `@grant` asymmetry, metadata traps.
- [`greasyfork.md`](greasyfork.md) — the publishing rulebook.
- [`../../references/report-format.md`](../../references/report-format.md) — **the Userscript
  report block; end every run with it.**

**Out of scope:** delivery (the fleet's own skill), performance/network/console diagnosis
(`page-lab:page-diagnose`), and picker mechanics (`scripts/` + `pick-protocol.md`).
