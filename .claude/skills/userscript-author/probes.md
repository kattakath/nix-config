# Probes — the measurement instruments

**Two routes, and you must check which one this session actually has** — a missing tool surface is the single most common reason a measurement never happens:

| Route | How to run a probe | Requires |
|---|---|---|
| **claude-in-chrome** | `javascript_tool` (`action: "javascript_exec"`) with a `tabId` from `tabs_context_mcp` (or `tabs_create_mcp` + navigate) | its tools **loaded in this session** — they are not always |
| **Kapture** (`mcp__kapture__*`) | `list_tabs` → `evaluate` on that tab | the `npx kapture-mcp bridge` server **and** DevTools open + connected **on that tab** |

Both are declared in `modules/shared/chromium.nix` (`claudeInChrome`, `kaptureMcp`). If **neither** is reachable, say so and stop — **do not substitute a guessed selector for a measurement.** Ask the operator to paste the probe into the browser console themselves and hand back the JSON; that is a valid measurement, just not one you took.

## Honest caveats — read before blaming the page

| Caveat | Consequence |
|---|---|
| The claude-in-chrome tool names are **lifted from `../vast-instance-log-tail/SKILL.md`, not re-verified this session**. | If `javascript_tool` / `tabs_context_mcp` / `tabs_create_mcp` were renamed, the failure is the **tool surface**, not the site. Re-check the tool list first. |
| Kapture's extension being *installed* proves nothing — its per-tab gate is **DevTools**. | `list_tabs` returning empty is the expected state for a tab nobody connected. Open DevTools → Kapture panel → connect, then retry. |
| Measurement happens in the **claude-in-chrome Chrome profile — NOT the ungoogled-chromium profile the script will run in**. | Extension set, CSP handling and `@run-at` timing can differ. That is exactly why Probe 4 re-measures **after the real install**, and why a green Probe 3 is evidence, not proof. |

**Every probe returns JSON.** Screenshots and blind-waiting are not measurements — they cannot be diffed, so they cannot settle the DOM-differs vs DOM-identical question.

---

## Probe 1 — `dumpSubtree(rootSelector)`

**Why:** the whole v1.x guessed-selector loop existed because nobody dumped the two states and compared them. This is that dump.
**Gotcha:** generated class names are **noise** — a JSCompiler redeploy changes all of them. Ship a **count**, never the names, so the diff cannot be polluted by churn.

```js
(() => {
  const ROOT = 'body';                       // narrow this to the subtree you actually care about
  const KEEP = ['display', 'position', 'width', 'overflow-x', 'visibility'];
  const root = document.querySelector(ROOT);
  if (!root) return { err: 'root not found: ' + ROOT };
  const nodes = [root, ...root.querySelectorAll('*')].map((el, i) => {
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    const out = {
      i,
      tag: el.tagName.toLowerCase(),
      role: el.getAttribute('role') || null,
      label: el.getAttribute('aria-label') || null,
      // KEYS only — a generated value is as volatile as a generated class name.
      data: Object.keys(el.dataset).sort(),
      classCount: el.classList.length,
      w: Math.round(r.width),
      h: Math.round(r.height),
    };
    for (const p of KEEP) out[p] = cs.getPropertyValue(p);
    return out;
  });
  return { href: location.href, innerWidth: window.innerWidth, count: nodes.length, nodes };
})()
```

- Run it **twice**: once in **state A** (what the site gives you) and once in **state B** (what you want — resized window, alternate route, a toggle the site owns).
- Record both payloads in the session. They are Probe 3's only inputs.
- `count` mismatch is the fastest signal there is: same count ⇒ suspect pure CSS before you read a single line of the diff.

---

## Probe 2 — `mediaRules()`

**Why:** when the DOM is identical, the switch lives in a media query, and this tells you **which** condition to replay — instead of guessing a pixel.
**Gotcha:** `sheet.cssRules` **throws** on a cross-origin sheet — it does not return `null`. Count the throw and move on; **no probe can read a cross-origin stylesheet**, so a high `crossOrigin` count means the finding is incomplete, not that the site has no breakpoint.

```js
(() => {
  let crossOrigin = 0;
  const byCondition = {};
  for (const sheet of document.styleSheets) {
    let rules;
    try {
      rules = sheet.cssRules;
    } catch {
      crossOrigin++;                          // opaque by CORS — unreadable, by design
      continue;
    }
    for (const rule of rules) {
      if (rule.type !== CSSRule.MEDIA_RULE) continue;
      const key = rule.conditionText.trim();
      byCondition[key] = (byCondition[key] || 0) + rule.cssRules.length;
    }
  }
  return { crossOrigin, innerWidth: window.innerWidth, byCondition };
})()
```

