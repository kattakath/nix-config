# Gmail MCP — multi-account operator runbook

TRUE simultaneous multi-account Gmail for Claude Code — the built-in Gmail/Google
Workspace connector is single-account-per-connection by design (one OAuth grant,
no way to hold two accounts open at once). This runs
[ArtyMcLabin/Gmail-MCP-Server](https://github.com/ArtyMcLabin/Gmail-MCP-Server)
(a maintained fork of the now-archived GongRzhe original) as **one server
process per account**, each with its own `--tool-prefix`.

**Where things live (since 2026-10-20).** Nix installs ONE generic launcher,
`nix-mcp-gmail <address>` (`local.gmailMcp.enable`, `modules/home/gmail-mcp.nix`). The
ACCOUNT lives in a plugin's `.mcp.json` as `{"command":"nix-mcp-gmail","args":["<address>"]}`:
the operator's own public address in `github:kattakath/skills`'s `gmail` plugin, every other
address in the PRIVATE overlay marketplace (`<your-handle>/skills`). Adding or removing an
account is a plugin `.mcp.json` edit, never a Nix edit. Claude Code spawns one stdio child per
account per session; Claude Desktop loads no plugins, so it has no Gmail.

**Why the launcher stays in Nix:** a plugin's `.mcp.json` can set `env` to literals and
passthroughs but **cannot run `security find-generic-password`**. The Keychain read, the
`gcp-oauth.keys.json` materialisation and the per-account `--tool-prefix` all happen in a
binary the plugin merely names.

## Pieces

| Piece | Role | Lives |
|---|---|---|
| Google Cloud OAuth client (**Desktop app** type) | ONE shared client (`client_id`/`client_secret`) authenticates every account — Google allows the same Desktop client across arbitrary accounts | Your Google Cloud Console; secret in the login Keychain |
| the alias | Sanitizes an email (`lower`, `@`/`.`/`+` → `_`) into a tool-prefix/filename-safe token — computed at runtime from argv, never part of the config surface | `packages/gmail-mcp.nix` (the launcher script) |
| the launcher (`nix-mcp-gmail <address>`) | `writeShellApplication` wrapper (shellchecked at build; `set -u` only, so a missing Keychain entry warns instead of aborting): reads the shared client id/secret from Keychain at launch, materializes `~/.gmail-mcp/gcp-oauth.keys.json`, execs the server with `--tool-prefix=<alias>_`. `npx` is baked as an absolute store path so the launcher is immune to whatever Node the calling session has on PATH — which matters, because the plugin lane gets fnm's Node, not the fleet default | `packages/gmail-mcp.nix` |
| `local.gmailMcp.enable` | installs the one launcher; holds **no** addresses | `modules/home/gmail-mcp.nix`; set in `hosts/macos.nix` |
| a plugin's `.mcp.json` | one server entry per account, `nix-mcp-gmail` + the address in `args` — the ONLY place the roster lives | the public `gmail` plugin or the private overlay (**not this repo**) |
| `~/.gmail-mcp/credentials-<alias>.json` | Per-account OAuth token, produced by the **one-time interactive auth step** (not by Nix) | `$HOME`, never in git/store |

## Which addresses belong where

Real email addresses are personal data, so **this repo holds none**. The public `gmail`
plugin in `github:kattakath/skills` carries only the operator's own already-public address;
every other mailbox goes in the private overlay marketplace
([`agent-resource-externalization.md`](agent-resource-externalization.md)). Anyone else's
address never goes in a public plugin.

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
     roster had no working credential** — exactly
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
   secret set GMAIL_OAUTH_CLIENT_ID      # no value argument: it prompts hidden
   secret set GMAIL_OAUTH_CLIENT_SECRET
   ```
   If you're driving this via an agent with browser access: prefer clicking
   "Download JSON" and piping the file straight into `security
   add-generic-password` / `secret set` over transcribing values from a
   screenshot or terminal output — then `shred -u` (or `rm -P`) the download.

## Per-account procedure (repeat for each new account)

1. **Add the email as a Console test user** (Audience → Add users) — do this
   *before* attempting auth, or it fails outright.
2. **Add a server entry for the email** to the right plugin's `.mcp.json` (the public `gmail`
   plugin only for an already-public address, otherwise the private overlay), as
   `{"command":"nix-mcp-gmail","args":["<address>"]}`. The server NAME becomes part of the
   tool prefix, so keep it stable once chosen.
3. **Pick it up** per [kattakath/skills `CLAUDE.md`](https://github.com/kattakath/skills/blob/main/CLAUDE.md)
   § Shipping a change (or wait for auto-update), then start a **fresh** session — a running session's tool namespace was fixed at start.
   `local.gmailMcp.enable = true` must already be activated so `nix-mcp-gmail` is on PATH.
4. **Run the one-time interactive auth**, using the SAME shared
   `gcp-oauth.keys.json` (rewritten from the Keychain on every launcher start) and a
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
   place means that account's server will run against the WRONG
   mailbox. Retry from step 4 rather than assuming a second attempt will
   land differently.
4. Never chain multiple accounts' auth runs unattended without checking each
   one — the failure mode is *silent* (`HTTP 200`, plausible-looking JSON),
   not a loud error.

## Removing or rotating an account

1. Remove the account's server entry from the plugin `.mcp.json` that holds it, and ship it
   the way step 3 of § Per-account procedure links.
2. `rm ~/.gmail-mcp/credentials-<alias>.json` — nothing references it any
   more, and the local token should not linger.
3. Optionally revoke the grant from the account's own Google Account →
   Security → Third-party access page (this is the account holder's own
   action, not something scriptable from here).
4. Remove the email from the Console's test-user list if it should no longer
   be able to authenticate at all (e.g. an account you no longer manage).
5. To rotate the **shared** OAuth client itself: repeat "One-time setup"
   steps 4–5 with a new client, `secret set` the new Keychain values (old
   ones are simply overwritten), then every account needs its one-time auth
   re-run against the new `gcp-oauth.keys.json` (the launcher rewrites it from the
   Keychain on every start, so start one session after `secret set` before re-running auth).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` at the consent screen | OAuth client is **Web application** type, not Desktop | Create a new **Desktop app** client (see setup step 4) |
| Auth flow rejects the account / "app not available to this user" | Email isn't in the Console's test-user list | Audience → Add users, then retry |
| `Access blocked: <org> can only be used within its organization` | The client is **Internal**, and the account is out-of-org. A test-user entry CANNOT fix this | Audience → **Make external** → Testing, then re-verify per setup step 2 |
| An account works for weeks, then `invalid_grant` on refresh | Testing-status **7-day refresh-token expiry** (setup step 2) — not corruption | Re-run that account's auth. A directory of dead credentials is this, not a bug |
| Account is declared in a plugin `.mcp.json` but was never usable | Declared roster ≠ credentials on disk; nothing reconciles them | Compare the plugin entries against `ls ~/.gmail-mcp/credentials-*.json` (names only — never print contents) |
| `HTTP 403` on the profile check, `insufficientPermissions`-shaped error | Gmail API not enabled on the project, or the scope isn't registered on the consent screen | Setup steps 1 and 3 |
| One account's server exits immediately at spawn | That account's `credentials-<alias>.json` doesn't exist yet (no completed auth) | Run the per-account auth procedure. It cannot take the others down — every account is its own process, and since 2026-10-01 its own per-session child, so there is no shared proxy left to dark |
| Verified `emailAddress` doesn't match the target | The silent wrong-account grab (see "Known issue") | Check the default-path file; mv or re-run per the mitigation steps |
| Launcher is on PATH, auth verified, but no `gmail` tools in the session | The plugin isn't enabled, its `.mcp.json` has no entry for this address, or the session predates the change | Enable the plugin; check its `.mcp.json`; start a **fresh** session — and prove it per `mcp-gateway.md` § How to verify a plugin-owned server actually answers. **No `nix flake check` leg can see any of this** |

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
| `packages/gmail-mcp.nix` | the generic launcher: alias derivation, Keychain read, `gcp-oauth.keys.json`, `--tool-prefix` |
| `modules/home/gmail-mcp.nix` | the `local.gmailMcp.enable` option; puts `nix-mcp-gmail` on PATH |
| `hosts/macos.nix` | `local.gmailMcp.enable = true` |
| a plugin `.mcp.json` (public `gmail`, or the private overlay) | the DECLARATION and the roster — one server entry per account. **Not in this repo**; the public plugin's `nix-mcp-gmail` is read by `checks.*.mcp-launcher-parity` (via the pin), the private overlay by no check here |
| ~~`modules/shared/mcp.nix`~~ | **deleted 2026-10-02** — held `mkGmailMcp` and the old gateway wiring |
| `~/.gmail-mcp/` | Runtime state: shared `gcp-oauth.keys.json` + per-account `credentials-<alias>.json` (never in git) |
