# page-lab

Author **Violentmonkey userscripts** and **diagnose live pages** from one place.

Built around four sentences an operator actually says:

| You say | It runs |
|---|---|
| *"make this site do X"* | `/userscript` — shelf-check → measure A/B → diff → write → lint → publish |
| *"this element annoys me"* | `/pick` — you click the element, the agent measures that exact node |
| *"why is this slow / what request failed"* | `/devtools` — traces, network, console with source-mapped stacks |
| *"my script stopped working"* | re-measure, re-diff, re-verify — the page changed, your memory of it did not |

## The one invariant

**MEASURE.** Never ship a selector, class or breakpoint that was not dumped from the live
page. A plausible-looking selector nobody measured is the single most common way a userscript
silently stops working on the site's next deploy.

The corollary is the method's whole point: **before writing UI, check whether the site already
renders the state you want** — a narrow-viewport layout, a print stylesheet, a logged-out view.
If it does, replaying its own condition beats reimplementing it, and ships without a single one
of the site's generated class names.

## Why one plugin and not two

These were two plugins that cross-referenced each other. That held only while neither needed
the other mid-motion. The verb that broke it is **pick**: point at an element → measure that
exact node → read its cascade → prototype the override live → date it in the `WHY` block → lint
it → prove it after install. Under the split that motion crossed the plugin boundary four times
and needed a seam *file* to narrate the crossing. A seam that needs its own document is a merge
that has not happened yet.

**The cost, stated plainly:** the diagnosis half is no longer adoptable on its own. Anyone who
wants only page diagnosis also installs the userscript machinery. Softened by keeping
`page-diagnose` a self-contained skill with its own references and its own `/devtools`, not
removed.

## Layout

| Piece | What it owns |
|---|---|
| `skills/userscript-author/` | The authoring method, `patterns.md`, `probes.md`, `greasyfork.md`, `gm-api.md` |
| `skills/page-diagnose/` | Symptom-first diagnosis, `attaching.md`, `tools.md` |
| `references/facts.md` | **Every falsifiable claim, once**, with an ID, a date and a re-measure recipe |
| `references/routes.md` | The five routes: gate, probe, how to open, fidelity, disarm obligation |
| `references/pick-protocol.md` + `pick-envelope.schema.json` | The pick contract |
| `references/cdp-extras.md` | Raw-CDP surface no MCP tool exposes, as symptom → command |
| `scripts/` | Everything deterministic — the picker, the validator, the linter, the route probe |

## Scripts

```bash
scripts/page-route.sh                      # which route is available right now
scripts/route-up.sh                        # how to OPEN a route, not just name it
scripts/userscript-meta-lint.sh <path|dir> # Greasy Fork readiness
scripts/pick-validate.mjs --self-test scripts/fixtures
scripts/devtools-doctor.sh                 # CDP connection preflight
node scripts/pick-element.mjs              # arm the picker (or the page-lab-pick CLI)
```

Wire the linter into CI:

```yaml
- run: plugins/page-lab/scripts/userscript-meta-lint.sh userscripts/
```

Requires `bash`, and `node` for the `.mjs` scripts. Zero npm dependencies.

## Facts are dated, not remembered

`references/facts.md` is the single source of volatile truth. Every other file states a
falsifiable fact in at most one clause and cites `[F-ID]`. Rows marked **UNVERIFIED** are
promoted only by re-running their recipe and dating the result — never by tidying the table.

That discipline is not decoration. Measured examples currently in the table:

- `chrome-devtools-mcp@1.8.0` ships **29** tools, not the ~57 its generated docs describe —
  so the entire Extensions group does not exist, and any plan built on `install_extension`
  fails at the first call.
- `$0` is **not** readable from a separate CDP session. Do not retry it.
- `Overlay.setInspectMode({mode:'none'})` **rejects** unless `highlightConfig` is passed on the
  *disarm* too — which is why one `try/catch` around a disarm loop leaves every tab armed.

## Safety posture, inherited and non-negotiable

- **An armed picker swallows the next click on every armed tab.** Every disarm is guarded
  independently, with a timeout, a signal handler and a detached watchdog.
- **An open remote-debugging port is an unauthenticated control channel** — any local process
  can drive that browser and read its cookies and session state. Hand-run only, never a launchd
  agent or login item, closed when the work ends.
- **Both telemetry flags on every `chrome-devtools-mcp` invocation** — `--no-usage-statistics`
  *and* `--no-performance-crux`; the second otherwise sends **traced URLs** off-machine.
- **Never present lab data as field data.** A local trace is one sample on one machine.
- **An agent cannot install a userscript or flip a `chrome://extensions` toggle.** That click is
  always the operator's.

## Licence

MIT. `chrome-devtools-mcp` is Google's, under its own licence.
