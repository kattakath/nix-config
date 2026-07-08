# FlakeHub input freshness — automated `flake.lock` bumps

This repo follows the FlakeHub ["keep your inputs fresh"][bp] best practice with
two cooperating pieces:

- **`.github/workflows/nix-ci.yml` — the `flake-checker` job.** Advisory (never
  fails a build): warns on every PR/push when the `nixos-unstable` input in
  `flake.lock` drifts stale or off a supported branch.
- **`.github/workflows/update-flake-lock.yml`.** Scheduled every Monday: runs
  `nix flake update` and opens a PR with the regenerated `flake.lock`. The
  automated counterpart to the manual `/update-input` command.

Dependabot (`.github/dependabot.yml`) keeps the **GitHub Actions** pins fresh but
has no Nix ecosystem, so it never touches flake inputs — that is what these two
cover.

[bp]: https://docs.determinate.systems/flakehub/best-practices/

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
identity, scoped to this single repo.

## One-time setup (owner, browser)

This is done **once**. Until it is complete, the token step in
`update-flake-lock.yml` fails fast with a clear "input required" error and no PR
is cut — the scheduled run simply no-ops, so leaving it unconfigured is safe.

1. **Register the App.** Go to <https://github.com/settings/apps> → **New GitHub
   App**.
   - Name it anything (e.g. `nix-config-lockfile-bot`).
   - **Repository permissions:** `Contents` → *Read and write*, `Pull requests`
     → *Read and write*. Leave everything else *No access*.
   - Uncheck **Active** under *Webhook* (no webhook needed).
   - Create the App, then note its numeric **App ID**.
2. **Generate the App's private signing key** (the "Generate a private key"
   button on the App's page). A `.pem` downloads — this is the only copy, so
   handle it like any credential and delete the local file once step 4 is done.
3. **Install the App** on `ismailkattakath/nix-config`: the App's *Install App*
   tab → install on **Only select repositories** → this repo.
4. **Wire the two values into the repo's Actions settings** — repo **Settings →
   Secrets and variables → Actions**:

   | Kind         | Name                 | Value                                    |
   | ------------ | -------------------- | ---------------------------------------- |
   | **Variable** | `CI_BOT_APP_ID`  | the numeric App ID from step 1           |
   | **Secret**   | `CI_BOT_APP_PRIVATE_KEY` | the full contents of the `.pem` from step 2 |

   The App ID is not sensitive, so it is a **Variable**; the signing key is, so it
   is a **Secret** — injected into the workflow only via `${{ secrets.* }}` at run
   time, never committed to git or the Nix store.

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

- **Rotate the key:** generate a new private key on the App, replace the
  `CI_BOT_APP_PRIVATE_KEY` secret, delete the old key from the App. No workflow edit
  needed.
- **Disable the automation entirely:** uninstall the App from the repo (or delete
  the `CI_BOT_APP_ID` variable). The scheduled run then no-ops on the
  fail-fast token step; `flake-checker` and the manual `/update-input` path are
  unaffected.
