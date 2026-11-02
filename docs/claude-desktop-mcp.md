# Claude Desktop / Cowork — MCP (2026-09-15, rewritten 2026-10-02)

> # ⚠ CURRENT STATE (2026-11-02): RETIRED. This repo writes NOTHING into Claude Desktop.
>
> Operator decision D4 (2026-11-02) retired `modules/home/claude-desktop.nix`, its
> `nix-claude-desktop-mcp-sync` watch agent and `checks.aarch64-darwin.claude-desktop-config-shape`.
> Desktop chat runs no plugin stdio server (claude.com/docs/plugins/platform-support; its Code tab
> DOES load plugins, like the CLI), the public render had been empty since 2026-11-01, and no
> private overlay was placed — so Desktop chat's MCP now comes **only from claude.ai connectors**.
> Desktop Commander reaches Desktop separately, as a Desktop Extension.
>
> The retirement accepts the risk the old module's header warned about: with no writer, whatever
> sits in `claude_desktop_config.json`'s `mcpServers` stays as it is. At retirement the Nix
> render was empty, so no `NIX_CONFIG_MANAGED` entry should remain; if one does, delete it by hand.
> After the first `activate` without the module, `launchd-doctor` must not list
> `nix-claude-desktop-mcp-sync` as ORPHANED.
>
> **Everything below is the design record** of the merge and the watch agent, kept for the day a
> writer is needed again (`git log --diff-filter=D -- modules/home/claude-desktop.nix` names the
> retiring commit; `git show <sha>^:modules/home/claude-desktop.nix` restores it).

**The original decision (superseded as to its subject, not its mechanism): Claude Desktop is
"Client side D" of the MCP hub.** The same connector Claude Code got — the Cloudflare MCP portal
in front of the gateway — was rendered into Desktop's `claude_desktop_config.json` by
`modules/home/claude-desktop.nix` (retired 2026-11-02). Cowork got
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

**From 2026-10-02: an empty `mcpServers` object, until `local.claudeDesktop.extraServers` came back
— today nothing from Nix, and no overlay is placed.** The flow below is the shape the
renderer HAD until 2026-11-02, when the `toStdioShim` url branch and `mcpRemoteVersion` were
removed as dead. Read it as history: today only a stdio entry is rendered, with the marker.

From 2026-09-22 to 2026-10-02 it was **one** entry, not a per-server list:
`programs.claude-code.mcpServers` was empty (desktop-commander moved onto the proxy, open-design
left the fleet), and the hub carried a single portal URL.

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

- **Shims, not servers.** The gateway hosted one instance of each; Desktop launched
  one thin `mcp-remote` bridge per server. ~27 node processes at launch; first launch after
  a pin bump fetched `mcp-remote@<pin>` into `~/.npm/_npx` (a runtime fetch, the same trade
  the gateway's npx/uvx launchers made). **The shim is gone** (2026-11-02): Nix renders no
  server, and a `url` overlay entry is skipped, not bridged.
- **The marker is an env var** (`NIX_CONFIG_MANAGED`) because it is the one extra field
  Desktop's stdio schema tolerates and every server ignores. It is how the merge tells
  *ours* (rewrite, prune when stale) from *theirs* (a server added in Desktop's UI — never
  touched).
- **Restart Desktop** after a switch that changed the set; the activation says so only
  when it actually changed something.

## What this gives Cowork — and what it does not

**Current answer: none of these rows is served from this repo any more** (what Desktop does have is
in the CURRENT STATE header). The table below is the 2026-09-22 state, kept because it
is the clearest statement of what was given up on 2026-10-02 — all three rows are now **no**.

| Surface | Path | Includes telegram / gmail-* / wordpress? |
|---|---|---|
| Desktop app | this file | ~~yes~~ → **no** (not rendered) |
| Cowork, Mac linked | Desktop bridge → `mcp__remote-devices__<name>__*` | ~~yes — without publishing them~~ → **no** (nothing to bridge) |
| Cowork, Mac **not** linked (phone, closed laptop) | remote connector = the same portal (`config.fleet.publicMcpServers`, behind Cloudflare Access) | ~~yes since 2026-09-22~~ → **no** — the portal is destroyed and `publicMcpServers` deleted |

Gmail reaches every surface through the claude.ai Gmail connector (account state, not this repo);
the self-hosted `local.gmailMcp` lane was retired 2026-11-01.

Skills and plugins are **not** in scope here: in Desktop/Cowork they are account state
(Settings → Capabilities, the claude.ai plugin catalog), not files. The gateway-hosted `skills`
server once planned for them died with the gateway; nothing replaces it here.

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

- **`WatchPaths = [ configFile overlayFile ]`** — every Desktop write wakes the agent, which
  re-merges; so does an overlay edit, which therefore lands without a rebuild.
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

`checks.aarch64-darwin.claude-desktop-config-shape` reads the real macos rendering. **Inverted
2026-10-02**: it used to fail if no rendered entry dialled the gateway's own `portalEndpoint` (two
modules, one URL); it now asserts the render contract its own legs state (`modules/parts/checks.nix`,
including never `desktop-commander`), paired with a leg asserting
`claudeDesktop.enable` is still **true**. Both legs are needed, and a deleted check would have
caught neither direction — an empty set from a disabled module is a different claim from an empty
set from an enabled one, and the disabled case leaves stale content on disk (#732). The shape rules
still apply to anything `extraServers` adds: `{command, args}` + marker, and no
`desktop-commander`. It all exists because the failure mode is silent — a wrong-shaped entry does
not error, it disappears from the app.

## Knobs

| Option | Default | Why you'd touch it |
|---|---|---|
| `local.claudeDesktop.enable` | darwin (**no longer gated on a gateway** — there isn't one) | off on a Mac without Desktop. **Not** the way to express "no servers": see the header |
| `.extraServers` | `{}` | a Desktop-only stdio server (`{command, args, env}`; a `url` entry fails eval) |
