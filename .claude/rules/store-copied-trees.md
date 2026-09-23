---
# Claude Code reads `paths:` (docs/en/memory § Path-specific rules): this only
# matters when touching a tree that a DIRECTORY path literal copies wholesale
# into the Nix store.
description: Directory path literals copy the whole tree into the store — a stray file becomes a closure input.
paths:
  - "sites/**"
---

# Store-copied trees — every byte is a closure input

**Two** trees under `sites/` are referenced by a **directory** path literal, not file-by-file
— and `sites/` holds exactly two directories, so that is **all** of them:

| Tree | Referenced from | Lands in |
|---|---|---|
| `sites/snoringirl/` | `modules/parts/identity.nix:139` — `hostedSites[].root = ../../sites/snoringirl` | the **live** nixpi closure |
| `sites/ismail-landing/fonts/` | `modules/shared/next-right-thing.nix:36` — `fontDir = ../../sites/ismail-landing/fonts` | the `macos` home closure (the widget's `NRT_FONT_DIR`) |

**Absent from `hostedSites` is not absent from a closure** — that is the whole reason the
second row exists. `sites/ismail-landing` stopped being Caddy-served on 2026-09-16, so the
tree reads as a dead archive; its `fonts/` subdir is still a build input to the Next Right
Thing generator on `macos`. Checking only `hostedSites` to decide what ships would miss it.

Note the asymmetry in that column: row 1 points at the **whole** site tree, row 2 at one
**subdirectory**. So a stray file directly under `sites/ismail-landing/` reaches no closure,
while one under its `fonts/` does. The check below deliberately sweeps all of `sites/` anyway
— it costs nothing, and it does not have to track which subtree is currently load-bearing.

Ported from the private nix-personal flake when it was retired (2026-09-15) and folded into
this repo — the footgun it documents is unchanged, only the location moved.

A directory literal copies the directory **as it is on disk**. That has two consequences:

1. **A stray file becomes a build input.** A `.DS_Store` (or `._*`, `Thumbs.db`) inside either
   tree above would change that tree's consuming derivation — `nixpi`'s toplevel or `macos`'s —
   and ship Finder/OS metadata into a world-readable store path, invisible to `git status`
   because it's gitignored. Measured on the original tree
   (2026-09-12, a different one): deleting the strays returned the drv to its clean-rev hash
   exactly.
2. **Gitignore does not protect you here.** Ignoring a file keeps it out of git; it does *not*
   keep it out of a directory copy. The two mechanisms are unrelated.

## Before committing a change under `sites/`

```bash
find sites -name '.DS_Store' -o -name '._*' -o -name 'Thumbs.db'   # must be empty
git status --porcelain                                            # the `git add -A` workflow sweeps
```

If a derivation moved and you only edited a comment or a doc, suspect a stray file under
`sites/` before suspecting your edit — and read *which* output moved, because the two trees
report to different places: `sites/snoringirl/` moves the `nixpi` toplevel, while
`sites/ismail-landing/fonts/` moves the `macos` one. `scripts/drv-snapshot.sh` is the harness
that tells you which.

## Do not "fix" this by narrowing the literal

Pointing at individual files instead would work but loses the point: a site is a *tree*, and
enumerating its files is a list that goes stale silently. Keep the directory literal and keep
the tree clean.

The `fonts/` row is **not** a counter-example to that. It is still a directory literal — it
just names the one subtree that is actually consumed, rather than enumerating the two `.woff2`
files inside it. Narrowing to a *tree* is fine; narrowing to a *file list* is what goes stale.
