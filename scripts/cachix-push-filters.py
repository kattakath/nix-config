"""Fail unless every cachix-action push site filters Anthropic's All-rights-reserved artifacts.

Usage: cachix-push-filters.py ROOT  (exit 1 on any unfiltered site, 0 otherwise).

The kattakath Cachix is PUBLIC. claude-code (unfree, redistributable = false in nixpkgs), its
`claude.zst` source, the npm @anthropic-ai/claude-agent-sdk tarball and our
hook-types-node-modules (which unpacks it) must never be pushed there. Every
`cachix/cachix-action` step under .github/ therefore needs a `pushFilter` whose regex MATCHES
each sample store-path name below. The test is semantic (the regex is run), so a filter that is
present but broken still fails. Born 2026-11-25, when a composite action turned out to be a
push site that a grep of .github/workflows/ alone had missed.
"""
import os
import re
import sys

SAMPLES = [
    "/nix/store/1k0q3n9djm1dsbqbvbxfaqvnnskgbd4a-claude-code-2.1.322",
    "/nix/store/27k6ks52a36hd0783irswqrdriwk6gc3-claude.zst",
    "/nix/store/afss2f65h2v8j5f0ir8kc1jqvzcysddx-claude-agent-sdk-0.3.330.tgz",
    "/nix/store/057934scb21b91d5a7zyh76fmhq87mgj-hook-types-node-modules",
]
# A filter must not swallow everything: our own claude-* config paths stay cacheable.
MUST_NOT_MATCH = "/nix/store/ak65kk5n94gfbkp231h0hywsibalm8sz-claude-managed-settings.json"

root = sys.argv[1]
sites, bad = 0, []
for dirpath, _, filenames in os.walk(os.path.join(root, ".github")):
    for name in filenames:
        if not name.endswith((".yml", ".yaml")):
            continue
        rel = os.path.relpath(os.path.join(dirpath, name), root)
        lines = open(os.path.join(dirpath, name)).read().splitlines()
        for i, line in enumerate(lines):
            if not re.match(r"\s*-?\s*uses:\s*cachix/cachix-action@", line):
                continue
            sites += 1
            indent = len(line) - len(line.lstrip(" -"))
            flt = None
            for nxt in lines[i + 1:]:
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) < indent:
                    break
                m = re.match(r'\s*pushFilter:\s*"(.*)"\s*$', nxt)
                if m:
                    flt = m.group(1).replace("\\\\", "\\")
            if flt is None:
                bad.append(f"{rel}: cachix-action with no pushFilter")
                continue
            missed = [s for s in SAMPLES if not re.search(flt, s)]
            if missed:
                bad.append(f"{rel}: pushFilter {flt!r} lets through {', '.join(p.split('-', 1)[1] for p in missed)}")
            if re.search(flt, MUST_NOT_MATCH):
                bad.append(f"{rel}: pushFilter {flt!r} also blocks our own claude-managed-settings")

if sites == 0:
    print("cachix-push-filters: VACUOUS - no cachix-action found under .github/", file=sys.stderr)
    sys.exit(1)
if bad:
    print("cachix-push-filters: a push site could publish Anthropic's artifacts to the public cache:", file=sys.stderr)
    for b in bad:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
print(f"cachix-push-filters: all {sites} cachix-action push sites filter the protected artifacts")
