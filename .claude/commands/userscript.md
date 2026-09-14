---
description: Author or fix a Violentmonkey userscript for a site — routes to the page-lab plugin; this fleet no longer declares or gates scripts in Nix
argument-hint: "<site> <wish>  # e.g. photos.google.com icon rail at every width | fix google-photos-icon-nav"
---

Run the **`page-lab:userscript-author`** skill (from the pinned `page-lab` plugin) end to end
for: $ARGUMENTS

Then read `.claude/skills/userscript-author/SKILL.md` for the two things that plugin cannot
know: how a script reaches **this** Mac, and why nothing is declared in Nix here any more.

## The last three steps of the old pipeline are DEAD (2026-09-14, commit 535f1ef)

That commit removed the `kattakath-userscripts` input, every
`local.ungoogledChromium.userScripts.scripts` entry and `checks.<system>.userscripts` together;
nix-personal dropped `modules/userscripts.nix` and both of its gates the same day. Every script
was **published** instead — the last one, `google-photos-icon-nav`, is
`greasyfork.org/scripts/595764` — because a fork-installed copy is the only one that carries an
`@updateURL`, so it self-updates where a materialised file never could.

So, concretely, do **not**:

| Dead step | Why it fails now | Do this instead |
|---|---|---|
| seed from `userscripts/google-photos-icon-nav.user.js` | no `userscripts/` directory in this tree | the plugin writes the metadata block; its linter is the header's correctness proof |
| add a line to `modules/shared/home.nix` | `scripts` is empty on purpose; nothing pins a `.user.js` | publish to Greasy/Sleazy Fork and install from the fork |
| `nix build .#checks.aarch64-darwin.userscripts` | **that derivation does not exist** | the plugin's own `scripts/userscript-meta-lint.sh <file>` (step 5 of `page-lab:userscript`) — the same rulebook, unmoved |

Pipeline today: shelf → route → measure A vs B → diff → write → plugin lint → **publish** →
install from the fork, once. **No PR to this repo**, so no `nix flake check` either.

## The Nix path is DORMANT, not deleted

`local.ungoogledChromium.userScripts` is still in `modules/shared/chromium.nix` — generic,
documented, `enable` still `true` (Violentmonkey is still sideloaded), `scripts = { }` empty.
Reviving it for a script that genuinely must not be public takes all three back **together**: a
pinned input holding the file, one line in `scripts`, and the gate restored. Re-pointing the
gate at an empty tree is why it was deleted rather than kept — a green build over nothing is
strictly worse than no gate.

**Never** `@require`/`@resource` (install-time CDN fetch, no SRI), **never a secret** (a
published script is world-readable twice over), **never a selector not dumped from the live
page**.

At TS/JSX or `GM_*` plus a settings UI — **stop and propose vite-plugin-monkey** in the script's
own repo, never grow a bundler here.

$ARGUMENTS
