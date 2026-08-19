---
name: gmail-mcp-accounts
description: >
  Add, remove, or authenticate accounts for the self-hosted multi-account
  Gmail MCP (services.mcpGateway.gmail.accounts, modules/shared/mcp.nix) —
  TRUE simultaneous multi-account Gmail via ArtyMcLabin/Gmail-MCP-Server, one
  process per account, unlike the built-in single-account connector. Use when
  asked to "add a gmail account", "authenticate gmail mcp", "gmail multi
  account setup", "rotate the gmail oauth client", or when a gmail-mcp
  account seems to be authenticated as the wrong person.
---

# Gmail MCP multi-account operator

Canonical docs: [`docs/gmail-mcp-multi-account-runbook.md`](../../../docs/gmail-mcp-multi-account-runbook.md).

## Rules

- **Never print a client secret, access token, or refresh token** — pipe
  values directly between Keychain/file/curl, report only success/failure.
- **Public vs private**: only add an email to a public `hosts/<host>.nix` if
  it's already public elsewhere in that same tree (the operator's own
  identity). Every other account — family/associates, anything the operator
  hasn't already named publicly — goes in the private composition flake via
  `extraHomeModules`, same contract as nixpi's `hostedSites`. If unsure, ask.
- **A Console test user MUST exist before auth is attempted** — Audience →
  Add users, or the flow rejects the account outright.
- **The OAuth client must be Desktop app type**, not Web application — Web
  clients don't support the loopback redirect this tool uses.
- **ALWAYS verify the result of a one-time auth run with a direct API call**
  (`curl` the Gmail profile endpoint with the saved access token) — the CLI's
  own "Authentication completed successfully" message is not sufficient
  evidence. There is a known failure mode (see below) where it silently
  authenticates the *wrong* account with no error and no visible prompt.
- When editing a Nix file that already has unrelated uncommitted changes
  (e.g. a private flake with other work in progress), never `git add -A` and
  never hand-edit `git add -p` hunks — use the base+edit+`hash-object`+
  `update-index` reconstruction in the runbook to isolate exactly your
  change in the index, leaving the rest of the working tree untouched.

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
# the full Console walkthrough (Desktop app type, External+Testing, enable
# Gmail API, register gmail.modify + gmail.settings.basic scopes).
secret set GMAIL_OAUTH_CLIENT_ID <client_id>
secret set GMAIL_OAUTH_CLIENT_SECRET <client_secret>

# Per-account: after adding as a Console test user AND to the right Nix list
# (public/private) AND activating —
GMAIL_OAUTH_PATH="$HOME/.gmail-mcp/gcp-oauth.keys.json" \
  GMAIL_CREDENTIALS_PATH="$HOME/.gmail-mcp/credentials-<alias>.json" \
  npx -y @artymclabin/gmail-mcp auth

# MANDATORY verification — never skip:
tok="$(jq -r '.tokens.access_token' "$HOME/.gmail-mcp/credentials-<alias>.json")"
curl -s -H "Authorization: Bearer $tok" \
  "https://gmail.googleapis.com/gmail/v1/users/me/profile"
unset tok
```

`<alias>` = the email, lowercased, with `@`/`.`/`+` replaced by `_` (matches
`gmailAlias` in `modules/shared/mcp.nix` — e.g. `a@b.com` → `a_b_com`).

## Failure modes

| Symptom | Action |
|---|---|
| `redirect_uri_mismatch` | Client is Web-app type — create a Desktop app client instead |
| Auth rejects the account | Add it as a Console test user first |
| Verified email doesn't match target | Known failure mode above — check the default-path file before re-running |
| Gateway entry for one account exits at launch | No completed auth for that account yet — doesn't affect other accounts, each is its own process |
| New account not visible after `darwin-rebuild`/activate | Nix file not staged (`git add`), or activated from a flake that doesn't compose the module the account was added to |

## Removing an account

Remove from `gmail.accounts` (whichever list), evaluate/commit/push/activate,
then `rm ~/.gmail-mcp/credentials-<alias>.json`. See runbook for full
rotation/revocation steps.
