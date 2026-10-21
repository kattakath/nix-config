---
description: Add/authenticate/remove a Gmail MCP multi-account (self-hosted, local.gmailMcp)
---

Use the **gmail-mcp-accounts** skill and `docs/gmail-mcp-multi-account-runbook.md`.

Default flow when the user is vague ("add a gmail account for X"):

1. Decide where the address goes: the operator's own already-public address
   goes in the public `gmail` plugin (`github:kattakath/skills`); every other
   address goes in the PRIVATE overlay marketplace's `gmail-private` plugin. No
   address is ever written into this repo. If unsure, ask.
2. Add the email as a Console test user (Audience → Add users) — required
   before anything else works.
3. Add a server to that plugin's `.mcp.json`:
   `{"command":"nix-mcp-gmail","args":["<address>"]}` (server name = a short
   stable label; it becomes the tool prefix's plugin half). Commit and push in
   THAT repo. `local.gmailMcp.enable = true` already installs the launcher.
4. Start a fresh Claude Code session (the marketplace auto-updates; a running
   session never sees a new server).
5. Run the one-time interactive auth with `GMAIL_OAUTH_PATH`/
   `GMAIL_CREDENTIALS_PATH` set for that account's sanitized alias.
6. **Verify with a direct Gmail API call** — never trust the CLI's success
   message alone. If the returned email doesn't match, check
   `~/.gmail-mcp/credentials.json` (default path) before re-running — see
   the runbook's "Known issue" section.

Never print a client secret, access token, or refresh token in any form.
