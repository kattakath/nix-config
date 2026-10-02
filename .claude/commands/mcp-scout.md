---
description: Discover, vet, and declaratively adopt an MCP server into its owning plugin
---

Use the **mcp-scout** skill for: $ARGUMENTS

Pipeline: discover (official registry REST API / `mcpfinder` if the session has it) → vet
(provenance, maintenance, license, secrets, startup behavior) → **spawn-test the exact spec
against the PATH runtime** → declare in the **owning plugin's `.mcp.json`** in
`github:kattakath/skills`, plus a nix-config PATH package if and only if it needs a login-Keychain
read → `.claude/settings.json` permissions → fresh session → **call one of its tools**.

**There is no gateway lane.** `modules/shared/mcp.nix`, `local.mcpGateway.*`,
`fleet.publicMcpServers` and the Cloudflare portal were all destroyed/deleted 2026-10-02. Nothing
in this repo can see a plugin's `.mcp.json`, so no `nix flake check` leg gates the result —
invoking a tool is the only proof. No server counts to update anywhere.

**Never install imperatively** — no installer CLIs, no `claude mcp add` (denied at user *and*
managed scope), no mcpfinder write tools — it ships none today, and only its four read-only tools
are pre-approved, so a new one prompts. Adoption is a declaration.
