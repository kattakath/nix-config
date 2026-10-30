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
| Google Cloud OAuth client (**Desktop app** type) | ONE shared client (`client_id`/`client_secret`) authenticates every account — all of them in the operator's Workspace org, because the client is Internal (setup step 2); the google-tasks MCP shares it | Your Google Cloud Console; secret in the login Keychain |
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
2. **Google Auth Platform → Audience: the user type is Internal, and it stays
   Internal.** **Never click "Make external".** The one Desktop client serves
   both the gmail and google-tasks MCPs, and the same project holds the
   Cloudflare One client, so flipping the audience changes that too (operator
   decision, 2026-10-26).
   - Consequence: **only accounts in the operator's Workspace org are
     supported.** An out-of-org account (`gmail.com`, another Workspace) gets
     *"Access blocked: &lt;org&gt; can only be used within its organization"*,
     and nothing on this client fixes it — do not declare such an account.
     Measured 2026-09-29: **3 of the 4 declared accounts had no working
     credential** — exactly the three outside the client's org. Nothing
     warned; the declared roster and reality disagreed silently for weeks.
   - An Internal app needs no test-user list, is exempt from Google's
     app-verification review even for restricted scopes, and is exempt from
     the 7-day refresh-token expiry that applies only to External apps in
     Testing status
     ([Google, *Refresh token expiration*](https://developers.google.com/identity/protocols/oauth2#expiration)).
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

1. **Confirm the address is in the operator's Workspace org** — the client is
   Internal (setup step 2), so any other address cannot authenticate.
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
4. To rotate the **shared** OAuth client itself: repeat "One-time setup"
   steps 4–5 with a new client, `secret set` the new Keychain values (old
   ones are simply overwritten), then every account needs its one-time auth
   re-run against the new `gcp-oauth.keys.json` (the launcher rewrites it from the
   Keychain on every start, so start one session after `secret set` before re-running auth).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` at the consent screen | OAuth client is **Web application** type, not Desktop | Create a new **Desktop app** client (see setup step 4) |
| `Access blocked: <org> can only be used within its organization` | The account is outside the operator's Workspace org; the client is **Internal** by design (setup step 2) | Unsupported — remove the account from the plugin roster. **Never** flip the audience to External |
| An account works for weeks, then `invalid_grant` on refresh | Not the Testing 7-day expiry (an Internal client is exempt) — the grant was revoked or otherwise invalidated (Google, *Refresh token expiration*, lists the causes) | Re-run that account's auth |
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
- The **Internal** audience is the deliberate choice: no app-verification
  review for Gmail's restricted scopes, no refresh-token expiry, and no
  out-of-org account can ever be granted. Never make it External.
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