- **Several separate `@media` blocks routinely share one breakpoint** — that is why the value is a rule *count* per condition, not a single block.
- Feed the winning condition into the script as a **band** (`BAND_MIN`/`BAND_MAX` + a `conditionText` regex), never as a hardcoded pixel — the site is free to retune its own breakpoint.

---

## Probe 3 — `diff(a, b)`

**Why:** the diff, not intuition, picks the approach. **An EMPTY DIFF IS THE FINDING, not a failure** — identical DOM either side of the switch proves the switch is **pure CSS**, and therefore that **no selector can force it**. That single result is what turned the Photos script from a reimplementation into a breakpoint replay.
**Gotcha:** it aligns nodes by **document-order index**. A real structural change shifts every later index, so read `countDelta` and the **first** differing index first — a thousand-line diff is usually one insertion.

```js
(() => {
  const A = /* paste Probe 1 payload — state A */ null;
  const B = /* paste Probe 1 payload — state B */ null;
  if (!A || !B) return { err: 'paste both Probe 1 payloads' };
  const KEYS = ['tag', 'role', 'label', 'classCount', 'w', 'h',
                'display', 'position', 'width', 'overflow-x', 'visibility'];
  const changes = [];
  const n = Math.min(A.nodes.length, B.nodes.length);
  for (let i = 0; i < n; i++) {
    const a = A.nodes[i], b = B.nodes[i];
    const d = {};
    for (const k of KEYS) if (a[k] !== b[k]) d[k] = [a[k], b[k]];
    const da = a.data.join(','), db = b.data.join(',');
    if (da !== db) d.data = [da, db];
    if (Object.keys(d).length) changes.push({ i, tag: a.tag, role: a.role, label: a.label, d });
  }
  const structural = changes.filter((c) => c.d.tag || c.d.role || c.d.label || c.d.data);
  return {
    widths: [A.innerWidth, B.innerWidth],
    countDelta: B.nodes.length - A.nodes.length,
    structuralCount: structural.length,
    structural: structural.slice(0, 40),
    cssOnlyCount: changes.length - structural.length,
    firstChanges: changes.slice(0, 40),
  };
})()
```

| Result | Verdict | What to build |
|---|---|---|
| `structuralCount > 0` | **DOM-DIFFERS** | Set the attribute/class the **site itself** sets. Cheapest and most durable. |
| `structuralCount === 0`, `cssOnlyCount > 0` | **DOM-IDENTICAL** | Pure media query ⇒ Probe 2, lift its rules, re-serve unconditionally. |
| Everything `0` and `countDelta === 0` | **STATE B NEVER HAPPENED** | You measured the same state twice, or the toggle did nothing. Re-measure before writing a line. |

**Never carry a selector from one site's diff to another.** Every selector is measured on the page it ships against, or it is a guess wearing a measurement's clothes.

---

## Probe 4 — `assertEffect()`

**Why:** post-install proof. Eyeballing the page is not a check, and this is also how you detect the **most common non-bug**: the *Allow User Scripts* toggle is off, so the script never ran at all.
**Gotcha:** absent marker + zero adopted sheets ⇒ **the script did not execute** — check `chrome://extensions` (*Allow User Scripts*, *Allow access to file URLs*) and whether the `@version` bump was actually re-installed, **before** touching the code.

```js
(() => {
  const MARKER = 'nixYourScriptName';       // the documentElement dataset key your script sets
  return {
    href: location.href,
    innerWidth: window.innerWidth,
    ran: document.documentElement.dataset[MARKER] !== undefined,
    adoptedStyleSheets: document.adoptedStyleSheets.length,
    // Re-run Probe 1 now and diff it (Probe 3) against the RECORDED state B.
    // Converged ⇒ shipped. Diverged ⇒ read the diff, do not guess.
  };
})()
```

Sequence: `assertEffect()` → **`ran: true`** → re-run **Probe 1** → **Probe 3** against the recorded **state B** → converged ⇒ shipped.

---

## Where the evidence lives

**In the script's own WHY block — nowhere else.** One sentence, the measured finding, at the top of the `.user.js`, in the shape the existing script already uses:

```
// Measured: identical DOM either side of the breakpoint — same classes, same
// attributes — so the switch is a pure CSS media query and there is nothing a
// selector can force.
```

Plus one line per **shipped selector** with the date it was measured. There is **no** evidence directory, no evidence schema, and nothing greps for one — the repo's comments-explain-why idiom already owns this, and a second home for the rationale is just drift.
