---
name: resolve-the-real-nixpkgs-lock-node
description: `nix flake metadata --json`'s node named "nixpkgs" is a TRANSITIVE input here — the root's nixpkgs is node `nixpkgs_2`. Follow root.inputs, or you read the wrong revision
metadata:
  type: feedback
---

**Never read `flake.lock`'s node literally named `nixpkgs` as "the pinned nixpkgs" in this
repo.** Follow the root node's inputs:

```bash
python3 -c "
import json; d=json.load(open('flake.lock')); n=d['nodes']
k=n[d['root']]['inputs']['nixpkgs']; print(k, n[k]['locked']['rev'])"
```

Measured 2026-10-06: the root's nixpkgs is node **`nixpkgs_2`**
(`DeterminateSystems/nixpkgs-weekly`, rev `44a91898…`, 26.11). The unsuffixed `nixpkgs`
node is `NixOS/nixpkgs` rev `c5c4a43b…`, 26.05 — a **transitive** input of the
Nix/Determinate node. A whole lane of research was sourced from the wrong revision before
this was caught.

**Why:** `nix flake metadata --json` emits the lock's raw node table, and lock node names
are de-duplicated with `_N` suffixes in arbitrary order; the bare name is not the root's.

**How to apply:** when you need the source tree, prefer the documented form from
`.claude/rules/upstream-first.md`, which resolves through the flake and cannot pick the
wrong node:

```bash
nix eval --raw --impure --expr \
  'builtins.toString (builtins.getFlake "'"$PWD"'").inputs.nixpkgs.outPath'
```

Cross-check the result with `cat <path>/.version` (expect `26.11`, not `26.05`). And do not
cite upstream `file:line` numbers in a repo comment — they drift on every weekly bump; name
the file and the option/attr instead.
