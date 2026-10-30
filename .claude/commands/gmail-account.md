---
description: Add/authenticate/remove a Gmail MCP multi-account (self-hosted, local.gmailMcp)
argument-hint: "add|auth|remove <address>"
---

Use the **gmail-mcp-accounts** skill for: $ARGUMENTS

The skill owns the rules (where an address may live, the Internal-only OAuth client, never
printing a secret or token), the per-account procedure and the mandatory API verification;
`docs/gmail-mcp-multi-account-runbook.md` owns the full Console walkthrough and recovery steps.
With no verb, assume `add`. If it is unclear which plugin an address belongs in, ask.
