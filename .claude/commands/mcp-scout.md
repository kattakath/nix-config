---
description: Discover, vet, and declaratively adopt an MCP server into the gateway
---

Use the **mcp-scout** skill for: $ARGUMENTS

Pipeline: discover (gateway `mcpfinder` tools / official registry REST API /
mcp-servers-nix modules) → vet (provenance, maintenance, license, secrets,
startup behavior) → declare in `modules/shared/mcp.nix` (pinned; Keychain
wrapper if secrets; opt-in gate if it exits without auth) → update the server
counts + `.claude/settings.json` permissions → `/eval` → PR.

**Never install imperatively** — no installer CLIs, no `claude mcp add`, no
mcpfinder `add_mcp_server_config` (deny-listed). Adoption is a Nix declaration.
