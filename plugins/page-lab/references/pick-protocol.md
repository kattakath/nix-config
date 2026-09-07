# Pick protocol — one verb, five implementations, one contract

**PICK** is the two-way verb: the operator points at an element in their own browser, and the
agent measures the exact node they pointed at.

Five, not six: `routes.md`'s `inapp-eval` tier reaches a live page but **cannot host a pick**,
because the operator is not pointing at anything in it — it is a different browser with a
different profile. It measures a site; PICK measures *this operator's* page. Which tier takes the measurement is
[`routes.md`](routes.md)'s business. What comes back is this file's business, and it is the
same object every time.

Volatile claims are one clause plus an `F-` citation into [`facts.md`](facts.md).

## 1. The envelope

Every route returns exactly one `page-lab/pick@1` JSON object on stdout. The authority on its
shape is [`pick-envelope.schema.json`](pick-envelope.schema.json); the only producer is
`scripts/lib/envelope.mjs`, and `scripts/pick-validate.mjs` is the gate.

| Field | Carries |
|---|---|
| `schema` | `page-lab/pick@1`, always. A future shape is `@2` in its own file — this one is never widened in place |
| `status` | `picked` · `no-pick` (the route ran, nothing usable came back) · `origin-mismatch` (the click landed off-target; **no selector is emitted**). Process outcomes — timeout, SIGINT, no route — exit non-zero with **no envelope at all** |
| `route` | which tier measured: `cdp-overlay`, `kapture-focus`, `kapture-hover`, `kapture-eval`, `cic-armed`, `operator-paste` |
| `fidelity` | `verified` · `sampled` · `asserted` — the whole contract hangs off this |
| `measuredAt` | `YYYY-MM-DD`, pre-formatted for the dated `WHY` block hard rule 2 requires |
| `url` / `origin` / `originVerified` | the page this came from, and whether that was checked rather than assumed |
| `pageMutated` | the act of measuring changed the DOM (every Kapture route) |
| `viewport` | `innerWidth` / `innerHeight` / `dpr` — a breakpoint-sensitive selector is meaningless without it |
| `target` | `tag`, `path`, `reachability`, `selectorSource`, `candidates[]`, and the optional `id`, `classCount`, `classes`, `rect`, `boxes`, `text`, `frameUrl`, `shadowHostPath` |
| `cascade` | tier 1 only, optional: `matchedRuleCount`, `winningRuleSelector`, `winningSheet`, `unlayeredWinner`, `needsImportant` |
| `shipBlockers` | empty is the **only** value that lets a pick become a shipped selector |
| `notes` | the limitations this tier imposes, in the operator's words |

**There is no `outerHTML` field, anywhere, by construction** — the schema sets
`additionalProperties:false`, so "no serialized markup in the envelope" is a rule rather than
a wish. `target.text` is at most 200 characters, derived locally from markup that is never
emitted.

### Fidelity decides what may be read

| `fidelity` | Meaning | Required | Forbidden |
|---|---|---|---|
| `verified` | uniqueness confirmed by `DOM.querySelectorAll` against the correct scoring root, no page JS | `candidates[].matches`, `candidates[].root`, `target.boxes`, `target.reachability`, `originVerified:true` | — |
| `sampled` | a tool read the live DOM but scored no selector (Kapture) | `candidates[].sel`, `pageMutated` | `candidates[].matches` |
| `asserted` | a sanitizer or a human stood between the page and this object (claude-in-chrome, paste) | a non-empty `notes` naming the limitation | `candidates[].matches`, `target.boxes` |

**A consumer must never read a field the fidelity table says is absent. A missing `matches`
means *unverified* — never *one*.** Defaulting it to 1 is the exact drift the schema exists
to stop, and `fixtures/pick-bad-matches-on-sampled.json` is the negative fixture that proves
the validator still catches it.

### Hard rules the schema enforces, so prose does not have to

