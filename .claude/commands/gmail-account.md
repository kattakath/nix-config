---
description: Add/authenticate/remove a Gmail MCP multi-account (self-hosted, gateway)
---

Use the **gmail-mcp-accounts** skill and `docs/gmail-mcp-multi-account-runbook.md`.

Default flow when the user is vague ("add a gmail account for X"):

1. Ask (or infer from context) whether the account is safe to name publicly
   (already public elsewhere in this tree) or belongs in the private
   composition flake — default to private unless obviously the operator's
   own already-public identity.
2. Add the email as a Console test user (Audience → Add users) — required
   before anything else works.
3. Add the email to the right `gmail.accounts` list, evaluate, commit, push.
   If the target file has unrelated uncommitted changes, use the
   base+`hash-object`+`update-index` isolation technique in the runbook —
   never `git add -A`.
4. Activate (`darwin-rebuild switch`, or the private flake's activation app
   if the account went into a private module).
5. Run the one-time interactive auth with `GMAIL_OAUTH_PATH`/
   `GMAIL_CREDENTIALS_PATH` set for that account's sanitized alias.
6. **Verify with a direct Gmail API call** — never trust the CLI's success
   message alone. If the returned email doesn't match, check
   `~/.gmail-mcp/credentials.json` (default path) before re-running — see
   the runbook's "Known issue" section.

Never print a client secret, access token, or refresh token in any form.
