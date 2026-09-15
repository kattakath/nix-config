# Claude Desktop / Cowork — MCP parity with Claude Code (2026-09-15)

**Decision: Claude Desktop is "Client side D" of the MCP hub.** The same servers Claude
Code gets — every localhost-gateway endpoint plus the per-client stdio servers — are
rendered into Desktop's `claude_desktop_config.json` by
[`modules/shared/claude-desktop.nix`](../modules/shared/claude-desktop.nix). Cowork gets
them for free through Desktop's device bridge.

This is the first piece of Desktop state nix-config manages;
[`claude-desktop-instructions.md`](claude-desktop-instructions.md) covers the piece it
still cannot (account-level instructions).

## Why Desktop needed its own renderer

| | Claude Code | Claude Desktop |
|---|---|---|
| Reads | `~/.claude/*`, managed `.mcp.json` (home-manager hub) | `~/Library/Application Support/Claude/claude_desktop_config.json` **only** |
| Transports | stdio, Streamable HTTP (`type = "http"`) | **stdio only** — `url`/`type` keys fail schema validation, entry vanishes |
| File ownership | Nix-managed | **Desktop-owned, stateful** (`coworkUserFilesPath`, `preferences`) |
| Upstream HM client | `programs.claude-code.enableMcpIntegration` | **none** (grepped pinned home-manager: no `claude-desktop` in modules/programs or modules/lib) |

So the renderer is custom, but it is built on the hub's own seam —
`lib.hm.mcp.transformMcpServer` with one `extraTransform` — exactly how the codex module
renders. Upstream growing a `programs.claude-desktop` client would retire the module and
move the shim transform with it.

## What gets written

```
programs.mcp.servers (hub)            programs.claude-code.mcpServers
  26 gateway endpoints (url)            desktop-commander  ── excluded (Desktop Extension already)
        │                               open-design        ── copied verbatim (already stdio)
        v  toStdioShim
  { command = <store>/npx;
    args = [ -y mcp-remote@<pin> <url> --transport http-only ];
    env  = { NIX_CONFIG_MANAGED = "claude-desktop"; } }
        │
        v  activation: jq merges ONLY .mcpServers, ONLY marked entries
  claude_desktop_config.json  (27 entries; foreign entries + other keys untouched)
        │
        v  Desktop device bridge
  Cowork cloud session: mcp__remote-devices__<name>__*
```

- **Shims, not servers.** The gateway still hosts one instance of each; Desktop launches
  one thin `mcp-remote` bridge per server. ~27 node processes at launch; first launch after
  a pin bump fetches `mcp-remote@<pin>` into `~/.npm/_npx` (a runtime fetch, the same trade
  the gateway's npx/uvx launchers already make).
- **The marker is an env var** (`NIX_CONFIG_MANAGED`) because it is the one extra field
  Desktop's stdio schema tolerates and every server ignores. It is how the merge tells
  *ours* (rewrite, prune when stale) from *theirs* (a server added in Desktop's UI — never
  touched).
- **Restart Desktop** after a switch that changed the set; the activation says so only
  when it actually changed something.

## What this gives Cowork — and what it does not

| Surface | Path | Includes telegram / gmail-* / wordpress? |
|---|---|---|
| Desktop app | this file | yes |
| Cowork, Mac linked | Desktop bridge → `mcp__remote-devices__<name>__*` | yes — without publishing them |
| Cowork, Mac **not** linked (phone, closed laptop) | remote connector = the **public** gateway (`local.mcpGateway.public`, :8097 behind Cloudflare Access) | no, by design — keep account-credential servers off the public list |

Skills and plugins are **not** in scope here: in Desktop/Cowork they are account state
(Settings → Capabilities, the claude.ai plugin catalog), not files. The plan for those is
the capability-broker skill fed by a gateway-hosted `skills` server — same hub, one more
renderer — tracked separately.

## The contract, checked

`checks.aarch64-darwin.claude-desktop-config-shape` reads the real macos rendering and
fails if any entry is not `{command, args}` + marker, if any gateway endpoint is missing
(parity is the point), or if `desktop-commander` sneaks in (20 duplicate tools). It exists
because the failure mode is silent: a wrong-shaped entry does not error, it disappears from
the app.

## Knobs

| Option | Default | Why you'd touch it |
|---|---|---|
| `local.claudeDesktop.enable` | darwin && gateway on | off on a Mac without Desktop |
| `.mcpRemoteVersion` | pinned | deliberate bump, here, not `@latest` |
| `.excludeServers` | `[ "desktop-commander" ]` | another server later installed as a Desktop Extension |
| `.extraServers` | `{}` | a Desktop-only server (hub shape; `url` is shimmed) |