- `status:"picked"` requires `originVerified:true` **or** a `notes` entry `origin-unconfirmed`.
- `status:"origin-mismatch"` requires `expectedOrigin`, forbids `target`, and pins
  `originVerified:false`.
- `selectorSource:"kapture-minted"` requires `kapture-minted-selector` in `shipBlockers`.
- `reachability` other than `document` requires the matching blocker: `shadow-root-target`,
  `cross-frame-target`, or both for `shadow-in-frame`.
- `url` is always present. An envelope that cannot be traced to a page is rejected
  (`fixtures/pick-bad-no-url.json`).

`shipBlockers` enum, and what each one demands before the selector may ship:

| Blocker | Resolve by |
|---|---|
| `kapture-minted-selector` | re-pick on a non-mutating route — the `kapture-N` stamp evaporates on reload [F-KAPTURE-MUTATES] |
| `shadow-root-target` | pierce the host (`patterns.md` § 11); a **closed** root is unreachable, so re-scope to the host or abandon |
| `cross-frame-target` | `@match` the frame's own URL **and** drop the default `@noframes` |
| `generated-classname` | anchor on something else — a `[data-*]`, a `[role]`, or an nth-of-type path |
| `origin-unconfirmed` | confirm the URL with the operator before using the selector |
| `sanitizer-drift` | re-measure [F-CIC-SANITIZER] and demote to `operator-paste` until it matches again |

**A pick is a measurement only when `fidelity=="verified"`, some candidate has `matches==1`,
and `shipBlockers` is empty.** Everything else is evidence in progress.

## 2. Tier by tier

### Tier 1 — `cdp-overlay`

The agent **does not build a picker**; it arms Chrome's own — the same inspect mode the
DevTools arrow drives — from a plain CDP client with no DevTools window open
[F-INSPECTMODE-WORKS]. `$0` is not usable for this from a separate session, and no amount of
`includeCommandLineAPI` changes that [F-DOLLAR-ZERO-DEAD]. There is no MCP passthrough either
[F-NO-CDP-PASSTHROUGH], so the raw WebSocket is structural, not a stopgap — and
`chrome-remote-interface` is declined for the reasons in [F-CRI-UNAVAILABLE].

```bash
page-lab-pick --expect-origin https://example.com --timeout 45000
# or, outside this repo:  node scripts/pick-element.mjs --expect-origin …
```

Order of operations, each step load-bearing:

| # | Call | Why it cannot be skipped or reordered |
|---|---|---|
| 1 | `GET /json/version` → browser `webSocketDebuggerUrl` | one socket serves every target through flat sessions |
| 2 | `Target.getTargets`, keep `type=="page"`, drop `devtools://` | 13 targets can be 3 pages [F-TARGETS-13-3] |
| 3 | raise the browser (`open <bundle>`, ~800 ms) | otherwise the operator's app-switching click **is** the pick |
| 4 | write the arm stamp | a `kill -9` after this point is still recoverable |
| 5 | spawn the detached watchdog | the deadman that survives the parent |
| 6 | per target: `Target.attachToTarget({flatten:true})` → `DOM.enable` → `DOM.getDocument` → `Overlay.enable` → `Overlay.setInspectMode({mode:'searchForNode', highlightConfig})` | a missing enable presents as "the method returned nothing"; arming one tab means the pick never arrives, because the operator clicks whichever tab they are looking at |
| 7 | one stderr line: armed, click it, **Ctrl-C cancels**, timeout | no `Escape` promise until [F-UNMEASURED-ESC] is measured |
| 8 | race `Overlay.inspectNodeRequested`; disarm the losers **immediately** | so no second tab eats a click [F-ARMED-SWALLOWS] |
| 9 | origin guard | a stray click in a mail or bank tab must never return a confident envelope |
| 10 | `DOM.pushNodesByBackendIdsToFrontend` → `DOM.describeNode` → `DOM.getBoxModel` | four quads, no page JS, no CSP exposure |
| 11 | `DOM.getDocument({depth:-1, pierce:true})` → `reachability` + the scoring root | shadow and iframe walls are detected **and acted on** |
| 12 | `DOM.querySelectorAll` per candidate, against **that root** | the envelope carries verified counts, not a plausible string. A count against the wrong root is worse than no count |
| 13 | `CSS.getMatchedStylesForNode` + `CSS.getLayersForNode` (probed for presence) | answers whether `!important` is needed **at all** |
| 14 | `Overlay.highlightNode` ~1.2 s → `Overlay.hideHighlight` | they point, it points back — no screenshot round-trip, no page mutation |
| 15 | `finally`: per target, independently guarded, `setInspectMode({mode:'none', highlightConfig})` then `hideHighlight` | § 3 |

