# MCP gateway — the fleet's server fleet, behind one connector

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Navigating the Codebase → `modules/shared/mcp.nix`.
`CLAUDE.md` keeps only the pointer; the inventory and the per-server gotchas live here.
**When you add or remove a server, update this file and `config.fleet.publicMcpServers`
(`modules/parts/identity.nix`) — and nothing in `CLAUDE.md` (it carries no count).** Count drift
across prose was a recurring bug, which is why the count lives in exactly one prose place and
the roster itself is now machine-checked (see § Parity).

## Shape

One `mcp-proxy` launchd agent (`modules/shared/mcp.nix`, **darwin-only**) bound to
**`127.0.0.1:<publicMcpPort>`**, started at login, hosting all **26** servers, each at
`/servers/<name>/mcp` (Streamable HTTP).

**Clients never address that port.** They dial one connector —
`https://mcp.kattakath.com/mcp`, the Cloudflare MCP portal — which authenticates against
Google Workspace and proxies back in through the tunnel. So every client config is a *single
entry* whose size does not change when the roster does, and every call carries an identity
instead of being trusted for running on this machine.

| | Before 2026-09-22 | Now |
|---|---|---|
| proxies | 2 (`:8096` private, `:8097` published) | **1** |
| what a client declares | 20+ loopback URLs | **1 portal URL** |
| published servers | 2 of 26 | **26 of 26** |
| per-client stdio servers | `desktop-commander`, `open-design` | **none** |
| processes | ~50 (two copies of each server) | **26** |

The second proxy existed because Cloudflare Access protects a *hostname*, not a path, so
tunnelling the private gateway would have exposed every server to a leaked service token. That
argument was load-bearing while 2 of 26 were published; publishing all of them killed it —
both processes then hosted the same set, so the split bounded nothing but a crash while costing
a duplicate instance of every server, two copies fighting over one Gmail credential file, one
MTProto session and one memory graph.

`desktop-commander` — an RCE surface kept off the gateway entirely until then — is now hosted
like everything else, by operator decision. `open-design` left the fleet in the same change;
the **app** is still installed as a cask, only its stdio MCP server is gone
([`open-design.md`](open-design.md)).

**What this accepts, stated plainly:** a leaked Access service token now reaches four Gmail
accounts, production WordPress, Postgres, the Cloudflare account, `macos-automator` (arbitrary
AppleScript on this Mac), `chrome-devtools` (live browser sessions) and `desktop-commander`
(shell). Identity-gated at the edge, not bounded by absence.

There is **no project `.mcp.json`** — the user-scope gateway is the single source (the Mac is
the sole MCP client host; the Pi/VM stay lean).

## Parity — the roster is checked, not remembered

`checks.<system>.mcp-published-parity` asserts `local.mcpGateway.hostedServers` equals
`config.fleet.publicMcpServers` in **both** directions, and fails the build otherwise:

- *hosted but NOT published* — the server exists and no client can ever see it.
- *published but NOT hosted* — terranix registers a dead upstream with Cloudflare.

This replaced the assertions that used to police `local.mcpGateway.public`. They could only
catch a published name that was not hosted; the parity check also catches the direction that
actually kept happening — a newly hosted server nobody remembered to publish.

## The 7 packaged servers (`mcp-servers-nix`)

`context7`, `fetch`, `memory`, `sequential-thinking`, `nixos`, `terraform`, `github` — pinned
via `mcp-servers-nix.lib.mkConfig`'s `programs` block. Credentials, where needed, are read from
the login Keychain at **gateway launch** by a `passwordCommand` wrapper, so no token is ever in
argv or the `/nix/store` (`context7` → `CONTEXT7_API_KEY`, `github` →
`GITHUB_PERSONAL_ACCESS_TOKEN`; an absent key means an empty export and the server degrades
rather than crashing).

## The 13 custom stdio launchers

