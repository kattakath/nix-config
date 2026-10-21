# FlakeHub input freshness — automated `flake.lock` bumps

This repo follows the FlakeHub ["keep your inputs fresh"][bp] best practice with
two cooperating pieces:

- **`.github/workflows/nix-ci.yml` — the `flake-checker` job.** Advisory (never
  fails a build): inspects the ROOT `nixpkgs` lock node only (never transitive
  inputs). Since 2026-09-21 that node is FlakeHub's `DeterminateSystems/nixpkgs-weekly`
  (a weekly snapshot of nixos-unstable), a tarball: the branch/owner checks no-op,
  but the **30-day staleness** check still fires on `lastModified` — so it remains
  the alarm if the weekly bump below stalls.
- **`.github/workflows/update-flake-lock.yml`.** Scheduled every Monday: runs
  `nix flake update` and opens a PR with the regenerated `flake.lock`. The
  automated counterpart to the manual `/update-input` command.

Dependabot (`.github/dependabot.yml`) keeps the **GitHub Actions** pins fresh but
has no Nix ecosystem, so it never touches flake inputs — that is what these two
cover.

[bp]: https://docs.determinate.systems/flakehub/best-practices/

## Shape vs. revisions — `nix flake lock`, not `nix flake update`

Two different edits regenerate `flake.lock`, and only one of them is a bump:

| Edit | Command | What moves |
|---|---|---|
| New/changed **`follows`** (the input diet — see [`map/entry-points.md`](map/entry-points.md) § `flake.lock`) | `nix flake lock` | Graph **shape** only. Nodes collapse or disappear; **no rev changes.** |
| Freshness | `nix flake update` (all) / `nix flake update <name>` (one) | **Revisions.** |

A bare `nix flake update` after a `follows` edit buries the shape change in 31 inputs' worth of
unrelated churn — always `nix flake lock` for the former.

**Do not review a shape change by eyeballing `git diff flake.lock`.** `nix flake lock`
*renumbers* nodes when duplicates collapse, so the diff shows what look like rev bumps that are
really renames (`home-manager_2` → `home-manager`, `flake-parts_5` → `flake-parts_3`). Compare
the **set of `(source-identity, rev)` pairs** instead — nothing may be ADDED:

```bash
git add -A                                    # flakes evaluate the git tree
git show HEAD:flake.lock > /tmp/lock.before   # or stash a copy before re-locking
python3 - <<'PY' > /tmp/A
import json
N = json.load(open('/tmp/lock.before'))['nodes']
for x in sorted({(l.get('type'), l.get('owner'), l.get('repo'), l.get('url'), l.get('ref'),
                  l.get('rev') or l.get('narHash'))
                 for n, v in N.items() if n != 'root' for l in [v['locked']]}, key=str):
    print(x)
PY
# …repeat against ./flake.lock into /tmp/B, then:
comm -13 /tmp/A /tmp/B   # ADDED — MUST be empty for a shape-only change
comm -23 /tmp/A /tmp/B   # DROPPED — the diet
```

Node count is the other measurable: `python3 -c "import json;print(len(json.load(open('flake.lock'))['nodes']))"`.

**Two checks are `self`-source-hashed, so their drvPath moves on *any* `flake.nix` byte** —
`checks.<sys>.formatting`, `checks.<sys>.pre-commit`, and `checks.<sys>.ast-grep` all take the
flake tree as `src`. A changed hash there is **not** evidence that a shape change altered
anything; the meaningful invariants are the host `toplevel`s and the devShell, which stay
byte-identical across a pure dedupe.

## Why a GitHub App instead of `GITHUB_TOKEN`

A PR opened by a workflow using the built-in `GITHUB_TOKEN` **cannot trigger
other workflows** — a GitHub safeguard against recursive CI. If the lockfile PR
were opened that way, `nix-ci` would not run on it, so you'd be merging new input
revisions with no cross-system evaluation behind them. That defeats the purpose.

A dedicated **GitHub App** sidesteps this: the workflow mints a **short-lived
installation token** at run time (via `actions/create-github-app-token`), and a
PR opened with that token triggers `nix-ci` normally. It also fits this repo's
posture — no long-lived *personal* credential is stored, mirroring the OIDC model
used for FlakeHub publishing. The only persisted material is the App's own
identity.

## Setup — already done, org-wide

There is nothing to register. The token comes from the ONE org-wide CI App,
`ismailkattakath-ci` (installed on the `kattakath` org with `repository_selection: all`),
via the org variable `CI_BOT_CLIENT_ID` and org secret `CI_BOT_APP_PRIVATE_KEY` — see
[`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md) §1 and `secrets/secrets.nix`.
**Do not register a second App or add a repo-level secret**: a repo-level value would
shadow the org one, and `auto-merge.yml` uses the same key.

## Verify

Trigger the workflow by hand once both values exist:

```bash
gh workflow run update-flake-lock.yml
gh run watch
```

A successful run either opens/updates a `chore: bump flake inputs` PR (if any
input moved) or no-ops (if everything was already current). Confirm the opened PR
**shows `nix-ci` running** on it — that is the whole point of the App token; if
CI is absent, re-check that both the checkout and the `update-flake-lock` steps
receive `token: ${{ steps.app-token.outputs.token }}`.

## Rotation / teardown

- **Rotate the key:** it is the shared org key — follow `secrets/secrets.nix`, never a
  repo-level replacement.
- **Disable the automation entirely:** remove the `schedule:` trigger from
  `update-flake-lock.yml` — NOT the App or the org variable, which `auto-merge.yml`
  and the other repos share. `flake-checker` and the manual `/update-input` path are
  unaffected.