**Never cache a nodeId across a navigation.** `DOM.documentUpdated` invalidates all of them
and fires on SPA document replacement too; always re-resolve from `backendNodeId`
[F-NODEID-EPHEMERAL].

Fidelity: `verified`. Confirm-back: `Overlay.highlightNode`.

### Tier 2 — `kapture-focus` / `kapture-hover`

Same browser, zero relaunch. Precede either shape with `mcp__kapture__show({tabId})` so the
target tab is unambiguous.

**2a — `:focus`, first choice for anything focusable.** Ask the operator to click or Tab into
it, then `mcp__kapture__elements({tabId, selector: ":focus"})`. One call, exact, and
self-verifying — the element data reports `focused:true`. Use `:focus-within` when the target
itself is not focusable.

**2b — `:hover` sampler, confirm by agreement.** Not one long timer; three short samples:

```
mcp__kapture__compose({tabId, script: "wait?t=2500\nelements?selector=%3Ahover&visible=true"})   ×3
```

The `:` **must** be percent-encoded as `%3A`, and `evaluate` is ineligible inside `compose`.
Accept only when **two consecutive samples agree** and the terminal node is not `html` or
`body`; an `html`/`body`-terminated stack is `status:"no-pick"`, never a pick of `<body>`.
Show the operator the **last three** entries of the stack and let them choose the depth — the
deepest node is routinely a `<span>` inside the thing they meant. The whole shape depends on
[F-UNMEASURED-KAPTURE-HOVER]; if that measurement fails, 2b demotes to `elementsFromPoint`
with operator-supplied coordinates.

**Cost, recorded on the envelope:** `selectorSource:"kapture-minted"`, `pageMutated:true`,
`shipBlockers:["kapture-minted-selector"]` [F-KAPTURE-MUTATES] — a ship blocker enforced by
the schema and again by `userscript-meta-lint.sh`, not by prose. Any later HTML diff must
re-measure state A.

Fidelity: `sampled`. Confirm-back: `mcp__kapture__screenshot({tabId, selector})`.
Normalize with `pick-normalize.mjs --route kapture-focus|kapture-hover --page-mutated`.

### Tier 3 — `kapture-eval`

Gate: tier 2's, **plus** a human flipping *Allow JavaScript Execution*. Probe by tool-name
presence only — the server hides `evaluate` from `tools/list` until the toggle is on, and the
toggle resets on disconnect [F-KAPTURE-EVAL-GATE].

One call, using `pick-payload.js`'s `blocking` wrapper, because `evaluate` runs with
`awaitPromise:true` and blocks on the returned Promise for up to its timeout. Kapture applies
no output filter, so the full raw shape survives. `evaluate` is ineligible inside `compose`,
so this is always its own call. If [F-UNMEASURED-KAPTURE-AWAIT] fails on measurement, tier 3
becomes ARM/POLL/DISARM — tier 4's shape — and loses its only advantage over tier 2.

Fidelity: `sampled`.

### Tier 4 — `cic-armed` (ARM / POLL / DISARM)

