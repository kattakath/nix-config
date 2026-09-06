---
description: Author or fix a Violentmonkey userscript for a site, to a greasyfork.org-publishable standard — measure the live page first, never guess a selector.
argument-hint: <site-or-url> <what you want changed>
---

Run the **`userscript-author`** skill from this plugin, end to end, for: `$ARGUMENTS`

## Sequence

1. **Shelf first.** Fetch `https://greasyfork.org/en/scripts/by-site/<bare-domain>` (and
   Sleazy Fork if the site is adult-adjacent — a site's scripts land on only one of the two).
   Report **hit-adapted / hit-rejected (why) / empty**. "Nobody looked" and "nothing exists"
   must not read the same.
2. **Measure, do not guess.** Run the probes in `probes.md` against the live page for state A
   (what the site gives) and state B (the state wanted), then `diff(a, b)`.
3. **Take the verdict's route** — DOM-DIFFERS → set the site's own attribute; DOM-IDENTICAL →
   lift its own `@media` rules by condition in a band; STATE-B-UNREACHABLE → construct, and
   justify every invented selector with its measured line.
4. **Write** down the reuse ladder in `patterns.md`, stopping at the first hit. Open the file's
   WHY block with the measured finding and the dated selectors.
5. **Lint:** `scripts/userscript-meta-lint.sh <file>`.
6. **Publish** only if asked — `greasyfork.md` has the rulebook and the sync setup.

## Non-negotiable

- **Never ship a selector, class, or breakpoint that was not dumped from the live page.**
  If neither browser-automation route is reachable, say so and stop; ask the operator to paste
  the probe into their console and hand back the JSON. That is a valid measurement.
- **Never `@require`/`@resource` from a CDN** — no SRI exists. Vendor with attribution instead.
- **Degrade to stock, never mangle.** A script that cannot do its job becomes a no-op.
- Anything the user has not stated — colour, density, typography, which furniture goes —
  is **asked**, not inferred.

End with the skill's **Userscript report** block.
