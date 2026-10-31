# `git-tidy` — return a checkout to its default branch, fast-forwarded, with every
# local branch whose GitHub PR has MERGED deleted (and its clean, inactive worktree).
#
# The branch half is OFF-THE-SHELF: `gh-poi` (nixpkgs, seachicken/gh-poi) asks GitHub
# for each branch's PR state, so it deletes SQUASH-merged branches — which
# `git branch -d`, `--merged` and `--contains` all report as unmerged — and never a
# branch with no merged PR. It also removes a merged branch's linked worktree when
# that worktree is clean and not current. This wrapper adds only what gh-poi does
# not do: refuse a dirty tree, switch to the default branch, fast-forward it.
#
# Why a wrapper at all, and why `set -e` matters: it replaced a hand-typed one-liner
# whose clean-tree guard was joined by `&&` but whose branch sweep came after a `;`.
# With the tree dirty, the guard failed and the sweep ran anyway (2026-10-30). Here
# every step is fatal, so nothing past a failed guard runs.
#
# Fast-forward ONLY: if the default branch has diverged (a history rewrite upstream,
# or local commits), it stops and says so rather than resetting anything.
#
# Usage: git-tidy [gh-poi flags]   e.g. `git-tidy --dry-run`, `git-tidy --state closed`
# gh-poi takes its GitHub auth from the `gh` on PATH (programs.gh).
{
  writeShellApplication,
  git,
  gh-poi,
}:
writeShellApplication {
  name = "git-tidy";
  runtimeInputs = [
    git
    gh-poi
  ];
  text = ''
    if [ -n "$(git status --porcelain)" ]; then
      echo "git-tidy: working tree is DIRTY — commit, stash or ignore first" >&2
      git status --short >&2
      exit 1
    fi

    git fetch --prune
    if ! def=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
      git remote set-head origin --auto >/dev/null
      def=$(git symbolic-ref --short refs/remotes/origin/HEAD)
    fi
    branch=''${def#origin/}

    git switch "$branch"
    if ! git merge --ff-only "$def"; then
      echo "git-tidy: $branch has DIVERGED from $def — not resetting it; resolve by hand" >&2
      exit 1
    fi

    gh-poi "$@"
    git worktree prune

    git branch -vv
    git worktree list
  '';
}
