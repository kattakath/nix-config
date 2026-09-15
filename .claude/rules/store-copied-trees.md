---
# Claude Code reads `paths:` (docs/en/memory § Path-specific rules): this only
# matters when touching a tree that a DIRECTORY path literal copies wholesale
# into the Nix store.
description: Directory path literals copy the whole tree into the store — a stray file becomes a closure input.
paths:
  - "sites/**"
---

# Store-copied trees — every byte is a closure input

**One** tree in this repo is referenced by a **directory** path literal, not file-by-file:

| Tree | Referenced from | Lands in |
|---|---|---|
| `sites/<name>/` | `modules/parts/identity.nix` — `hostedSites[].root = ../../sites/<name>` | the **live** nixpi closure |

Ported from the private nix-personal flake when it was retired (2026-09-15) and folded into
this repo — the footgun it documents is unchanged, only the location moved.

A directory literal copies the directory **as it is on disk**. That has two consequences:

1. **A stray file becomes a build input.** A `.DS_Store` (or `._*`, `Thumbs.db`) under `sites/`
   would change the `nixpi` derivation and ship Finder/OS metadata into a world-readable store
   path, invisible to `git status` because it's gitignored. Measured on the original tree
   (2026-09-12, a different one): deleting the strays returned the drv to its clean-rev hash
   exactly.
2. **Gitignore does not protect you here.** Ignoring a file keeps it out of git; it does *not*
   keep it out of a directory copy. The two mechanisms are unrelated.

## Before committing a change under `sites/`

```bash
find sites -name '.DS_Store' -o -name '._*' -o -name 'Thumbs.db'   # must be empty
git status --porcelain                                            # the `git add -A` workflow sweeps
```

If the `nixpi` derivation moved and you only edited a comment or a doc, suspect a stray file
under `sites/` before suspecting your edit. `scripts/drv-snapshot.sh` is the harness that
tells you which output actually moved.

## Do not "fix" this by narrowing the literal

Pointing at individual files instead would work but loses the point: a site is a *tree*, and
enumerating its files is a list that goes stale silently. Keep the directory literal and keep
the tree clean.
