---
description: Author or fix a Violentmonkey userscript for a site, measured against the live DOM
argument-hint: "<site> <wish>  # e.g. photos.google.com icon rail at every width | fix google-photos-icon-nav"
---

Use the **userscript-author** skill (`.claude/skills/userscript-author/SKILL.md`) for: $ARGUMENTS

Pipeline: **check the shelf first** — `greasyfork.org/en/scripts/by-site/<domain>` (and
`sleazyfork.org/…` for adult-adjacent sites; one codebase, but a site lands on only one) → measure
state A vs B with claude-in-chrome → diff (**identical ⇒ pure CSS media query, so
replay its condition in a band; different ⇒ set the attribute the site sets**) → seed the header from
`userscripts/google-photos-icon-nav.user.js` (`@version` → `1.0.0`) → one line in `modules/shared/home.nix`
→ `git add -A` → `nix build .#checks.aarch64-darwin.userscripts` → `nix flake check` → PR.

**Never** `@require`/`@resource` (install-time CDN fetch, so Nix pins nothing and the gate never sees
it), **never a secret** (the store is world-readable), **never a selector not dumped from the live page**.

At a **4th script**, TS/JSX, or `GM_*` plus a settings UI — **stop and propose vite-plugin-monkey** as
its own PR, never grow a bundler. Installing stays a manual click **per change**: open `index.html`
under `~/.local/share/userscripts/`, click the script, confirm Violentmonkey.

$ARGUMENTS
