# Gmail MCP — multi-account operator runbook

TRUE simultaneous multi-account Gmail for Claude Code — the built-in Gmail/Google
Workspace connector is single-account-per-connection by design (one OAuth grant,
no way to hold two accounts open at once). This runs
[ArtyMcLabin/Gmail-MCP-Server](https://github.com/ArtyMcLabin/Gmail-MCP-Server)
(a maintained fork of the now-archived GongRzhe original) as **one server
process per account**, each with its own `--tool-prefix`.

> **LANE CHANGE, 2026-10-01 — this runbook is LIVE, but the option name moved.** These four
> accounts used to be entries on the central MCP gateway (`local.gmailMcp.accounts` in
> `modules/shared/mcp.nix`). That gateway and its Cloudflare portal were destroyed on 2026-10-02
> and the module is **deleted**. Gmail was deliberately kept, so:
>
> | Then | Now |
> |---|---|
> | `local.gmailMcp.accounts` | **`local.gmailMcp.accounts`** (`modules/shared/gmail-mcp.nix`) |
> | `mkGmailMcp` inline in `mcp.nix` | **`packages/gmail-mcp.nix`** — one `nix-mcp-gmail-<alias>` launcher per account, on PATH |
> | one long-lived process per account under `mcp-proxy`, shared by every client | **one stdio child per account PER SESSION**, spawned by Claude Code from the `gmail` plugin's `.mcp.json` in `github:kattakath/skills`, reaped at session end |
> | reachable from Claude Code, Claude Desktop and Cowork | **Claude Code only** — Desktop loads no plugins, so it has no Gmail (and no MCP servers at all) |
>
> **Why the launcher stayed in Nix:** a plugin's `.mcp.json` can set `env` to literals and
> passthroughs but **cannot run `security find-generic-password`**. The Keychain read, the
> `gcp-oauth.keys.json` materialisation and the per-account `--tool-prefix` all have to happen in
> a binary the plugin merely names. That split is the pattern for any future credentialed server.
>
> **Everything about Google, OAuth, the test-user cap, the 7-day Testing expiry and the
> wrong-account grab is UNCHANGED** — it was never about the gateway. Substitute the new option
> name as you read, and note that the auth commands below are unaffected: they were always run by
> hand against `~/.gmail-mcp/`, never by Nix.

## Pieces

| Piece | Role | Lives |
|---|---|---|
| Google Cloud OAuth client (**Desktop app** type) | ONE shared client (`client_id`/`client_secret`) authenticates every account — Google allows the same Desktop client across arbitrary accounts | Your Google Cloud Console; secret in the login Keychain |
| `gmailAlias` | Sanitizes an email (`lower`, `@`/`.`/`+` → `_`) into a tool-prefix/filename-safe token — internal only, never part of the config surface | `packages/gmail-mcp.nix` (derived there, never passed in) |
| the launcher (`nix-mcp-gmail-<alias>`) | `writeShellScriptBin` wrapper: reads the shared client id/secret from Keychain at launch, materializes `~/.gmail-mcp/gcp-oauth.keys.json`, execs the server with `--tool-prefix=<alias>_`. `npx` is baked as an absolute store path so the launcher is immune to whatever Node the calling session has on PATH — which matters, because the plugin lane gets fnm's Node, not the fleet default | `packages/gmail-mcp.nix` (was `mkGmailMcp` in `mcp.nix`) |
| `local.gmailMcp.accounts` | `listOf str` of **plain email addresses** — the only thing you edit to add/remove an account. Empty by default | `modules/shared/gmail-mcp.nix` option; set in `hosts/macos.nix` |
| the `gmail` plugin's `.mcp.json` | names each launcher **by binary name**, one server entry per account — the declaration half | `github:kattakath/skills` (**not this repo**) |
| `~/.gmail-mcp/credentials-<alias>.json` | Per-account OAuth token, produced by the **one-time interactive auth step** (not by Nix) | `$HOME`, never in git/store |

## Which addresses belong in this list

Real email addresses are personal data. `gmailMcp.accounts` is a plain Nix list
set directly in `hosts/macos.nix`, and it holds **only the operator's own
accounts, each under an identity already public elsewhere in this tree**.
Anyone else's address never goes in it.

The private nix-personal flake used to add further accounts through
`extraHomeModules`; it was fully retired 2026-09-15 and only two of its seven
were carried over (#524) — the rest were intentionally dropped rather than
made public. That `extraHomeModules` seam still exists generically on
`lib.mkDarwin`, just unused today.

## One-time setup: the shared OAuth client (do this once per Google Cloud project)

1. **Google Cloud Console → APIs & Services → Library** → enable the **Gmail
   API** for your project.
2. **Google Auth Platform → Audience**:
   - If the project's user type is **Internal**, it can *only* authenticate
     accounts in that exact Workspace org — fine for a single-domain setup,
     but it structurally cannot authenticate accounts on other domains
     (`gmail.com`, a different Workspace, etc.). For a real multi-domain
     roster, click **Make external**, choose **Testing** (not "In
     production" — Testing skips Google's app-verification review, which
     Gmail's scopes would otherwise require).
   - **Add every account you intend to authenticate as a test user here**,
     under "Test users". Cap is 100 per app, for the app's lifetime. An
     account NOT listed here will be rejected at authorization regardless of
     anything else being correct.
   - **VERIFY the "Make external" step actually stuck — nothing else detects
     it.** Attempt an auth for an account OUTSIDE the client's own Workspace
     org; Google's consent screen must NOT say *"Access blocked: &lt;org&gt; can
     only be used within its organization"*. If it does, the app is still
     Internal and **no amount of test-user configuration will help** — an
     Internal app cannot authenticate an out-of-org account at all.
     Measured 2026-09-29: the shared client had drifted back to (or never
     left) Internal, and **3 of the 4 accounts declared in
     `local.gmailMcp.accounts` had no working credential** — exactly
     the three that live outside the client's org. Nothing warned; the
     declared roster and reality disagreed silently for weeks.

   > **Cost of "Testing" that decides your ops burden, not just your setup:**
   > Google expires **refresh tokens after 7 days** for an app whose user type
   > is External and whose publishing status is Testing — "unless the only
   > OAuth scopes requested are a subset of name, email address, and user
   > profile"
   > ([Google, *Refresh token expiration*](https://developers.google.com/identity/protocols/oauth2#expiration)).
   > Gmail's `gmail.modify`/`gmail.settings.basic` are restricted scopes, far
   > outside that subset, so **the expiry applies to every account here** and
   > each one needs periodic re-auth. That is the likeliest explanation for a
   > directory full of dead credentials (see § Troubleshooting).
   >
   > The alternative shape — one **Internal** client per Workspace org — has no
   > Testing expiry and is exempt from verification even for restricted scopes,
   > at the cost of one OAuth client per org. It is **not** adoptable as-is:
   > `packages/gmail-mcp.nix` assumes a single shared client (it reads one
   > `GMAIL_OAUTH_CLIENT_ID`/`_SECRET` pair from the Keychain), so this would need a per-account
   > client id. Recorded here as the trade-off, not as a supported option.
3. **Google Auth Platform → Data Access → Add or remove scopes**: register
   `.../auth/gmail.modify` and `.../auth/gmail.settings.basic` (the tool's
   default scope request) — they only appear in the picker *after* step 1
   enables the API. They'll show under "Restricted scopes" (Gmail scopes are
   classified restricted, not merely sensitive).
4. **Google Auth Platform → Clients → Create client**: type **Desktop app**
   (NOT "Web application" — a Web-app client's registered-redirect-URI model
   doesn't support the arbitrary-port `http://localhost` loopback this tool
   uses; both existing Web-app clients in a typical project are unusable
   here). Name it something recognizable.
5. **Download the JSON**, extract `client_id`/`client_secret`, store in the
   Keychain, then delete the downloaded file — **never** paste these into
   chat, a file that gets committed, or anywhere outside the Keychain:
   ```bash
   secret set GMAIL_OAUTH_CLIENT_ID <client_id>
   secret set GMAIL_OAUTH_CLIENT_SECRET <client_secret>
   ```
   If you're driving this via an agent with browser access: prefer clicking
   "Download JSON" and piping the file straight into `security
   add-generic-password` / `secret set` over transcribing values from a
   screenshot or terminal output — then `shred -u` (or `rm -P`) the download.

## Per-account procedure (repeat for each new account)

1. **Add the email as a Console test user** (Audience → Add users) — do this
   *before* attempting auth, or it fails outright.
2. **Add the email to the right Nix list** — public `hosts/<host>.nix` or the
   private flake's module, per the split above. Evaluate, commit, push.

   If the target file already has **unrelated uncommitted changes** you must
   not disturb (a common case in a private composition flake with other
   work-in-progress), don't `git add -A` and don't hand-edit hunks with
   `git add -p` line numbers — reconstruct precisely instead:
   ```bash
   git show HEAD:path/to/file.nix > /tmp/base.nix   # clean base, no local edits
   # apply ONLY your intended edit to /tmp/base.nix (Edit tool, or patch)
   blob=$(git hash-object -w /tmp/base.nix)
   git update-index --cacheinfo 100644,"$blob",path/to/file.nix
   git diff --cached -- path/to/file.nix   # sanity check: ONLY your hunk
   git diff -- path/to/file.nix            # sanity check: everything else, untouched
   ```
   This sets the **index** to base+your-edit without ever writing to the
   working-tree file — the other uncommitted work stays exactly as its owner
   left it, unstaged, on disk.
3. **Activate**: `activate` (or `darwin-rebuild switch`). This puts the new
   `nix-mcp-gmail-<alias>` launcher on PATH. **Two things to know since the lane change:**
   the `gmail` plugin's `.mcp.json` must also name that binary — a launcher on PATH that no
   plugin names is spawned by nobody — and a **already-running Claude Code session will not see
   it**, because its tool namespace was fixed at session start. Start a fresh session.
4. **Run the one-time interactive auth**, using the SAME shared
   `gcp-oauth.keys.json` (materialized once, on the launcher's first run) and a
   credentials path matching the email's sanitized alias:
   ```bash
   GMAIL_OAUTH_PATH="$HOME/.gmail-mcp/gcp-oauth.keys.json" \
     GMAIL_CREDENTIALS_PATH="$HOME/.gmail-mcp/credentials-<alias>.json" \
     npx -y @artymclabin/gmail-mcp auth
   ```
   This opens the system default browser for the OAuth consent flow.
5. **Verify — do not trust the CLI's "Authentication completed successfully"
   message.** See "Known issue" below for exactly why. Always confirm with a
   real, tool-independent API call:
   ```bash
   tok="$(jq -r '.tokens.access_token' "$HOME/.gmail-mcp/credentials-<alias>.json")"
   curl -s -H "Authorization: Bearer $tok" \
     "https://gmail.googleapis.com/gmail/v1/users/me/profile"
   unset tok
   ```
   Confirm the returned `emailAddress` matches the account you intended.
   Never print the access token itself — capture it in a shell variable,
   `unset` it immediately after use, and don't echo it.

## Known issue: silent wrong-account grab (verify, always)

Observed repeatedly: the tool calls the OS's `open()` on the OAuth URL — the
system default browser, not necessarily whatever browser you're driving via
automation. If that browser already has an active Google session for *some*
account, the flow can complete **near-instantly with zero visible interaction
and zero account picker**, silently using whichever account happens to be
active — not necessarily the one you intended. In practice this showed up as
an apparent one-account **lag**: requesting account N's credentials produced
account N−1's token (the previous run's identity), while the *actual* correct
token for N turned up under the tool's **default** credentials path
(`~/.gmail-mcp/credentials.json`, used when `GMAIL_CREDENTIALS_PATH` is
unset) on the *next* invocation.

**Mitigation — always, no exceptions:**
1. After every auth run, verify via the direct API call in step 5 above.
2. If the `emailAddress` doesn't match: check
   `~/.gmail-mcp/credentials.json` (the default path) — the correct token may
   have landed there under the generic filename. Verify it, then `mv` it to
   the correct `credentials-<alias>.json` rather than re-running auth (which
   just consumes another slot in whatever the underlying selection order is).
3. If genuinely wrong (not just misfiled) and no default-path candidate has
   the right identity: delete the wrong file immediately — leaving it in
   place means that account's gateway process will run against the WRONG
   mailbox. Retry from step 4 rather than assuming a second attempt will
   land differently.
4. Never chain multiple accounts' auth runs unattended without checking each
   one — the failure mode is *silent* (`HTTP 200`, plausible-looking JSON),
   not a loud error.

## Removing or rotating an account

1. Remove the email from `local.gmailMcp.accounts` (whichever list
   it's in), evaluate, commit, push, activate.
2. `rm ~/.gmail-mcp/credentials-<alias>.json` — nothing references it any
   more, and the local token should not linger. **Also remove the account's entry from the
   `gmail` plugin's `.mcp.json`**, or Claude Code keeps trying to spawn a launcher that no longer
   exists on PATH.
3. Optionally revoke the grant from the account's own Google Account →
   Security → Third-party access page (this is the account holder's own
   action, not something scriptable from here).
4. Remove the email from the Console's test-user list if it should no longer
   be able to authenticate at all (e.g. an account you no longer manage).
5. To rotate the **shared** OAuth client itself: repeat "One-time setup"
   steps 4–5 with a new client, `secret set` the new Keychain values (old
   ones are simply overwritten), then every account needs its one-time auth
   re-run against the new `gcp-oauth.keys.json` (delete the old file first so
   it's regenerated, not stale).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` at the consent screen | OAuth client is **Web application** type, not Desktop | Create a new **Desktop app** client (see setup step 4) |
| Auth flow rejects the account / "app not available to this user" | Email isn't in the Console's test-user list | Audience → Add users, then retry |
| `Access blocked: <org> can only be used within its organization` | The client is **Internal**, and the account is out-of-org. A test-user entry CANNOT fix this | Audience → **Make external** → Testing, then re-verify per setup step 2 |
| An account works for weeks, then `invalid_grant` on refresh | Testing-status **7-day refresh-token expiry** (setup step 2) — not corruption | Re-run that account's auth. A directory of dead credentials is this, not a bug |
| Account is declared in `local.gmailMcp.accounts` but was never usable | Declared roster ≠ credentials on disk; nothing reconciles them | Compare the list against `ls ~/.gmail-mcp/credentials-*.json` (names only — never print contents) |
| `HTTP 403` on the profile check, `insufficientPermissions`-shaped error | Gmail API not enabled on the project, or the scope isn't registered on the consent screen | Setup steps 1 and 3 |
| One account's server exits immediately at spawn | That account's `credentials-<alias>.json` doesn't exist yet (no completed auth) | Run the per-account auth procedure. It cannot take the others down — every account is its own process, and since 2026-10-01 its own per-session child, so there is no shared proxy left to dark |
| Verified `emailAddress` doesn't match the target | The silent wrong-account grab (see "Known issue") | Check the default-path file; mv or re-run per the mitigation steps |
| `nix eval`/`darwin-rebuild` doesn't see a newly-added account | New/edited `.nix` file not staged | `git add` it — flakes ignore untracked/unstaged-new files (see `.claude/rules/git-purity.md`) |
| Adding an account to a private composition flake has no effect on the public repo's `nix flake check` | Expected — `listOf` options merge only when BOTH modules are actually composed together (i.e. evaluated from the flake that supplies `extraHomeModules`) | Evaluate/activate from the flake that has both, not the public-only one |
| Launcher is on PATH, auth verified, but no `gmail` tools in the session | The `gmail` plugin isn't enabled, its `.mcp.json` doesn't name this alias, or the session predates the change | Enable the plugin; check its `.mcp.json`; start a **fresh** session — and prove it per `mcp-gateway.md` § How to verify a plugin-owned server actually answers. **No `nix flake check` leg can see any of this** |

## Security notes

- Client secret and every account's OAuth token are Keychain/`$HOME`-only —
  never in git, the Nix store, or command argv history beyond the single
  `security add-generic-password -w` call that stores them.
- `~/.gmail-mcp/*.json` files are `chmod 600`.
- **Testing** (not "In production") publishing status is the deliberate
  choice — it avoids Google's app-verification review (which Gmail's
  restricted scopes would otherwise require) while still working for any
  account you explicitly list as a test user, regardless of domain.
- If an agent is doing this setup on your behalf: it should never transcribe
  a client secret, access token, or refresh token into a chat message — pipe
  values directly between tools (Keychain ↔ file ↔ curl) and only ever report
  *whether* an operation succeeded, not the values involved.

## Agent skill

`.claude/skills/gmail-mcp-accounts/SKILL.md` — use when asked to add/remove a
Gmail account, run the one-time auth, or diagnose a Gmail MCP account issue.
Command: `/gmail-account`.

## Source

| Path | What |
|---|---|
| `packages/gmail-mcp.nix` | the per-account launcher: `gmailAlias` derivation, Keychain read, `gcp-oauth.keys.json`, `--tool-prefix` |
| `modules/shared/gmail-mcp.nix` | the `local.gmailMcp.accounts` option; puts one launcher per account on PATH |
| `hosts/macos.nix` | All accounts for that host, via `home-manager.users.<user>.local.gmailMcp.accounts` |
| `github:kattakath/skills` → the `gmail` plugin's `.mcp.json` | the DECLARATION — one server entry per account, naming the launcher by binary name. **Not in this repo, and invisible to every check here** |
| ~~`modules/shared/mcp.nix`~~ | **deleted 2026-10-02** — held `mkGmailMcp` and the old gateway wiring |
| `~/.gmail-mcp/` | Runtime state: shared `gcp-oauth.keys.json` + per-account `credentials-<alias>.json` (never in git) |
