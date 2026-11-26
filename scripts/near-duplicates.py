"""Fail when a paragraph in one LIVE agent-facing doc is a near-copy of one in another.

ADR-014 § 4 C. Usage: near-duplicates.py ROOT  (exit 1 on any pair, 0 otherwise).

Scope is the docs every session loads or every audit reads: CLAUDE.md, claude/, .claude/
(markdown), docs/repo-map.md and docs/map/. ADRs, studies and retired history docs keep
their as-of text on purpose and are out of scope.

Method: 6-word shingles per paragraph of 30+ words, Jaccard similarity across files. Tables,
code fences and HTML comments are skipped (a table row restates by design; a generated span
is proven by hosts-documented). Measured 2026-11-25: 0 pairs at >= 0.5 in this scope; the
whole-repo scan found 8, all outside it (capsule README provenance boilerplate and one
retired doc). jscpd is the off-the-shelf tool for this and was not used: it is not in nixpkgs.
"""
import itertools
import os
import re
import sys

THRESHOLD = 0.5
MIN_WORDS = 30
SHINGLE = 6

root = sys.argv[1]


def in_scope(rel):
    if not rel.endswith(".md") or rel.startswith(".claude/worktrees/"):
        return False
    return (
        rel in ("CLAUDE.md", "docs/repo-map.md")
        or rel.startswith(("claude/", ".claude/", "docs/map/"))
    )


files = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != ".git"]
    for name in filenames:
        rel = os.path.relpath(os.path.join(dirpath, name), root)
        if in_scope(rel):
            files.append(rel)

paras = []
for rel in sorted(files):
    text = open(os.path.join(root, rel), errors="replace").read()
    for p in re.split(r"\n\s*\n", text):
        if p.lstrip().startswith(("|", "```", "<!--")):
            continue
        words = re.sub(r"[^a-z0-9 ]", " ", p.lower()).split()
        if len(words) >= MIN_WORDS:
            shingles = {tuple(words[i:i + SHINGLE]) for i in range(len(words) - SHINGLE + 1)}
            paras.append((rel, shingles, " ".join(words[:14])))

if not paras:
    print("near-duplicates: VACUOUS - no paragraph in scope", file=sys.stderr)
    sys.exit(1)

index = {}
for i, (_, shingles, _) in enumerate(paras):
    for s in shingles:
        index.setdefault(s, []).append(i)
pairs = set()
for ids in index.values():
    if len(ids) > 1:
        pairs.update(itertools.combinations(ids, 2))

hits = []
for i, j in sorted(pairs):
    a, b = paras[i], paras[j]
    if a[0] == b[0]:
        continue
    jac = len(a[1] & b[1]) / len(a[1] | b[1])
    if jac >= THRESHOLD:
        hits.append((jac, a[0], b[0], a[2]))

if hits:
    print(f"near-duplicates: {len(hits)} paragraph pair(s) restate each other (Jaccard >= {THRESHOLD}):", file=sys.stderr)
    for jac, fa, fb, start in sorted(hits, reverse=True):
        print(f"  {jac:.2f}  {fa}  <->  {fb}  | {start} ...", file=sys.stderr)
    print("Keep one copy; make the other a pointer (ADR-014 § 3).", file=sys.stderr)
    sys.exit(1)
print(f"near-duplicates: {len(paras)} paragraphs in {len(files)} live docs, no cross-file restatement")
