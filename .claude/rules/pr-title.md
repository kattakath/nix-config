# Commit Subject (and PR Title) — Comma-Separated List of Touched Components

A commit subject on `main` — and a PR title, on the rare PR — is a **comma-separated
list of the components the change touches**, then a colon and a short summary. It is not a
prose sentence. Each component is derived — don't consult a fixed
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

List every touched component, comma-separated. Example: a commit touching
`modules/darwin/*` + `.claude/rules/*` + `docs/` → subject
`darwinConfigurations, claude, docs: <what changed>`.

If a PR's scope grows after it is opened, keep the title in sync with the new
combined scope.

**Note the asymmetry.** The dot-folder half (2) is **mechanically** derivable from
the path — strip the dot — so a hook could generate it automatically. The
flake-output half (1) is a **semantic** mapping requiring judgment against a
maintained path→output map, which a hook could not derive reliably. That is why
this stays a prompt rule rather than a fully mechanical one.

## One commit per change, pushed to `main` — PRs are the exception

The default lane is a **direct push to `main`**: the global `claude/CLAUDE.md` § Landing on
the fleet, with this repo's specifics in [`landing-changes.md`](landing-changes.md). One
logical change is one commit, rebased onto `origin/main` and pushed. Independent changes are
separate commits and separate pushes, so a red one points at one cause. A change that depends
on another lands after it, in the same push or the next one. There is no parent PR to wait on.

**Open a PR only when:** Ismail asks for one; the author is a bot, Dependabot or a fork; or a
change needs `build-darwin` (PR-only) BEFORE it reaches `main`. When you do, the machinery
from before still applies: `auto-merge.yml` arms every non-draft operator PR, so park work in
flight as a **draft**. A draft does not leave a merge queue it already joined. History and the
measurements: [`docs/pr-wait-research.md`](../../docs/pr-wait-research.md).
