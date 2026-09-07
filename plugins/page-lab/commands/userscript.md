---
description: Author or fix a Violentmonkey userscript for a site, to a greasyfork.org-publishable standard — measure the live page first, never guess a selector.
argument-hint: <site-or-url> <what you want changed>
---

Run the **`userscript-author`** skill from this plugin, end to end, for: `$ARGUMENTS`

## Sequence

- **0.5 — Route before anything.** Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/page-route.sh`. It
  prints `ROUTE_SHELL=cdp|kapture|none` and an `AGENT-MUST-CHECK:` block naming the two checks a
  shell cannot make; make them, then re-run with `--tools kapture-eval=yes|no,cic=yes|no,inapp=yes|no` for the
  final `ROUTE=`. If a gate is shut, `bash ${CLAUDE_PLUGIN_ROOT}/scripts/route-up.sh --tier <n>`
  says how to open it. **Do not improvise past a dark gate** — knowing the route is what decides
  whether measuring is possible at all.
- **1 — Shelf first.** Fetch `https://greasyfork.org/en/scripts/by-site/<bare-domain>` (and
  Sleazy Fork if the site is adult-adjacent — a site's scripts land on only one of the two).
  Report **hit-adapted / hit-rejected (why) / empty**. "Nobody looked" and "nothing exists" must
  not read the same.
- **2 — Measure, do not guess.** When the target is an element the operator can point at, start
  with `/pick` and carry its envelope forward; resolve every `shipBlockers` entry **before**
  writing anything. Then run the probes in `skills/userscript-author/probes.md` against the live
  page for state A (what the site gives) and state B (the state wanted), and `diff(a, b)`.
- **3 — Take the verdict's route** — DOM-DIFFERS → set the site's own attribute; DOM-IDENTICAL →
  lift its own `@media` rules by condition in a band; STATE-B-UNREACHABLE → construct, and
  justify every invented selector with its measured line.
- **4 — Write** down the reuse ladder in `skills/userscript-author/patterns.md`, stopping at the
  first hit. Open the file's WHY block with the measured finding and the dated selectors.
- **5 — Lint:** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/userscript-meta-lint.sh <file>`.
- **6 — Publish** only if asked — `skills/userscript-author/greasyfork.md` has the rulebook and
  the sync setup.

## Non-negotiable

- **Never ship a selector, class, or breakpoint that was not dumped from the live page.** If no
  route on the ladder is reachable, say so and stop; ask the operator to paste the probe into
  their console and hand back the JSON. That is a valid measurement.
- **A picked element is a measurement only when** the envelope's `fidelity` is `verified`, a
  candidate has `matches == 1`, and `shipBlockers` is empty. A `kapture-N` selector never reaches
  a `.user.js` — it evaporates on reload, and the linter fails the file.
- **Never `@require`/`@resource` from a CDN** — no SRI exists under Violentmonkey. Vendor with
  attribution instead.
- **Degrade to stock, never mangle.** A script that cannot do its job becomes a no-op.
- **`assertEffect()` after a real install is not optional.** The protocol measures the page, never
  the userscript runtime.
- Anything the user has not stated — colour, density, typography, which furniture goes — is
  **asked**, not inferred.

End with the **Userscript report** block from `references/report-format.md`.
