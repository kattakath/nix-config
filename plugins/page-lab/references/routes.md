# Routes — the six ways to reach a live page

One ladder for the whole plugin. `probes.md`, both `SKILL.md`s and the three commands point
here instead of carrying a second copy.

Every volatile claim below is one clause plus an `F-` citation into
[`facts.md`](facts.md). Do not restate a fact here; cite it.

## Preference is per-workflow, not global

The fidelity ladder (tier 1 best) is **not** the preference ladder. Fidelity says how much a
route can prove. Preference says which route answers *this* operator's question.

| Workflow | Prefers | Why |
|---|---|---|
| W1 author a script, W2 pick → ship | **same-profile routes first** — Kapture tiers 2/3 on the daily browser, or a tier-1 attach to the **daily** profile | the element that annoys the operator is in their logged-in browser with Violentmonkey installed; a throwaway profile is a different page |
| W3 diagnose a public page | **isolated launch** | no login state is needed and the daily profile must not be touched |

### The three profiles, named so nobody conflates them

| Profile | How | Violentmonkey / logins | Use for |
|---|---|---|---|
| daily (cask default) | `open -na "Chromium" --args --remote-debugging-port=9222` — **no `--user-data-dir`** | yes | tier 1 for W1/W2 |
| isolated debug | `… --remote-debugging-port=9222 --user-data-dir="$(mktemp -d)"` | no | W3 only |
| the profile the script ships into | the operator's normal launch, no flags | yes | **the only place `assertEffect()` proves anything** |

**Two traps on the way up.** The port can never be declarative on this fleet — the browser is
a Homebrew cask, so home-manager's assertion forbids `commandLineArgs` [F-CASK-NOFLAG]; it is
a hand-run wrapper, every time. And a Chromium **already running without the flag ignores the
flag on a second `open`** — it must be fully quit first. `scripts/route-up.sh` detects that
case and refuses rather than pretending the port came up.

## The six tiers

| # | Route | GATE | PROBE | OPEN | CANNOT SEE | DISARM OBLIGATION |
|---|---|---|---|---|---|---|
| 1 | `cdp-overlay` | something answers on 9222 **and** ≥1 `type=="page"` target | `curl -sf --max-time 2 http://127.0.0.1:9222/json/version`, then `curl -s http://127.0.0.1:9222/json/list \| jq '[.[] \| select(.type=="page")] \| length'` — 13 targets can still be only 3 pages [F-TARGETS-13-3]. Identify the serving build from `pgrep -fl -- '--remote-debugging-port'`, never from the `Browser` string [F-UGC-NO-VENDOR] | `scripts/route-up.sh --tier 1 --yes` (add `--isolated` for W3) | the **userscript runtime**: `@grant` sandboxing, `GM_*` availability, Violentmonkey's real injection timing. CDP measures the page, never the manager. Also: a closed shadow root, and whatever the *ship* profile does differently from the measuring one | **the full contract** — an armed picker swallows the next click on **every** armed tab [F-ARMED-SWALLOWS] and the disarm itself needs `highlightConfig` [F-DISARM-HIGHLIGHTCONFIG]. See [`pick-protocol.md`](pick-protocol.md) § Disarm |
| 2 | `kapture-focus` / `kapture-hover` | ≥1 tab connected to the bridge | `curl -sf --max-time 2 http://127.0.0.1:61822/tabs` — `[]` is **bridge up, zero tabs: dark**, connection refused is **bridge down**. Two different problems, two different fixes [F-KAPTURE-COLD] | the operator clicks connect in the **toolbar popup** — DevTools is not required [F-KAPTURE-POPUP]; `route-up.sh --tier 2` prints the exact step | a scored selector (no match counts — the envelope is `sampled`), box quads, shadow/frame reachability, and `Overlay.setInspectMode`, which no extension exposes | nothing is armed, but the page **was mutated**: `getUniqueSelector()` stamps `id="kapture-N"` / `.kapture-N` [F-KAPTURE-MUTATES]. Record `pageMutated:true`, carry the `kapture-minted-selector` ship blocker, and re-measure state A before any HTML diff. The stamp clears on reload |
| 3 | `kapture-eval` | tier-2 gate **plus** a human flipping *Allow JavaScript Execution* | **is `mcp__kapture__evaluate` present in this session's tool list?** The server filters it out of `tools/list` until the toggle is on, and the toggle is in-memory and resets on disconnect [F-KAPTURE-EVAL-GATE]. Probe by **name presence**; never "call it and see" | the operator flips the toggle in the popup — and is asked again every session, because it does not persist | same blind spots as tier 2, plus: injected JS runs under the page's CSP, and a closed shadow root stays closed | the injected picker's `disarm()` is idempotent and runs in a `finally`; state hangs off `window` and survives until reload |
| 4 | `cic-armed` | the extension is connected **and** the domain is permitted | `mcp__claude-in-chrome__tabs_context_mcp` — **not shell-probeable**, the transport is native messaging [F-CIC-COLD] | the operator connects the extension; the first JS call on a new domain raises a per-domain prompt | anything the silent output sanitizer eats [F-CIC-SANITIZER]; box quads; match counts; and any same-call navigation, which fails the post-hoc origin re-check [F-CIC-ORIGIN-RECHECK] | the DISARM call is its own third call in a `finally`; `hit` deliberately outlives it so a late poll still retrieves the pick |
| 5 | `inapp-eval` | `mcp__Claude_Browser__*` present in the session **and** a pane open | **not shell-probeable** — an in-session MCP tool, same class of gate as tiers 3 and 4. Probe by **name presence** of `mcp__Claude_Browser__javascript_tool`; it refuses with *No preview is open* until `navigate` opens a pane, so a closed pane is not a closed route [F-INAPP-COLD] | `mcp__Claude_Browser__navigate` with any `url` | **the operator's profile, entirely** — a separate browser with no Violentmonkey, no logins and no extensions, so it can neither serve W1/W2's "the element in *my* browser" nor ever run `assertEffect()`. Also: a collapsed pane executes JS but lays out nothing, reporting a 0x0 viewport that reads like a broken selector [F-INAPP-ZERO-VIEWPORT] | nothing is armed and the page is not mutated; reset any `resize_window` emulation when done |
| 6 | `operator-paste` | none | always up | — | everything the agent did not watch happen: the origin, the viewport, whether the snippet ran on the page the operator says it did | nothing the agent armed; the pasted snippet self-times-out and `Escape` cancels it inside the page |

