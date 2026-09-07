---
name: userscript-author
description: >
  Declare and gate a Violentmonkey userscript IN THIS REPO: the file
  `userscripts/<kebab>.user.js` plus its one-line entry in
  `programs.ungoogledChromium.userScripts.scripts`
  (`modules/shared/home.nix`). Use when asked to "make <site> do X", "write a
  userscript for <site>", "fix my <site> script", or "this site's X annoys me".
  The authoring METHOD lives in the portable `userscript-author` plugin
  (`plugins/page-lab/`); this skill owns only what is specific to this
  fleet — the Nix declaration, the gate, and how a script reaches the browser here.
---

# Userscript author — the FLEET layer

**Method is not here.** Measuring, diffing, replaying, the code patterns, the probes and the
Greasy Fork rulebook all live in the **`userscript-author` plugin**
([`plugins/page-lab/`](../../../plugins/page-lab/)), which is deliberately
portable — it stops at a lint-clean `.user.js` and knows nothing about Nix. Invoke it as the
`page-lab:userscript-author` skill, or read
[its SKILL.md](../../../plugins/page-lab/skills/userscript-author/SKILL.md).

**This skill owns the delivery half the plugin cannot:** declaring the script in Nix, this
repo's gate, and the install reality on this Mac.

```
[plugin] wish → shelf → measure → diff → write
[here]   → declare in home.nix → gate → PR → activate → one click
```

## Standing preference (thin by design — append, never invent)

| # | Statement | Confidence | Evidence |
|---|---|---|---|
| **UI-1** | Give me **the site's own compact/narrow chrome at full width** — navigation shrinks, content takes the reclaimed space. | **VERIFIED** | the entire purpose of `userscripts/google-photos-icon-nav.user.js` |

- **Correction, load-bearing:** the 80px rail, the hover peek-back, the hidden storage footer and
  the 1px `Collections` divider are **Google's own design at its own breakpoint**, inherited as
  **one package** under UI-1 — **not** four separately stated preferences.
- Any preference **not in that table** is **asked via AskUserQuestion** (click-to-select,
  recommended first), never inferred. A row is **appended only after a shipped script proves it**.
- The plugin's own method rules (degrade-to-stock; never reimplement a state the site already
  renders) are general, and live there rather than here.

## Hard rules (fleet-specific — the plugin carries the rest)

1. **Seed from the gated script, delete its body** —
   `cp userscripts/google-photos-icon-nav.user.js userscripts/<kebab>.user.js`. That file is
   checked by CI on every PR, so its header is correct **by construction**; never hand-type a
   metadata block. Keep the block, retarget `@name` / `@description` / `@match` / `@homepageURL`
   / `@supportURL`, **reset `@version` to `1.0.0`**, and **DELETE THE BODY** — it is a
   `document-start` CSS-replay script, so its `@run-at` and style-injection shape are **wrong**
   for a DOM script (plugin `patterns.md` § `@run-at`).
2. **Never a secret** — `source` is copied into the **world-readable Nix store**, private flake
   or not (`modules/shared/chromium.nix`).
3. Follow [git-purity](../../rules/git-purity.md) + [pr-title](../../rules/pr-title.md); the index
   is root [`CLAUDE.md`](../../../CLAUDE.md), long form
   [`docs/repo-map.md`](../../../docs/repo-map.md) § `userscripts/`.

## Declare it

- [ ] Add **exactly one line** — `<kebab> = ../../userscripts/<kebab>.user.js;` — inside the
      existing `scripts = { … };` attrset of `modules/shared/home.nix`. Nothing else changes.
- [ ] A `../../` **source literal is repo-relative, correct and idiomatic — never "fix" it to a
      home path.**
- [ ] **Key collision:** nix-personal's private keys are **invisible from this repo**, and the
      module system treats a repeated key as a **conflict, not an override** — **ASK the
      operator** before claiming a plausible name.

## Gate

```bash
git add -A
nix build .#checks.aarch64-darwin.userscripts
nix fmt
git add -A                        # fmt may rewrite
git status --porcelain '*.nix'    # clean of ??
nix flake check
```

`checks.<system>.userscripts` **runs the plugin's linter** —
`plugins/page-lab/scripts/userscript-meta-lint.sh` — so the rulebook lives in exactly
one place and CI, the plugin and any other consumer cannot drift apart. Its contract is in the
plugin README; what it deliberately does **not** check is `patterns.md` § 10.

- [ ] If `nix` is unavailable: run the linter directly
      (`plugins/page-lab/scripts/userscript-meta-lint.sh userscripts/`),
      `nix-instantiate --parse` the changed `.nix`, and state the rest is **CI-deferred**.
