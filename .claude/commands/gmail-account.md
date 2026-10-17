---
description: Add/authenticate/remove a Gmail MCP multi-account (self-hosted, local.gmailMcp)
---

Use the **gmail-mcp-accounts** skill and `docs/gmail-mcp-multi-account-runbook.md`.

Default flow when the user is vague ("add a gmail account for X"):

1. Check the address may be listed at all: only an identity the operator has
   already named publicly in this tree goes into `hosts/<host>.nix`. There is no
   private flake any more (nix-personal was retired 2026-09-15) — if unsure, ask.
2. Add the email as a Console test user (Audience → Add users) — required
   before anything else works.
3. Add the email to `local.gmailMcp.accounts` in `hosts/<host>.nix`, evaluate,
   commit, push. If the target file has unrelated uncommitted changes, use the
   base+`hash-object`+`update-index` isolation technique in the runbook —
   never `git add -A`.
4. Activate (`activate`).
5. Run the one-time interactive auth with `GMAIL_OAUTH_PATH`/
   `GMAIL_CREDENTIALS_PATH` set for that account's sanitized alias.
6. **Verify with a direct Gmail API call** — never trust the CLI's success
   message alone. If the returned email doesn't match, check
   `~/.gmail-mcp/credentials.json` (default path) before re-running — see
   the runbook's "Known issue" section.

Never print a client secret, access token, or refresh token in any form.