Table cells escape `|` as `\|`. Copy a PROBE command from the **rendered** view — an escaped
pipe pasted into a shell is a literal character, not a pipeline.

## Degrade order, and why each rank

Descend one rung at a time, and say out loud which rung you are on.

1. **`cdp-overlay` — the only tier that can produce `fidelity:"verified"`.** It arms Chrome's
   own inspect mode from a plain CDP client with no DevTools window open
   [F-INSPECTMODE-WORKS], scores every candidate against the correct root, and runs **zero
   page JS**, so CSP is irrelevant and the DOM is untouched. An open DevTools window does not
   block it — Chrome has allowed multiple simultaneous CDP clients per target since Chrome 63
   [F-MULTI-CLIENT].
2. **`kapture-focus` / `kapture-hover` — same browser, zero relaunch.** The cheapest gate that
   still reads the live DOM, and the right first move for W1/W2 because it is already the
   operator's logged-in tab. It buys `sampled`, not `verified`, and it dirties the page.
   Inside the tier, `:focus` comes first: one call, exact, self-verifying; the `:hover`
   sampler is the fallback and is only as good as [F-UNMEASURED-KAPTURE-HOVER].
3. **`kapture-eval` — a real click-to-point, at the cost of a second human gate.** Ranked
   below tier 2 because it needs a toggle that resets on every disconnect, and because its
   one-call shape rests on [F-UNMEASURED-KAPTURE-AWAIT]; if that measurement fails, tier 3
   collapses into tier 4's ARM/POLL/DISARM shape and loses its only advantage.
4. **`cic-armed` — reachable when nothing else is, and it lies by omission.** The sanitizer
   replaces values **silently, with no error** [F-CIC-SANITIZER], `replMode` erases top-level
   bindings between calls [F-CIC-REPLMODE], and the gate cannot be probed from a shell
   [F-CIC-COLD]. Envelope fidelity is `asserted`, and the canary in
   [`pick-protocol.md`](pick-protocol.md) § Canaries is the only drift signal available.
5. **`inapp-eval` — real JS on a real page, in the wrong browser.** Ranked below every
   same-browser tier because it answers a different question: it measures *the site*, never
   *this operator's page*. For W3, and for the W1 sub-question "what does this site's DOM
   actually do", it beats dictating a snippet to a human — the agent runs the probe itself and
   reads the JSON. For anything about the install — `@grant` behaviour, whether the script
   ran, `assertEffect()` — it is not a route at all, it is a different page that happens to
   share a URL. Say which of those two you are doing before you use it.
