# MCP gateway — the localhost server fleet

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Navigating the Codebase → `modules/shared/mcp.nix`.
`CLAUDE.md` keeps only the pointer; the inventory and the per-server gotchas live here.
**When you add or remove a server, update this file, the server-count comments in
`modules/shared/mcp.nix`, and nothing in `CLAUDE.md` (it carries no count)** — count drift
across those comments is a recurring bug, which is why the count lives in exactly one prose
place now.

## Shape

MCP servers for Claude Code are provided by a localhost **gateway**
(`modules/shared/mcp.nix`, **darwin-only**): one `mcp-proxy` launchd agent on
**`127.0.0.1:8096`**, started at login, hosting all **19** servers (**20** with the opt-in
`telegram`). Each hosted server is wired into `programs.claude-code.mcpServers` as **HTTP**
(Streamable HTTP; a legacy `sse` path is also served for SSE-only clients such as Grok, via the
same `endpointFor` single source of truth).

`desktop-commander` stays a **per-client stdio** server, deliberately outside the gateway — it
is an RCE surface.

There is **no project `.mcp.json`** — the user-scope gateway is the single source (the Mac is
the sole MCP client host; the Pi/VM stay lean).

## The 7 packaged servers (`mcp-servers-nix`)

`context7`, `fetch`, `memory`, `sequential-thinking`, `nixos`, `terraform`, `github` — pinned
via `mcp-servers-nix.lib.mkConfig`'s `programs` block. Credentials, where needed, are read from
the login Keychain at **gateway launch** by a `passwordCommand` wrapper, so no token is ever in
argv or the `/nix/store` (`context7` → `CONTEXT7_API_KEY`, `github` →
`GITHUB_PERSONAL_ACCESS_TOKEN`; an absent key means an empty export and the server degrades
rather than crashing).

## The 12 custom stdio launchers

| Server | Notes |
|---|---|
| `duckduckgo` | web search |
| `json-yaml-toml` | structured-data convert/query/diff/merge/schema |
| `mcp-jq` | `jq` over files and payloads |
| `mcpfinder` | cross-registry MCP-server **DISCOVERY** (Official MCP Registry + Glama + Smithery, `@mcpfinder/server` pinned), wired **discovery-only**: its config-writing `add_mcp_server_config` tool is deny-listed in `.claude/settings.json`, since MCP adoption in this repo is always a pinned declaration in `mcp.nix` via the `mcp-scout` skill, never an imperative install |
| `cloudflare-docs` | Cloudflare documentation search |
| `cloudflare` | Cloudflare API; needs a one-time browser login and fails gracefully headless |
| `apify` | Apify Store's ready-made scraper/crawler Actors, run **LOCALLY** via `@apify/actors-mcp-server`, authenticated by an `APIFY_TOKEN` read from the Keychain at launch. Switched 2026-08-19 from the hosted `mcp.apify.com` OAuth bridge, which never completed its interactive login under the headless launchd gateway; a missing token warns but does not dark the gateway |
| `macos-automator` | AppleScript/JXA automation — needs a one-time macOS Accessibility (TCC) grant, see [`mcp-gateway-accessibility-tcc.md`](mcp-gateway-accessibility-tcc.md) |
| `mobile-mcp` | iOS/Android device + emulator driving |
| `postgres` | local Postgres (incl. the RAG store) |
| `wordpress` | docdyhr/mcp-wordpress (pinned) — **CLIENT-SIDE** WordPress admin over a live site's REST API with an Application Password (nothing installed on the site). Creds `WP_URL`/`WP_ADMIN_USER`/`WP_ADMIN_APP_PASSWORD` are Keychain-injected via the `wpMcp` wrapper; canonical **www** host required |
| `wordpress-adapter` | the official WordPress MCP Adapter (**server-side, SILVERCREEK.AI PROD**), reached via a Keychain-injecting `mcp-remote` wrapper against `https://www.silvercreek.ai`; always-on since prod is always reachable |

## Opt-ins (default off)

- **`telegram`** — chaindead/telegram-mcp. Needs a one-time phone auth **before** activating,
  or it darks the gateway.
- **`wordpress-adapter-local`** — mirrors `wordpress-adapter` against a LOCAL `wp-env` clone
  (`http://localhost:8888`). Gated behind `services.mcpGateway.localAdapter.enable` because
  `mcp-proxy` spawns every named server at startup and an unreachable endpoint would fail that
  server on boot; enable only while working against the local clone.
- **`gmail-<sanitized-email>`** — one per `services.mcpGateway.gmail.accounts` entry, a list of
  PLAIN EMAIL ADDRESSES (`hosts/macos.nix` sets the operator's own two:
  `ismail@kattakath.com`, `ismailkattakath@gmail.com`). ArtyMcLabin/Gmail-MCP-Server (maintained
  fork of the archived GongRzhe original) run as ONE process **PER** Google/Workspace account
  (each with its own `--tool-prefix`, sanitized from the email since MCP tool names can't
  contain `@`/`.`) for TRUE simultaneous multi-account Gmail, unlike the
  single-account-per-connection built-in connector. Uses a shared OAuth Desktop-app client from
  the Keychain plus a separate one-time browser auth per account (mirrors telegram's
  session-file pattern, not the OAuth-cache one). Any OTHER account (some belonging to people
  other than the operator) is supplied by the private nix-personal flake via
  `extraHomeModules` instead, same contract as nixpi's `hostedSites` (see
  [`private-home-modules.md`](private-home-modules.md)). Runbook:
  [`gmail-mcp-multi-account-runbook.md`](gmail-mcp-multi-account-runbook.md).

## Auth caches

OAuth tokens cache per-machine in `~/.mcp-auth`. `cloudflare` needs a one-time browser login
and fails gracefully headless; `apify` instead reads `APIFY_TOKEN` from the Keychain at launch
(no OAuth) and likewise warns without darkening the gateway if the token is missing.

## Adding a server

Always via the `mcp-scout` skill / `/mcp-scout` command: discover → vet → **declare** in
`mcp.nix` (pinned), add `.claude/settings.json` permission rules (allow read-only tools, deny
anything that writes outside its remit), and give any wrapper a `nix-*` `arg0` basename per
[`launchd-naming.md`](../.claude/rules/launchd-naming.md). Imperative installer CLIs and
config-writing install tools are never used.

## Related

- [`mcp-gateway-accessibility-tcc.md`](mcp-gateway-accessibility-tcc.md) — the one-time
  Accessibility (TCC) grant `macos-automator` needs.
- [`gmail-mcp-multi-account-runbook.md`](gmail-mcp-multi-account-runbook.md) — multi-account
  Gmail setup, auth, and a documented silent-wrong-account failure mode.
- [`private-home-modules.md`](private-home-modules.md) — how private accounts/sites plug in.
