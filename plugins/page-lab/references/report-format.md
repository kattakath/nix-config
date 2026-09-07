# Report format — the canonical blocks

Two blocks live here and **only** here. Every skill and command that ends with a report links
to this file; none of them copies the block. A second copy is a doc-drift lie waiting for the
next edit to land in one place and not the other.

## Userscript report

Ends every `page-lab:userscript-author` run. Ten lines, exactly these rows, in this order:

```markdown
## Userscript report
- **Wish:** (URL + the state asked for)
- **Shelf:** hit-adapted | hit-rejected (why) | empty — (which index/indices were fetched)
- **Measured:** (probes run, `innerWidth` A/B, cross-origin sheet count)
- **Diff verdict:** DOM-DIFFERS | DOM-IDENTICAL | STATE-B-UNREACHABLE
- **Approach:** (attribute set | rules lifted by condition in band X–Y | constructed UI)
- **Selectors shipped:** (each one, with the date measured — or "none")
- **Lint:** ✅/❌
- **Operator action:** (install / toggle / publish — whatever a human must click)
- **Verdict:** SHIPPED | BLOCKED (why) | ESCALATED (vite-plugin-monkey)
```

### Filling it when a pick was taken

The block does not grow a row for the picker. Two existing rows carry it:

- **`Measured:`** names the route and the fidelity — e.g. *"tier 1 `cdp-overlay`, fidelity
  `verified`, 3 candidates scored, viewport 1512×857 @2"*. If `shipBlockers` was non-empty at
  any point, name each blocker and how it was resolved.
- **`Selectors shipped:`** carries the envelope's `measuredAt` date against each selector.
  That date **is** the citation the dated `WHY` block needs.

A pick that never reached `fidelity:"verified"` with an empty `shipBlockers` cannot appear
under `Selectors shipped:` — it appears under `Verdict: BLOCKED`, with the blocker named.
The envelope contract is [`pick-protocol.md`](pick-protocol.md) § 1.

### Rows the fleet skill adds

`.claude/skills/userscript-author/SKILL.md` renders the same block and appends **only** these
three, because only they are specific to how a script reaches this fleet's browser:

```markdown
- **Files:** userscripts/<kebab>.user.js · modules/shared/home.nix
- **Gates:** userscripts ✅/❌ · fmt ✅/❌ · flake check ✅/❌
- **Operator action:** activate, then click <kebab> in index.html and confirm
```

The fleet `Operator action:` replaces the portable one; `Files:` and `Gates:` slot in ahead of
it. Nothing else in the block changes.

## Diagnosis report

Ends every `page-lab:page-diagnose` run:

```markdown
## Diagnosis report
- **Question:** (URL + what was actually asked)
- **Mode:** launch-isolated | attach (which profile, and why it had to be that one)
- **Measured:** (which workflow ran, and the insight or request it named)
- **Numbers:** (the insight's own figures, copied — not converted into a grade)
- **Finding:** (what those numbers support, and nothing beyond it)
- **Caveat:** one local run is one sample on one machine — lab data, not field data
- **Verdict:** DIAGNOSED | INCONCLUSIVE (what would settle it) | HANDED OFF (page-lab:userscript-author)
```

The **Caveat** row is mandatory and is not a formality: a local trace on a developer machine
on a home connection is not what users experience, and presenting it as such is the most
common way a true measurement becomes a false claim.

## Two rules that apply to both blocks

- **No secret values.** Refer to a token, key or session by name; never print one, in a report
  or anywhere else.
- **No serialized page markup.** The envelope has no `outerHTML` field by construction, and a
  report does not reintroduce one — name the element, its selector and its measured text.
