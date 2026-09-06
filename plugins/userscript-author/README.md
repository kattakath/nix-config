# userscript-author

Author and maintain **Violentmonkey / Tampermonkey userscripts** for Chromium browsers, to a
standard that can be published on **greasyfork.org**.

Portable by design: it stops at a lint-clean `.user.js`. How the file reaches the browser —
hand-install, a dotfiles repo, Nix, a build step — is yours.

## What's in it

| Piece | What it owns |
|---|---|
| `skills/userscript-author/SKILL.md` | The method: shelf-check → measure A/B → diff → replay-or-select → write → lint → publish |
| `skills/userscript-author/probes.md` | Four browser probes: `dumpSubtree`, `mediaRules`, `diff`, `assertEffect` |
| `skills/userscript-author/patterns.md` | Pre-vetted shapes: SPA navigation, waiting for an element, `@run-at`, CSS injection, replaying a site's own condition, `@grant` selection, `@match` vs `@include`, idempotence, what NOT to do |
| `skills/userscript-author/greasyfork.md` | The publishing rulebook, the metadata contract, and the `@require` tension |
| `scripts/userscript-meta-lint.sh` | A runnable Greasy Fork readiness lint |

## The one invariant

**MEASURE.** Never ship a selector, class, or breakpoint that was not dumped from the live
page. A plausible-looking selector that nobody measured is the single most common way a
userscript silently stops working on the site's next deploy.

The corollary is the method's whole point: **before writing UI, check whether the site already
renders the state you want** (a narrow-viewport layout, a print stylesheet, a logged-out view).
If it does, replaying its own condition beats reimplementing it — and ships without a single
one of the site's generated class names.

## The lint

```bash
scripts/userscript-meta-lint.sh path/to/script.user.js   # or a directory of them
```

Checks, each traceable to a Greasy Fork rule or a real failure mode:

- `node --check` — a `.user.js` is never parsed by a build, so a syntax error otherwise ships
  silently and surfaces as Violentmonkey's useless "Syntax error?" toast with no line number
- required: `@name` `@namespace` `@version` `@description` `@license` `@match` `@homepageURL` `@supportURL`
- banned: `@downloadURL` `@updateURL` `@installURL` — stripped on upload, and they let a push
  mutate an installed copy with no review
- `@version` must be dotted-numeric — Greasy Fork rejects a version it cannot order
- no minified/bundled output — Greasy Fork rejects it outright
- vendored third-party code must carry a source URL — Greasy Fork's inline-library rule

Exit 0 clean, 1 on any failure, and **every** problem in **every** file is reported in one run.

It reads only the `==UserScript==` block, so a `@key` mentioned in prose or inside a regex can
neither satisfy nor trip a rule.

## Wire it into CI

```yaml
- run: plugins/userscript-author/scripts/userscript-meta-lint.sh userscripts/
```

Requires `bash` and (for the syntax check) `node`. It degrades gracefully — without `node` it
skips the parse check and says so, rather than passing silently.

## Not covered

Delivery, installation and the browser toggles are the operator's. Chromium **138+** gates
`chrome.userScripts` behind a per-extension **Allow User Scripts** toggle that a policy cannot
set; before 138 it rides on Developer mode. An agent cannot flip either, nor drive a script
manager's install dialog.

## Licence

MIT.
