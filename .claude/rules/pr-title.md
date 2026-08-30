# PR Title — Comma-Separated List of Touched Components

The PR title is a **comma-separated list of the components the change touches**,
not a prose sentence. Each component is derived — don't consult a fixed
enumeration, apply the rule:

1. **A first-level `nix flake show` output category** when the change touches a
   flake output — e.g. `apps`, `checks`, `packages`, `nixosConfigurations`,
   `darwinConfigurations`, `formatter`, `devShells`. This is a **semantic** map
   from source path to output (`modules/darwin/*` → `darwinConfigurations`,
   `hosts/nixpi*` → `nixosConfigurations`, `packages/*` → `packages`, and so on),
   so it needs judgment and a maintained path→output mapping.
2. **A top-level directory named by stripping its leading dot** — `.claude` →
   `claude`, `.github` → `github`, `.vscode` → `vscode`, `.devcontainer` →
   `devcontainer`, and so on. These mappings are **illustrative, not exhaustive**:
   ANY top-level dot-folder maps to its own de-dotted name automatically, so a new
   one needs no edit to this rule. (`docs` also falls here, covering `docs/`, any
   `*.md`, and `CLAUDE.md`.)

List every touched component, comma-separated. Example: a PR touching
`modules/darwin/*` + `.claude/rules/*` + `docs/` → title `darwinConfigurations, claude, docs`.

If a PR's scope grows after it is opened, keep the title in sync with the new
combined scope.

**Note the asymmetry.** The dot-folder half (2) is **mechanically** derivable from
the path — strip the dot — so a hook could generate it automatically. The
flake-output half (1) is a **semantic** mapping requiring judgment against a
maintained path→output map, which a hook could not derive reliably. That is why
this stays a prompt rule rather than a fully mechanical one.

## One PR per change

Default GitHub behaviour: **one PR per logical change, branched off `main`.** There
is no session-batching rule — an already-open PR is not a reason to pile the next
change onto its branch. The repo's **merge queue** serializes and validates
integration (see [`docs/auto-merge-and-merge-queue.md`](../../docs/auto-merge-and-merge-queue.md)),
so independent PRs are the cheap, reviewable shape.