| Server | Notes |
|---|---|
| `duckduckgo` | web search |
| `arxiv` | arXiv literature loop via `arxiv-mcp-server` (pinned, `--python 3.12`): search, abstracts, section-level LaTeX reads, BibTeX, Semantic Scholar citation graphs, topic watches. No credentials; papers + watches under `$XDG_DATA_HOME/arxiv-mcp-server/papers` |
| `json-yaml-toml` | structured-data convert/query/diff/merge/schema |
| `mcp-jq` | `jq` over files and payloads |
| `mcpfinder` | cross-registry MCP-server **DISCOVERY** (Official MCP Registry + Glama + Smithery, `@mcpfinder/server` pinned), wired **discovery-only**: `.claude/settings.json` pre-approves only its FOUR read-only tools by name (`browse_categories`, `get_install_config`, `get_server_details`, `search_mcp_servers`), so a config-writing tool added by a future version pin matches no allow rule and prompts. It had one, `add_mcp_server_config`; the pinned version no longer registers it, which is why the deny that named it was removed rather than re-spelled (2026-09-16). MCP adoption in this repo is always a pinned declaration in `mcp.nix` via the `mcp-scout` skill, never an imperative install |
| `cloudflare-docs` | Cloudflare documentation search |
| `cloudflare` | Cloudflare API; needs a one-time browser login and fails gracefully headless |
| `apify` | Apify Store's ready-made scraper/crawler Actors, run **LOCALLY** via `@apify/actors-mcp-server`, authenticated by an `APIFY_TOKEN` read from the Keychain at launch. Switched 2026-08-19 from the hosted `mcp.apify.com` OAuth bridge, which never completed its interactive login under the headless launchd gateway; a missing token warns but does not dark the gateway |
| `macos-automator` | AppleScript/JXA automation — needs a one-time macOS Accessibility (TCC) grant, see [`mcp-gateway-accessibility-tcc.md`](mcp-gateway-accessibility-tcc.md) |
| `mobile-mcp` | iOS/Android device + emulator driving |
| `postgres` | local Postgres (incl. the RAG store) |
| `wordpress` | docdyhr/mcp-wordpress (pinned) — **CLIENT-SIDE** WordPress admin over a live site's REST API with an Application Password (nothing installed on the site). Creds `WP_URL`/`WP_ADMIN_USER`/`WP_ADMIN_APP_PASSWORD` are Keychain-injected via the `wpMcp` wrapper; canonical **www** host required |
| `wordpress-adapter` | the official WordPress MCP Adapter (**server-side, SILVERCREEK.AI PROD**), reached via a Keychain-injecting `mcp-remote` wrapper against `https://www.silvercreek.ai`; always-on since prod is always reachable |

## Publishing — `config.fleet.publicMcpServers`

There is no `local.mcpGateway.public` option any more. The roster is a fleet constant in
`modules/parts/identity.nix`, and it drives three things from one list: the proxy's own server
set, the `cloudflared` connector agent (`nix-mcp-tunnel-connector`), and the Cloudflare
registrations.

Narrow it by deleting names there; the next apply DROPS their Cloudflare objects, which the
`mkMcpPublicTofu` drop-guard makes you confirm.

After any `activate` that restarts the gateway, run `nix run .#mcp-public-sync` to ask the
portal to re-poll — registrations otherwise keep the tool list they last saw.

The Cloudflare half lives in `infra/cloudflare/mcp-public.nix`; the full design, the two-hostname
model and the three-objects-per-publish trap are in
[`mcp-public-exposure-design.md`](mcp-public-exposure-design.md).

## Opt-ins (default off)

- **`telegram`** — chaindead/telegram-mcp. Needs a one-time phone auth **before** activating,
  or it darks the gateway. **Enabling it now also fails `nix flake check`**, deliberately: it
  was withdrawn from `publicMcpServers` on 2026-09-22 (it advertises `prompts`/`resources` then
  answers `-32000` on both, which darked portal discovery), so turning it on makes it hosted
  but unpublished — exactly what § Parity refuses. Before the collapse that combination was
  normal, because a private gateway could hold it; there is no private half now. Re-publish it
  only once the upstream bug is fixed.
- **`wordpress-adapter-local`** — mirrors `wordpress-adapter` against a LOCAL `wp-env` clone
  (`http://localhost:8888`). Gated behind `local.mcpGateway.localAdapter.enable` because
  `mcp-proxy` spawns every named server at startup and an unreachable endpoint would fail that
  server on boot; enable only while working against the local clone.
- **`gmail-<sanitized-email>`** — one per `local.mcpGateway.gmail.accounts` entry, a list of
  PLAIN EMAIL ADDRESSES (`hosts/macos.nix` sets the operator's own four:
  `ismail@kattakath.com`, `ismailkattakath@gmail.com`, `izzy@silvercreek.ai`,
  `aloshyakasoto@gmail.com`). ArtyMcLabin/Gmail-MCP-Server (maintained
  fork of the archived GongRzhe original) run as ONE process **PER** Google/Workspace account
  (each with its own `--tool-prefix`, sanitized from the email since MCP tool names can't
  contain `@`/`.`) for TRUE simultaneous multi-account Gmail, unlike the
  single-account-per-connection built-in connector. Uses a shared OAuth Desktop-app client from
  the Keychain plus a separate one-time browser auth per account (mirrors telegram's
  session-file pattern, not the OAuth-cache one). Anyone else's address never goes in this
  public list; the private nix-personal flake that used to add such accounts via
  `extraHomeModules` was fully retired 2026-09-15, and only the operator's own two of its
  seven accounts were carried over (see
  [`private-home-modules.md`](private-home-modules.md) § History). Runbook:
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
- [`mcp-public-exposure-design.md`](mcp-public-exposure-design.md) — the PUBLISHED gateway's
  design and the Cloudflare side. Read its §10 first: the two-proxy model the body describes
  was collapsed on 2026-09-22.
- [`private-home-modules.md`](private-home-modules.md) — the `extraHomeModules`/`hostedSites`
  composition seams, and the nixpi deploy runbook.