6. **`operator-paste` — a measurement, just not one the agent took.** It is always available
   and it is always honest. Asking the operator to paste is a measurement; inventing a
   selector is not.

**Below tier 6 there is no tier.** If no route is reachable, say so and stop.

## The ROUTE token grammar

`scripts/page-route.sh` can only prove what a shell can see, so it prints its own blind spot
rather than guessing past it. Parse **only** the tokens below; every other line is a human
table and may change.

```
[stale-arm] FOUND                      # optional, first line, before any probing
ROUTE_SHELL=cdp|kapture|none           # exactly one, always
AGENT-MUST-CHECK:                      # block, only when --tools was NOT passed
  kapture-eval: is `mcp__kapture__evaluate` in this session's tool list? (never call it)
  cic: call `mcp__claude-in-chrome__tabs_context_mcp` (native messaging — no shell can see it)
  inapp: is `mcp__Claude_Browser__javascript_tool` in this session's tool list? (name presence)
ROUTE=cdp|kapture-eval|kapture|cic|inapp|paste   # exactly one, only when --tools WAS passed
```

The two-step is the point: `page-route.sh` is deterministic about two of five gates and
**explicit about which three it cannot see**. The agent answers the `AGENT-MUST-CHECK:` block
from its own tool list, then re-runs:

```bash
scripts/page-route.sh --tools kapture-eval=yes|no,cic=yes|no,inapp=yes|no
```

which prints the final `ROUTE=`.

| Token | Means | Envelope `route` value |
|---|---|---|
| `ROUTE=cdp` | tier 1 | `cdp-overlay` |
| `ROUTE=kapture-eval` | tier 3 | `kapture-eval` |
| `ROUTE=kapture` | tier 2 | `kapture-focus` or `kapture-hover` — the shape is chosen inside the tier, not by the token |
| `ROUTE=cic` | tier 4 | `cic-armed` |
| `ROUTE=inapp` | tier 5 | `inapp-eval` — measures the site, never the install |
| `ROUTE=paste` | tier 6 | `operator-paste` |

`ROUTE=` names the **largest capability whose gate is proven open**, which is why
`kapture-eval` outranks `kapture` in the token even though both yield `sampled` fidelity —
it is a superset on the same tab. It is evidence, not an instruction: the workflow table at
the top of this file still decides, and W1/W2 may deliberately take a lower rung.

**Exit codes:** `0` at least one non-paste tier is up · `1` only `paste` · `2` a stale arm was
found and could not be cleared. Exit `2` is the loud one — a tab somewhere is eating clicks.

## What no fallback can do

- **Tiers 2–5 cannot reach `Overlay.setInspectMode` at all.** Neither extension exposes it,
  and nothing in `chrome-devtools-mcp` sends an arbitrary CDP command at any version
  [F-NO-CDP-PASSTHROUGH]. That is precisely why an injected overlay and a `:hover` sampler
  exist — they are not a stylistic alternative, they are the only thing left.
- **They cannot arm every tab.** Tier 1 arms all page targets and races them; the lower tiers
  address one tab, so the target tab must first be made unambiguous with
  `mcp__kapture__show({tabId})`.
- **Nothing on any tier replaces Probe 4.** CDP measures the page, never the userscript
  runtime — `@grant` sandboxing, `GM_*` availability and Violentmonkey's real injection timing
  are proven only by `assertEffect()` after a real install, in the profile the script ships
  into. See `../skills/userscript-author/probes.md`.
- **No tier promises `Escape`.** Whether `Escape` cancels inspect mode from a non-DevTools
  client is unmeasured [F-UNMEASURED-ESC], so tier 1's operator line says **Ctrl-C only** until
  the recipe is run.

## Three standing cautions

1. **Every override is sticky and shared.** Overlay and Emulation state survives navigation
   and is visible to *every* CDP client, including the operator's own DevTools window
   [F-STICKY-STATE]. Pair each override with its clear, in a `finally`, guarded per call.
2. **An open debugging port is an unauthenticated control channel.** Any local process can
   drive that browser and act as the signed-in user. Hand-run only — **never** a launchd agent
   or a login item — and close it when the work ends.
3. **Kapture's two halves drift.** The bridge is an unpinned `npx -y …@latest`; the extension
   is pinned in Nix, and the bridge already version-gates it [F-KAPTURE-SKEW]. A tier-2/3
   failure that appeared without a config change is a skew suspect before it is a bug.
