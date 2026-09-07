# CDP extras — the raw-protocol surface no tool exposes

Everything below is reached over the DevTools Protocol **directly**, through this plugin's own
client (`scripts/lib/cdp.mjs`), against a browser already listening on the debugging port.
No MCP server sends an arbitrary CDP command at any version [F-NO-CDP-PASSTHROUGH], so the raw
socket is structural here, not a stopgap — and **tier 1 only**: no other route in
`routes.md` can send any of these.

Organised by **symptom**, because that is how the question arrives: *why is this rule losing*,
not *what does `CSS.getMatchedStylesForNode` return*.

---

## HARD RULE 6 — capability asymmetry is a trap, not a win

**Data that only CDP can see is EVIDENCE FOR THE AUTHOR, never a runtime dependency of the
shipped script.**

A `.user.js` runs in a page with no protocol client. It cannot re-derive at runtime what only
the protocol could see — matched-rule order, cascade layers, listener capture flags, a paint
snapshot. Use these to *decide* what to write; never to justify a script that needs them.

**A script that needs one of these is disproven, not clever.** Go back to the reuse ladder in
`../skills/userscript-author/patterns.md` and find a shape the page itself can support.

---

## Symptom → command

| Symptom | Commands |
|---|---|
| "which rule wins — do I even need `!important`?" | `CSS.enable` → `CSS.getMatchedStylesForNode` (inline style, attributes style, matched rules with their selector indices, the inherited chain, pseudo-elements) + `CSS.getLayersForNode`. **An unlayered rule beats every layered rule regardless of specificity** — check layers before reaching for `!important`. |
| "my change keeps coming back" | `DOMDebugger.setDOMBreakpoint({nodeId, type:'subtree-modified'})` pauses on the re-add and hands over the stack that did it; or `Runtime.addBinding` + the `Runtime.bindingCalled` event to **stream** a MutationObserver's re-add timings instead of returning once. |
| "will my click handler win?" | `DOMDebugger.getEventListeners({objectId, depth, pierce})` — type, `useCapture`, `passive`, `once`, the handler, `scriptId`/line/column. The only programmatic answer to *is there a capture-phase listener that beats me*. |
| "is it CSP or is it my code?" | `Page.setBypassCSP(true)` **as a diagnostic only**, `Runtime.evaluate({allowUnsafeEvalBlockedByCSP:true})`, `DOMDebugger.setBreakOnCSPViolation`. The fix is `GM_addElement` / `GM_addStyle`, never the bypass. **A script that only works with the bypass on is disproven, not shipped.** |
| "server-rendered or hydrated?" | `Emulation.setScriptExecutionDisabled(true)`, reload, look. Decides `@run-at document-start` versus waiting on a MutationObserver. |
| "where exactly is the breakpoint?" | `Emulation.setDeviceMetricsOverride` + `CSS.getMediaQueries` + the `CSS.mediaQueryResultChanged` event → bisect a **BAND**, never a pixel. A pixel is a guess wearing a number. |
| "which element is the fixed overlay?" | `DOM.getNodesForSubtreeByStyle` (experimental) and `DOM.getTopLayerElements`. |
| "does my target sit in a shadow root or a frame?" | `DOM.getDocument({depth:-1, pierce:true})`, `DOM.describeNode({pierce:true})`, `DOM.getFrameOwner`. This is what sets the envelope's `reachability` and the correct selector-scoring root. |
| "a strictly better Probe 1" | `DOMSnapshot.captureSnapshot({computedStyles, includePaintOrder, includeDOMRects})` — pierces iframes, shadow roots and template contents, adds paint order and DOM rects, and runs **no page JS**. |
| "cross-origin stylesheet text" | `CSS.getMediaQueries` / `CSS.getStyleSheetText` / `Page.getResourceContent` — these ask the **engine**, so cross-origin sheets are readable where page JS throws on `cssRules`. |

---

## Ordering is mandatory

A method that "returns nothing" is almost always a missing enable, not a missing capability.

```
DOM.enable → DOM.getDocument  →  (CSS.enable)  →  (Overlay.enable)
```

- No nodeId exists before `DOM.enable` **and** `DOM.getDocument`.
- `CSS.enable` depends on the DOM agent.
- `Overlay.enable` precedes every highlight and every inspect-mode call.
- Never cache a nodeId across a navigation — re-resolve from `backendNodeId` [F-NODEID-EPHEMERAL].

---

## Every override ships paired with its clear [F-STICKY-STATE]

Overlay and Emulation state survives navigation **and is shared with every CDP client, including
the operator's own DevTools window**. An unpaired override is a bug the operator discovers hours
later in their own browser.

| Override | Its clear |
|---|---|
| `Overlay.highlightNode` / `highlightRect` | `Overlay.hideHighlight` |
| `Overlay.setInspectMode({mode:'searchForNode', highlightConfig})` | `Overlay.setInspectMode({mode:'none', highlightConfig})` — **`highlightConfig` is required on the disarm too** [F-DISARM-HIGHLIGHTCONFIG] |
| `Emulation.setDeviceMetricsOverride` | `Emulation.clearDeviceMetricsOverride` |
| `Emulation.setEmulatedMedia({media:'print'})` | `Emulation.setEmulatedMedia({media:''})` |
| `Emulation.setScriptExecutionDisabled(true)` | `Emulation.setScriptExecutionDisabled(false)` |
| `Page.setBypassCSP(true)` | `Page.setBypassCSP(false)` |
| `DOMDebugger.setDOMBreakpoint` | `DOMDebugger.removeDOMBreakpoint` |

Guard each clear **independently**. One `try/catch` around a loop of clears leaves every
subsequent target uncleared — the mechanical root cause of the swallowed-click failure
[F-DISARM-HIGHLIGHTCONFIG].

---

## Probe for presence, never assume

Experimental surfaces move between Chrome builds. Probe before depending:
`Overlay.*`, `DOMSnapshot.captureSnapshot`, `DOM.getContentQuads`,
`DOM.getNodesForSubtreeByStyle`, `CSS.getLayersForNode`, `CSS.resolveValues`,
`Emulation.setVirtualTimePolicy`, `DOMDebugger.setBreakOnCSPViolation`.

Already dead — do not reach for them: `Overlay.setShowWebVitals`, `Overlay.highlightFrame`,
`DOM.getFlattenedDocument`, `Emulation.canEmulate`.

`Overlay.highlightRect` coordinates are **not** plain CSS pixels and need a manual DPR
adjustment (crbug.com/437807128). Prefer `Overlay.highlightNode`, which takes a nodeId and needs
no arithmetic.

---

## Dead ends, recorded so nobody retries them

- **`$0` is unreachable from a separate CDP session** — `undefined` even with
  `includeCommandLineAPI:true`, because it is bound per-session by `DOM.setInspectedNode`
  [F-DOLLAR-ZERO-DEAD]. Arm inspect mode instead; see `pick-protocol.md`.
- **"The socket close cleans it up"** is not a known behaviour and must not be written anywhere
  [F-UNMEASURED-DISCONNECT-RESET]. Disarm explicitly, every time.