Three `mcp__claude-in-chrome__javascript_tool` calls, never one: the wrapper is a `{ … }`
block under `replMode`, so top-level `let`/`const` are gone by the next call and all state
must hang off `window`; a single evaluation is capped at roughly 40 s and 50 KB
[F-CIC-REPLMODE].

1. **ARM** — inject `pick-payload.js`'s `armed` wrapper. Its return value is the **canary**
   (§ 5). Capture-phase `preventDefault` + `stopPropagation` are mandatory: a same-call
   navigation makes the whole call fail the post-hoc origin re-check [F-CIC-ORIGIN-RECHECK].
2. **POLL** — every ~2 s, read `window.__pageLabPick.hit`, which deliberately outlives
   `disarm()` so a late poll still retrieves the pick.
3. **DISARM** — in a `finally`, always.

Fidelity: `asserted`; `notes` must name the sanitizer.
Confirm-back: `mcp__claude-in-chrome__computer({action:'zoom', region:[x,y,x+w,y+h]})`.

**No-JS sub-tier**, when the per-domain prompt is unwanted: `mcp__claude-in-chrome__find({query})`
returns up to 20 refs and `mcp__claude-in-chrome__computer({scroll_to, ref})` plus a screenshot
shows which one. That is **propose-and-confirm, not a pick** — the report must say so.

### Tier 5 — `operator-paste`

`/pick` prints the standalone snippet, the operator runs it in their own console, and pastes
the JSON back; `pick-normalize.mjs --route operator-paste` turns it into an envelope.
Fidelity: `asserted`. This is a valid measurement — just not one the agent took. If even this
is refused, say so and stop; inventing a selector is not a fallback.

## 3. The disarm contract

**An armed picker swallows the next click on every armed tab** [F-ARMED-SWALLOWS]. A picker
left armed does not fail loudly — it makes the operator's browser feel broken, in tabs that
have nothing to do with the task.

**The disarm needs `highlightConfig`.** `Overlay.setInspectMode({mode:'none'})` rejects with
*"Internal error: highlight configuration parameter is missing"* unless the config is passed
on the disarm too [F-DISARM-HIGHLIGHTCONFIG]. Pass the one shared `HIGHLIGHT_CONFIG` object
on **both** arm and disarm.

**Each clear is guarded independently. One `try/catch` around the loop is the bug** — the
first rejection skips every remaining target and leaves them all armed. That is the mechanical
root cause of the swallowed-click failure, not a theory about it.

Every guarantee, all of which must hold at once:

| Guarantee | Covers |
|---|---|
| `finally` block | the normal path and any thrown error |
| hard `--timeout` (default 45 s) | the operator walked away |
| `SIGINT` / `SIGTERM` handlers | Ctrl-C, and a shell tearing the job down |
| `uncaughtException` handler | a bug in the picker itself |
| detached watchdog (`pick-watchdog.mjs`) | `kill -9`, which no in-process handler can catch |
| `page-route.sh`'s stale-arm sweep | a previous run that lost every other guarantee |
| `pick-element.mjs --disarm-only` | the named recovery, printed in `/pick`'s failure text |
| quitting the browser | the operator's nuclear option — inspect mode is per browser process |

Ordering that makes the guarantees real:

- **Write the arm stamp before arming**, not after. `${TMPDIR:-/tmp}/page-lab-pick.arm.json`
  carries `{pid, browserUrl, targetIds[], armedAt, deadlineAt}` — everything a cold sweep
  needs.
- **Spawn the watchdog before arming**, detached and `unref()`ed. The only timeout must not
  live inside the process whose death is the failure mode.
- **`--disarm-only` sweeps blind** when the stamp is missing: every page target, unconditional
  clear.
- **Never** write "the socket close cleans it up" anywhere. Whether Chrome auto-resets inspect
  mode on client disconnect is unmeasured [F-UNMEASURED-DISCONNECT-RESET].

