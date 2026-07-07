# PR Consolidation — One Open PR Per Working Session

Don't fragment a working session's output across multiple small PRs. When a PR is
already open for the current session's work, push follow-up commits onto that
same branch instead of branching off `main` again for the next change.

## Mandatory behavior

1. **Before opening a new PR**, check whether a PR from earlier in this session is
   still open (`gh pr list`, or recall the branch/PR you already created/pushed to).
2. **If an open PR from this session exists**, commit and push further changes to
   its branch (`git checkout <branch>`, commit, `git push`) rather than creating a
   new branch/PR — even for a change that touches unrelated files. Update the PR
   title/body to reflect the combined scope when the change set grows.
3. **Exception — the existing PR has already merged.** Once a session's PR lands
   on `main`, its branch is done. The next change starts a fresh branch and a new
   PR — do not try to reuse or reopen a merged branch.
4. **Exception — the user explicitly asks for a separate PR** (e.g. to keep an
   unrelated change reviewable on its own). Explicit instruction overrides the
   default.

## Quick check

```bash
gh pr list --author "@me" --state open   # any open PR from this session already?
git branch --show-current                 # confirm you're on that PR's branch before committing
```

If the only open PR is already merged (`gh pr view <n> --json state` shows
`MERGED`), start a new branch off latest `main` for the next change.
