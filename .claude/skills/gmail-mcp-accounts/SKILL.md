---
name: gmail-mcp-accounts
description: >
  Add, remove, or authenticate accounts for the self-hosted multi-account
  Gmail MCP (local.gmailMcp.enable, modules/home/gmail-mcp.nix, the generic
  `nix-mcp-gmail <address>` launcher from packages/gmail-mcp.nix, accounts
  declared in the `gmail` / private `gmail-private` / `gmail-persona` plugins'
  .mcp.json) —
  TRUE simultaneous multi-account Gmail via ArtyMcLabin/Gmail-MCP-Server, one
  process per account, unlike the built-in single-account connector. Use when
  asked to "add a gmail account", "authenticate gmail mcp", "gmail multi
  account setup", "rotate the gmail oauth client", or when a gmail-mcp
  account seems to be authenticated as the wrong person.
---

# Gmail MCP multi-account operator

Canonical docs: [`docs/gmail-mcp-multi-account-runbook.md`](../../../docs/gmail-mcp-multi-account-runbook.md).

**Where things live.** Nix installs ONE generic launcher, `nix-mcp-gmail <address>`
(`local.gmailMcp.enable`). The ACCOUNT lives only in a plugin's `.mcp.json` as
`{"command":"nix-mcp-gmail","args":["<address>"]}` — the operator's own public address in
`github:kattakath/skills`'s `gmail` plugin, every other address in the PRIVATE overlay
marketplace (`<your-handle>/skills`). Adding or removing an account is a plugin edit, never a
Nix edit. Claude Code spawns one stdio child per account per session; **an already-running
session never sees a new account**, so start a fresh one. Claude Desktop loads no plugins.

## Rules

- **Never print a client secret, access token, or refresh token** — pipe
  values directly between Keychain/file/curl, report only success/failure.
- **Which addresses go where**: this repo holds NONE. Only the operator's own
  already-public address may sit in the public `gmail` plugin; every other mailbox
  goes in the private overlay. Anyone else's address never goes in a public plugin.
  If unsure, ask — do not add.
- **The OAuth client is INTERNAL, and stays Internal — never flip its audience
  to External.** The one Desktop client serves both the gmail and google-tasks
  MCPs, and its project also holds the Cloudflare One client, so changing the
  audience changes that too (operator decision, 2026-10-26). Consequence:
  **only accounts in the operator's Workspace org are supported.** An
  out-of-org account is hard-blocked ("can only be used within its
  organization") and nothing on this client can fix that — do not declare it.
  Measured 2026-09-29: 3 of 4 declared accounts had never had a working
  credential for exactly this reason.
- Internal apps are exempt from the Testing-status 7-day refresh-token expiry,
  so an in-org account going `invalid_grant` is NOT routine — re-auth it and
  check whether the grant was revoked.
- **The OAuth client must be Desktop app type**, not Web application — Web
  clients don't support the loopback redirect this tool uses.
- **ALWAYS verify the result of a one-time auth run with a direct API call**
  (`curl` the Gmail profile endpoint with the saved access token) — the CLI's
  own "Authentication completed successfully" message is not sufficient
  evidence. There is a known failure mode (see below) where it silently
  authenticates the *wrong* account with no error and no visible prompt.

## Known failure mode (read before running auth on more than one account)

The tool opens the OS default browser. If that browser already has an active
Google session, the flow can complete instantly with **no account picker and
no visible interaction**, silently using whatever account is active — not
necessarily the target. Observed pattern: requesting account N produces
account N−1's token, and N's real token shows up under the tool's *default*
credentials path (`~/.gmail-mcp/credentials.json`, when
`GMAIL_CREDENTIALS_PATH` was omitted) on the *next* run. Check that file
before assuming a failure — the token may just be misfiled, fixable with a
`mv`, not a full re-auth. Full details and recovery steps: runbook § "Known
issue".

## Commands

```bash
# One-time OAuth client setup (per Google Cloud project) — see runbook for
# the full Console walkthrough (Desktop app type, Internal audience, enable
# Gmail API, register gmail.modify + gmail.settings.basic scopes).
secret set GMAIL_OAUTH_CLIENT_ID <client_id>
secret set GMAIL_OAUTH_CLIENT_SECRET <client_secret>

# Per-account (in-org addresses only): after adding a server entry in the
# right plugin's .mcp.json (public `gmail` or the private overlay) —
GMAIL_OAUTH_PATH="$HOME/.gmail-mcp/gcp-oauth.keys.json" \
  GMAIL_CREDENTIALS_PATH="$HOME/.gmail-mcp/credentials-<alias>.json" \
  npx -y @artymclabin/gmail-mcp auth

# MANDATORY verification — never skip:
tok="$(jq -r '.tokens.access_token' "$HOME/.gmail-mcp/credentials-<alias>.json")"
curl -s -H "Authorization: Bearer $tok" \
  "https://gmail.googleapis.com/gmail/v1/users/me/profile"
unset tok
```

`<alias>` = the email, lowercased, with `@`/`.`/`+` replaced by `_` (e.g. `a@b.com` →
`a_b_com`), computed at runtime from argv by `nix-mcp-gmail` (`packages/gmail-mcp.nix`); it
names the per-account credentials file and the `--tool-prefix`.

## Failure modes

| Symptom | Action |
|---|---|
| `redirect_uri_mismatch` | Client is Web-app type — create a Desktop app client instead |
| "can only be used within its organization" | The account is outside the operator's Workspace org — unsupported. Remove it from the plugin roster. **Never** flip the client's audience to External |
| Worked before, now `invalid_grant` | Not the Testing 7-day expiry (an Internal client is exempt) — the grant was revoked or otherwise invalidated (Google, *Refresh token expiration*, lists the causes); re-auth that account |
| Declared in a plugin `.mcp.json` but never worked | Roster ≠ credentials on disk; nothing reconciles them. Compare against `ls ~/.gmail-mcp/credentials-*.json` (names only) |
| Verified email doesn't match target | Known failure mode above — check the default-path file before re-running |
| One account's server exits immediately at spawn | No completed auth for that account yet — cannot affect the others, each is its own process and (since 2026-10-01) its own per-session child, so there is no shared proxy left to dark |
| New account not visible | Check in this order: `local.gmailMcp.enable` not activated (no `nix-mcp-gmail` on PATH); the plugin's `.mcp.json` has no entry for the address, or its marketplace wasn't updated; or the session **predates** the change — start a fresh one. **No `nix flake check` leg can see any of this** |
| Launcher is on PATH and auth verified, but still no tools | The plugin isn't enabled, or you are in a stale session. Prove it with `claude mcp list` in a fresh process, then invoke a tool with the plugin-lane `--allowedTools` spelling (see `docs/mcp-gateway.md` § How to verify a plugin-owned server actually answers) |

## Removing an account

Remove its server from the owning plugin's `.mcp.json` (public `gmail` or the private
overlay), commit and push in that repo, then
`rm ~/.gmail-mcp/credentials-<alias>.json`. No Nix change. See runbook for full
rotation/revocation steps.