And the wider rule this is one instance of: **every override ships paired with its clear** —
`hideHighlight`, `setInspectMode:'none'`, `clearDeviceMetricsOverride`,
`setEmulatedMedia({media:''})`, `setScriptExecutionDisabled(false)`. Overlay and Emulation
state is sticky **and shared with the operator's own DevTools window**.

## 4. Confirm-back — they point, it points back

| Tier | Confirmation | Cost |
|---|---|---|
| 1 | `Overlay.highlightNode`, ~1.2 s, then `hideHighlight` | none — no screenshot round-trip, no page mutation |
| 2–3 | `mcp__kapture__screenshot({tabId, selector})` | an image round-trip, and the page is already mutated |
| 4 | `mcp__claude-in-chrome__computer({action:'zoom', region:[x,y,x+w,y+h]})` | an image round-trip |
| 5 | the operator is looking at it | none |

Confirm before writing a selector into a file, not after.

## 5. Sanitizer canaries (tier 4)

claude-in-chrome sanitizes output **silently** — no error, the value is simply replaced
[F-CIC-SANITIZER]. The two traps that bite this plugin specifically:

| Input | Becomes | Why it matters here |
|---|---|---|
| `div.card.active` | `[BLOCKED: JWT token]` | a three-part class chain matches the JWT regex **exactly** |
| `x=1;y=2` | `[BLOCKED: Cookie/query string data]` | any string with `=` and `;`/`&` |
| a key named `author` | sensitive-key block | the key regex contains `auth` |
| a top-level array | only its description | never return one |
| a DOM node | `[DOM Node]` | never return one |

**Mitigations, baked into `pick-payload.js` rather than left to recall:** nth-of-type **path**
selectors only — spaces and `>` cannot match the anchored regexes, and a class chain can;
`<<…>>` sentinels stripped agent-side; never `outerHTML`; never a top-level array; never a DOM
node; keys short and boring — `sel`, `tag`, `w`, `h`, `x`, `y`, `txt`.

**The canary.** The ARM call's **first** returned object is:

```js
{ a: 'div.card.active', b: 'x=1;y=2', c: '<<probe>>', d: 'a'.repeat(40) }
```

Expected back: `a` → `[BLOCKED: JWT token]`, `b` → `[BLOCKED: Cookie/query string data]`, `c`
intact, `d` → `[BLOCKED: Base64 encoded data]` or intact.

**Any deviation ⇒ print `SANITIZER DRIFT`, add `sanitizer-drift` to `shipBlockers`, demote to
`operator-paste`, and re-measure [F-CIC-SANITIZER].** This is the only drift signal the sanitizer ever
gives; without the canary, a changed rule looks like a working pick with a slightly odd
selector.

`pick-normalize.mjs` refuses any input carrying a `[BLOCKED:` marker outside a canary field.

## 6. Dead ends — do not retry these

- **`$0` from a separate CDP session.** `undefined` even with `includeCommandLineAPI:true`; it
  is bound per session via `DOM.setInspectedNode` [F-DOLLAR-ZERO-DEAD].
- **Loading a userscript manager into a clean instance.** The whole Extensions tool group is
  absent from the pinned server [F-CDP-29TOOLS], so the clean-room route does not exist and
  the loop still ends at a human clicking Install.
- **"The socket close cleans it up."** Unmeasured [F-UNMEASURED-DISCONNECT-RESET]. Disarm
  explicitly.
- **An arbitrary CDP command through the MCP server.** No version has ever had one
  [F-NO-CDP-PASSTHROUGH].

## 7. Upgrade path

`@medv/finder` is the de-facto off-the-shelf selector generator and is the named swap **if the
claude-in-chrome tier is ever retired**. It is not adopted now because it optimises for
*short* selectors — class chains — which is exactly what the sanitizer eats and what a dated,
verifiable `WHY` block discourages. This plugin needs positional and verifiable, not short.
