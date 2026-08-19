# Gmail MCP — multi-account operator runbook

TRUE simultaneous multi-account Gmail for Claude Code — the built-in Gmail/Google
Workspace connector is single-account-per-connection by design (one OAuth grant,
no way to hold two accounts open at once). This runs
[ArtyMcLabin/Gmail-MCP-Server](https://github.com/ArtyMcLabin/Gmail-MCP-Server)
(a maintained fork of the now-archived GongRzhe original) as **one server
process per account**, each with its own `--tool-prefix`, side by side in the
local MCP gateway (`modules/shared/mcp.nix`).

## Pieces

| Piece | Role | Lives |
|---|---|---|
| Google Cloud OAuth client (**Desktop app** type) | ONE shared client (`client_id`/`client_secret`) authenticates every account — Google allows the same Desktop client across arbitrary accounts | Your Google Cloud Console; secret in the login Keychain |
| `gmailAlias` | Sanitizes an email (`lower`, `@`/`.`/`+` → `_`) into a tool-prefix/filename-safe token — internal only, never part of the config surface | `modules/shared/mcp.nix` |
| `mkGmailMcp` | `writeShellScriptBin` wrapper: reads the shared client id/secret from Keychain at launch, materializes `~/.gmail-mcp/gcp-oauth.keys.json`, execs the server with `--tool-prefix=<alias>_` | `modules/shared/mcp.nix` |
| `services.mcpGateway.gmail.accounts` | `listOf str` of **plain email addresses** — the only thing you edit to add/remove an account. Empty by default | `modules/shared/mcp.nix` option |
| `~/.gmail-mcp/credentials-<alias>.json` | Per-account OAuth token, produced by the **one-time interactive auth step** (not by Nix) | `$HOME`, never in git/store |

## Public/private split (same contract as nixpi's `hostedSites`)

Real email addresses are personal data — some may belong to people other than
the operator (family/associates whose inboxes they manage). `gmail.accounts`
is a plain Nix list, so:

- **Public** (`hosts/<host>.nix` in the public repo): only accounts the
  operator is comfortable naming publicly — typically identities already
  public elsewhere in the same tree (e.g. the repo's own `userEmail`/domain).
- **Private** (the operator's private composition flake, via
  `extraHomeModules` — see `docs/private-home-modules.md`): everything else.

`listOf`-typed options **merge** across defining modules — the private list
*adds to*, never replaces, the public one. Both sides evaluate independently;
`nix flake check` on the public repo never needs the private list to pass.

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
3. **Activate**: `darwin-rebuild switch` (public host) or your private
   flake's activation app (to pick up accounts from a private module too —
   `extraHomeModules` accounts only exist once activated from the flake that
   supplies them).
4. **Run the one-time interactive auth**, using the SAME shared
   `gcp-oauth.keys.json` (materialized once, on first gateway launch) and a
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

1. Remove the email from `services.mcpGateway.gmail.accounts` (whichever list
   it's in), evaluate, commit, push, activate.
2. `rm ~/.gmail-mcp/credentials-<alias>.json` — the gateway no longer
   references it, and the local token should not linger.
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
| `HTTP 403` on the profile check, `insufficientPermissions`-shaped error | Gmail API not enabled on the project, or the scope isn't registered on the consent screen | Setup steps 1 and 3 |
| Gateway server for one account exits immediately at launch | That account's `credentials-<alias>.json` doesn't exist yet (no completed auth) | Run the per-account auth procedure; it doesn't dark the whole gateway — every account is its own process |
| Verified `emailAddress` doesn't match the target | The silent wrong-account grab (see "Known issue") | Check the default-path file; mv or re-run per the mitigation steps |
| `nix eval`/`darwin-rebuild` doesn't see a newly-added account | New/edited `.nix` file not staged | `git add` it — flakes ignore untracked/unstaged-new files (see `.claude/rules/git-purity.md`) |
| Adding an account to a private composition flake has no effect on the public repo's `nix flake check` | Expected — `listOf` options merge only when BOTH modules are actually composed together (i.e. evaluated from the flake that supplies `extraHomeModules`) | Evaluate/activate from the flake that has both, not the public-only one |

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
| `modules/shared/mcp.nix` | `gmailAlias`, `mkGmailMcp`, `services.mcpGateway.gmail.accounts` option, gateway wiring |
| `hosts/<host>.nix` | Public accounts for that host, via `home-manager.users.<user>.services.mcpGateway.gmail.accounts` |
| private composition flake | Private accounts, via `extraHomeModules` (see `docs/private-home-modules.md`) |
| `~/.gmail-mcp/` | Runtime state: shared `gcp-oauth.keys.json` + per-account `credentials-<alias>.json` (never in git) |