- [ ] **A private (nix-personal) script is NOT covered by that check.** It globs
      `${self}/userscripts/*.user.js` — this repo's tree only. Owning the *option* does not gate
      the consumer, and **the build still goes green**, which is the trap. Measured 2026-08-31:
      nix-personal's `civitai-declutter` had shipped with **no `@license`** and the check never
      saw it. For a private script, point the linter at nix-personal's `userscripts/` by hand —
      it takes a path, so this is one command, not a reimplementation.

## Install reality (no Nix↔Violentmonkey bridge)

- Activation is the operator's move: **`activate`** from nix-personal — **NEVER**
  `darwin-rebuild switch --flake .#macos` from this repo.
- It rewrites `~/.local/share/userscripts/` + `index.html`, and **never touches Violentmonkey's DB.**
- One-time per profile, in `chrome://extensions`: **Allow User Scripts** + **Allow access to
  file URLs** (Chrome 138+ refuses to let policy set the first).
- A **click-through in `index.html` is required for a new script and after every edit** — Claude
  cannot install a script, flip a toggle, or drive Violentmonkey's dialog.

## Live-edit loop — which file to track HERE

The loop itself, its gotchas and the `Install`-vs-`+ Track` trap are in the plugin. What is
fleet-specific is **which of the three copies is the writable one** (measured 2026-08-31):

| Path | Mode | Track it? |
|---|---|---|
| `userscripts/<kebab>.user.js` (repo) | `-rw-r--r--` | **YES** — the only writable copy |
| `$XDG_DATA_HOME/userscripts/<kebab>.user.js` | symlink → `/nix/store/…` | **no** — read-only build artifact |
| `$XDG_DATA_HOME/userscripts/index.html` | symlink → `/nix/store/…` | **no** — that is the *install* path, and it installs the read-only copy |

Also fleet-specific: **the gate cannot see an unstaged edit** — it globs the **git tree**, so
finish with the gate above (`git add -A` first), not with a green browser. And the materialised
copy stays stale for the whole session; reconcile at the end with the gate, then `activate`.

## Live-edit loop (no operator at the keyboard — fallback)

When there is no human to click an installer — an agent-driven session — inject the saved body
straight into a matching Kapture tab. There is no plugin for this; it is one POST, so a wrapper
earned nothing (`plugins/userscript-preview` did exactly this and was retired 2026-09-04):

```bash
python3 - <<'EOF'
import json, re, urllib.request, pathlib
raw = pathlib.Path('userscripts/<kebab>.user.js').read_text()
body = re.sub(r"//\s*==UserScript==.*?//\s*==/UserScript==", "", raw, flags=re.S).strip()
req = urllib.request.Request("http://127.0.0.1:61822/tab/<tabId>/evaluate",
    data=json.dumps({"code": body, "timeout": 30000}).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
print(urllib.request.urlopen(req, timeout=40).read().decode()[:200])
EOF
```

- Tab must have Kapture connected and **Allow JS execution** (`evalAllowed`).
- The IIFE **must** call `window.__nix<Name>Teardown()` first, or each inject stacks
  another observer. A leftover `data-*Init` early-return makes inject a no-op instead
  — do not add one.
- Injecting over an OLDER installed build that predates its teardown makes the two
  copies fight for last-in-head until the tab pegs, and the POST times out (measured
  2026-09-04). Install the new version first, or use the tracked loop.
- Injection dies on reload. Ship with `activate` + click as usual.

## Publish

The rulebook is the plugin's
[`greasyfork.md`](../../../plugins/page-lab/skills/userscript-author/greasyfork.md).
The only fleet-specific part is the sync source for a script that lives here:

```
https://raw.githubusercontent.com/kattakath/nix-config/main/userscripts/<kebab>.user.js
```

Sync is a **site-side setting** on Greasy Fork, not the banned `@updateURL` — the file stays
clean, and users still update from Greasy Fork.

## Report format (always end with this)

```markdown
## Userscript report
- **Wish:** (URL + the state asked for)
- **Shelf:** hit-adapted | hit-rejected (why) | empty — (which index/indices were fetched)
- **Measured:** (probes run, `innerWidth` A/B, cross-origin sheet count)
- **Diff verdict:** DOM-DIFFERS | DOM-IDENTICAL | STATE-B-UNREACHABLE
- **Approach:** (attribute set | rules lifted by condition in band X–Y | constructed UI)
- **Selectors shipped:** (each one, with the date measured — or "none")
- **Files:** userscripts/<kebab>.user.js · modules/shared/home.nix
- **Gates:** userscripts ✅/❌ · fmt ✅/❌ · flake check ✅/❌
- **Operator action:** activate, then click <kebab> in index.html and confirm
- **Verdict:** SHIPPED | BLOCKED (why) | ESCALATED (vite-plugin-monkey)
```

## Compose with existing automation

```
/userscript <site> <wish>  → this skill + the userscript-author plugin
/eval                      → eval only
/hygiene                   → doc/index drift after the PR lands
```
