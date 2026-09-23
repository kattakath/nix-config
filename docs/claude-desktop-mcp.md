# Claude Desktop / Cowork — MCP parity with Claude Code (2026-09-15)

**Decision: Claude Desktop is "Client side D" of the MCP hub.** The same connector Claude
Code gets — the Cloudflare MCP portal in front of the gateway — is
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

Since 2026-09-22 this is **one** entry, not a per-server list: `programs.claude-code.mcpServers`
is empty (desktop-commander moved onto the proxy, open-design left the fleet), and the hub
carries a single portal URL.

```
programs.mcp.servers (hub)
  kattakath-portal (url = https://mcp.kattakath.com/mcp)
        │
        v  toStdioShim
  { command = <store>/npx;
    args = [ -y mcp-remote@<pin> <url> --transport http-only ];
    env  = { NIX_CONFIG_MANAGED = "claude-desktop"; } }
        │
        v  activation: jq merges ONLY .mcpServers, ONLY marked entries
  claude_desktop_config.json  (1 entry; foreign entries + other keys untouched)
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
| Cowork, Mac **not** linked (phone, closed laptop) | remote connector = the same portal (`config.fleet.publicMcpServers`, behind Cloudflare Access) | **yes** since 2026-09-22 — all 26 are published, so this row no longer differs from the one above |

Skills and plugins are **not** in scope here: in Desktop/Cowork they are account state
(Settings → Capabilities, the claude.ai plugin catalog), not files. The plan for those is
the capability-broker skill fed by a gateway-hosted `skills` server — same hub, one more
renderer — tracked separately.

## The clobber, and why activation alone was not enough (2026-09-15)

The first shipped version merged `mcpServers` only during activation. That is not enough,
and the failure is silent:

| Time | Event |
|---|---|
| 07:56:51 | activation merged `mcpServers`, printed *"restart Claude Desktop to load it"* |
| — | a second activation printed nothing: the merge was still intact, the merge is idempotent |
| **07:58:31** | **Desktop rewrote the file from its own in-memory state — the whole `mcpServers` key was gone** |

The ownership note below was right that Desktop *writes* this file. What it missed is the
cost: a **running** Desktop does not ignore an unknown key, it rewrites the file wholesale
from memory, so the merged key is **destroyed**, not merely unloaded. "Restart Desktop to
load it" was unreachable advice — by the time you restarted, there was nothing to load.

The fix is `launchd.agents.claude-desktop-mcp-sync`:

- **`WatchPaths = [ configFile ]`** — every Desktop write wakes the agent, which re-merges.
  This is home-manager's own option (`modules/launchd/launchd.nix:367`, used upstream by
  `modules/services/git-sync.nix:115`), not a watcher or poll loop of ours.
- **`RunAtLoad = true`** — repairs a file clobbered while logged out, before Desktop starts.
- **Writes only on difference.** The original activation `mv`d unconditionally, touching
  mtime even on a no-op; under a file watch that is a self-retriggering loop. The shared
  script compares the merged result with what is on disk and writes nothing when they match.
- **`ThrottleInterval = 10`** (launchd's own default, stated explicitly) damps a burst of
  Desktop writes.

Activation and the agent run the **same** script, so there is one implementation of the merge.

Ordering no longer matters: you can activate with Desktop open. It still needs a restart to
*load* new servers — but the config on disk now survives.

## The contract, checked

`checks.aarch64-darwin.claude-desktop-config-shape` reads the real macos rendering and
fails if any entry is not `{command, args}` + marker, if no rendered entry dials the
gateway's own `portalEndpoint` (two modules, one URL — the parity that is left once there is
one connector), or if `desktop-commander` sneaks in. It exists
because the failure mode is silent: a wrong-shaped entry does not error, it disappears from
the app.

## Knobs

| Option | Default | Why you'd touch it |
|---|---|---|
| `local.claudeDesktop.enable` | darwin && gateway on | off on a Mac without Desktop |
| `.mcpRemoteVersion` | pinned | deliberate bump, here, not `@latest` |
| `.excludeServers` | `[ "desktop-commander" ]` | another server later installed as a Desktop Extension |
| `.extraServers` | `{}` | a Desktop-only server (hub shape; `url` is shimmed) |
