# MCP gateway — the fleet's UNOWNED servers, behind one connector

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Navigating the Codebase → `modules/shared/mcp.nix`.
`CLAUDE.md` keeps only the pointer; the inventory and the per-server gotchas live here.
**When you add or remove a server, update this file and `config.fleet.publicMcpServers`
(`modules/parts/identity.nix`) — and nothing in `CLAUDE.md` (it carries no count).** Count drift
across prose was a recurring bug, which is why the count lives in exactly one prose place and
the roster itself is now machine-checked (see § Parity).

> **The gateway does NOT retire; it NARROWS — decided 2026-09-30 (#658, #657).** There are two
> permanent MCP lanes now, split by **ownership**: a server that is the tool half of a skill this
> fleet already ships moves into that skill's marketplace plugin; **every server with no plugin
> owner stays here, on the fleet gateway, permanently** (#658). That is a decision, not a
> concession — see § Which lane for the rule and for the three groups that structurally cannot
> move. The cost the operator accepted is stated in § Counting convention and in
> `modules/shared/claude-desktop.nix`'s header: a plugin-owned server is **Claude-Code-only**,
> silently absent from Claude Desktop and the Cowork bridge.

## Counting convention — CAPABILITIES vs ROSTER ENTRIES

Settle this before reading any number in this repo; three docs disagreed because they mixed the
two.

- A **capability** is one distinct server implementation.
- A **roster entry** is one name in `local.mcpGateway.hostedServers` /
  `config.fleet.publicMcpServers`. `gmail` is **one capability and four entries** — one process
  per Google/Workspace account.

**Everything mechanical in this repo speaks in ENTRIES**: `checks.<system>.mcp-published-parity`,
the tier brackets in `modules/parts/identity.nix`, and every "N servers" comment. Say
"capabilities" out loud when you mean the other number.

| Moment | Entries | Capabilities |
|---|---|---|
| today | **25** | 22 |
| after the eight assignable servers move to their plugins (#657) | **19** | 16 |
| if #656 proves out and `github` + `postgres` follow | **17** | **14** |

The eight moving: `mobile-mcp`, `chrome-devtools`, `kapture`, `macos-automator`, `mcpfinder`,
`nixos`, `terraform`, `arxiv`. `github` and `postgres` are the two of the ten assignable ones held
back, **for two different reasons** — do not collapse them:

- **`github`** needs a Keychain credential (`GITHUB_PERSONAL_ACCESS_TOKEN`, delivered today by a
  `passwordCommand` wrapper), so it waits on #656's `headersHelper` prototype.
- **`postgres` needs no credential at all.** Its `DATABASE_URI` is a loopback **trust-auth** URI
  with no password — `modules/shared/mcp.nix:193-196` says it "is the one entry that ISN'T a
  Keychain command", and `:405` sets `env.DATABASE_URI` straight from
  `config.local.rag.pgvector.databaseUri`. It is held because **moving it makes the career RAG
  unreachable from Claude Desktop and the Cowork bridge**: that postgres line is "THE CAREER RAG's
  whole path to Claude Code" (`mcp.nix:783-784`), and a plugin-owned server never reaches Desktop,
  which sees only the all-or-nothing portal connector (`modules/shared/claude-desktop.nix:16-27`).
  It moves in the second batch (→ 17) once that loss has actually been weighed, not when #656
  lands.

This paragraph used to say both were held because "each needs a Keychain credential, and a plugin
`.mcp.json` interpolates `${ENV_VAR}` only." That was **false for `postgres`** and was corrected
2026-09-30. The conclusion did not change; the premise did. Recorded rather than silently fixed
because a right answer resting on a wrong reason breaks the moment someone checks the reason —
which is exactly what happened here. (The `${ENV_VAR}`-only half is also narrower than it reads:
the manifest reference documents `${VAR}`/`${VAR:-default}`, `${user_config.KEY}` with
`sensitive: true`, and `headersHelper` for remote servers.)

This convention is also what reconciles **#655's "10 of 24"** with the roster count everything
else uses: the capability count is the entry count minus the 3 gmail duplicates. At the original
27 entries that was 24; after #657 batch 1 retired `kapture` and `mobile-mcp` it is **25 entries /
22 capabilities**.

## Shape

One `mcp-proxy` launchd agent (`modules/shared/mcp.nix`, **darwin-only**) bound to
**`127.0.0.1:<publicMcpPort>`**, started at login, hosting **25 roster entries** today — every
server the fleet owns, heading for 19 and then 17 as § Counting convention lays out — each at
`/servers/<name>/mcp` (Streamable HTTP).

**Clients never address that port.** They dial one connector —
`https://mcp.kattakath.com/mcp`, the Cloudflare MCP portal — which authenticates against
Google Workspace and proxies back in through the tunnel. So every client config is a *single
entry* whose size does not change when the roster does, and every call carries an identity
instead of being trusted for running on this machine.

| | Before 2026-09-22 | Now | Target (#657, #656) |
|---|---|---|---|
| proxies | 2 (`:8096` private, `:8097` published) | **1** | 1 |
| what a client declares | 20+ loopback URLs | **1 portal URL** | 1 portal URL **+ each enabled plugin's own `.mcp.json`** |
| published servers | 2 of 26 | **25 of 25** | **17 of 17** (19 after the full #657 batch) |
| per-client stdio servers | `desktop-commander`, `open-design` | **none** | **the plugin-owned ones** — local stdio, Claude Code only, never portal-reachable |
| processes | ~50 (two copies of each server) | **25** | **17** on the gateway, the rest spawned per-session by Claude Code |
| machine-control tier (`identity.nix`) | — | **[5]** | **[1]** — `desktop-commander` alone |

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

There is **no project `.mcp.json`** — the user-scope gateway is the single source *for what it
hosts* (the Mac is the sole MCP client host; the Pi/VM stay lean). It is **not** the single source
of every MCP server Claude Code sees: an enabled marketplace plugin's own `.mcp.json` is a second,
deliberate lane (§ Which lane), and it is invisible to everything in this repo. Claude Desktop
reads no plugins, so for Desktop the gateway really is the whole world.

## Parity — the roster is checked, not remembered

`checks.<system>.mcp-published-parity` asserts `local.mcpGateway.hostedServers` equals
`config.fleet.publicMcpServers` in **both** directions, and fails the build otherwise:

- *hosted but NOT published* — the server exists and no client can ever see it.
- *published but NOT hosted* — terranix registers a dead upstream with Cloudflare.

This replaced the assertions that used to police `local.mcpGateway.public`. They could only
catch a published name that was not hosted; the parity check also catches the direction that
actually kept happening — a newly hosted server nobody remembered to publish.

**What parity CANNOT see, and it matters now.** It compares two *Nix* lists — `hostedServers`
against `fleet.publicMcpServers` — and nothing in this repo can read a marketplace plugin's
`.mcp.json` (the plugin content lives in `github:kattakath/skills`, and since 2026-09-23 it does
not even come through a `flake.lock` pin). So a server **deleted from both lists and never
declared in its owning plugin is a SILENT LOSS**: parity stays green, because both sides agree it
is gone. That is the failure mode of the #657 migration, and the only defence is the per-batch
sequence in § Publishing — declare in the plugin and *verify the tool answers* before deleting
here, never the other way round. Its two sides must also keep coming from different modules
(ADR-006 §7) — that property is unchanged by the ownership split.

### Spawn-test against the PATH runtime BEFORE declaring — the second rule of this migration

The gateway launches every stdio server from a **Nix store path**: `npx` comes from
`lib.getExe' pkgs.nodejs "npx"`, `uvx` from `pkgs.uv`. A plugin's `.mcp.json` cannot do that — it
may only name a **bare command on PATH**, because a store path rotates on every rebuild and the
plugin file lives in another repo. **So the two lanes can run different runtimes, and the plugin
lane is the weaker one.**

Measured 2026-09-30:

| | gateway | plugin lane |
|---|---|---|
| Node | pinned `nodejs-24.20.0` | whatever `npx` resolves to — fnm's **v20.20.2** |
| `node:sqlite` | present | **absent** (arrived in Node 22.5) |

`mcpfinder` was declared, failed with `CONNECTION_CLOSED`, and had to be reverted (skills#43 →
skills#44): `@mcpfinder/server@1.1.0` imports `node:sqlite`. The pinned `@1.1.0` is a **security
control** — it holds back `add_mcp_server_config`, which writes client config imperatively — so
bumping it to escape a Node error is a bad trade and was refused. **`mcpfinder` stays on the
gateway until the fleet's default Node is ≥ 22.5.**

**The rule: spawn the exact spec against the PATH runtime before declaring it.**

```bash
npx -y <package>@<version> --help      # or the real entry point
```

A declaration that has to be reverted costs two PRs and a false green. And note the inverse trap:
a server whose runtime arrives via a **nix-config package** (`mcp-nixos`, `terraform-mcp-server`,
`uv`) is **not** spawn-testable until that change is ACTIVATED — merged is not enough. Those
cannot be verified on paper.

### How to verify a plugin-owned server actually answers

A session already running cannot see a newly declared plugin server — its tool namespace was fixed
at session start. **A fresh process can.** Three steps:

1. **Confirm the refresh landed** — compare the cached plugin SHA against the marketplace branch:
   `~/.claude/plugins/installed_plugins.json` → `gitCommitSha` vs `gh api repos/<o>/<r>/commits/main`.
2. **Connect/fail per server** — `claude mcp list` in a fresh process. Plugin-owned servers appear
   as `plugin:<plugin>:<server>`.
3. **Actually invoke it** — a tool that loads is not a tool that answers:

   ```bash
   claude -p 'Call <tool> once and reply with ONLY its raw result.' \
     --allowedTools 'mcp__plugin_<plugin>_<server>__<tool>'
   ```

`--allowedTools` with the **plugin-lane spelling** is what makes step 3 a discriminator rather than
a green tick: during the duplicate window the gateway still serves the same capability under
`mcp__plugin_hm_kattakath-portal__<server>_<tool>`, so a bare call can be satisfied by the wrong
lane. Naming the plugin-lane tool explicitly cannot be.

Judge the result against a criterion written **before** the test. An empty result is often the pass:
`kapture list_tabs → {"tabs":[]}` is correct (a tab appears only once the operator toggles it), and
`mobile-mcp mobile_list_available_devices → {"devices":[]}` is correct with no phone attached — what
mattered there was the **absence** of an `adb`/`ANDROID_HOME` error, which proved the plugin child
inherits the session environment and let the gateway's Android SDK wiring be deleted rather than
duplicated.
## The 7 packaged servers (`mcp-servers-nix`)

`context7`, `fetch`, `memory`, `sequential-thinking`, `nixos`, `terraform`, `github` — pinned
via `mcp-servers-nix.lib.mkConfig`'s `programs` block. Credentials, where needed, are read from
the login Keychain at **gateway launch** by a `passwordCommand` wrapper, so no token is ever in
argv or the `/nix/store` (`context7` → `CONTEXT7_API_KEY`, `github` →
`GITHUB_PERSONAL_ACCESS_TOKEN`; an absent key means an empty export and the server degrades
rather than crashing).

## The 15 custom stdio launchers

| Server | Notes |
|---|---|
| `desktop-commander` | **SHELL/RCE surface — hosted AND published.** `@wonderwhy-er/desktop-commander`, on the gateway since 2026-09-22 by operator decision. What that accepts, stated rather than implied: anything holding a valid Workspace session for this domain can drive a shell on this Mac through the portal. It was excluded until then, and two assertions made the exclusion structural; with every server published the private/published split bounded nothing, so keeping this one off bought a second transport and process tree for no isolation. The gate is Access + Workspace OAuth restricted to the domain — the same gate every other server is behind |
| ~~`kapture`~~ | **MOVED 2026-09-30** to the `page-lab` plugin (#657 batch 1). The extension half (`local.chromium.kaptureMcp`) stays in nix-config — the plugin owns only the client |
| `duckduckgo` | web search |
| `arxiv` | arXiv literature loop via `arxiv-mcp-server` (pinned, `--python 3.12`): search, abstracts, section-level LaTeX reads, BibTeX, Semantic Scholar citation graphs, topic watches. No credentials; papers + watches under `$XDG_DATA_HOME/arxiv-mcp-server/papers` |
| `json-yaml-toml` | structured-data convert/query/diff/merge/schema |
| `mcp-jq` | `jq` over files and payloads |
| `mcpfinder` | cross-registry MCP-server **DISCOVERY** (Official MCP Registry + Glama + Smithery, `@mcpfinder/server` pinned), wired **discovery-only**: `.claude/settings.json` pre-approves only its FOUR read-only tools by name (`browse_categories`, `get_install_config`, `get_server_details`, `search_mcp_servers`), so a config-writing tool added by a future version pin matches no allow rule and prompts. It had one, `add_mcp_server_config`; the pinned version no longer registers it, which is why the deny that named it was removed rather than re-spelled (2026-09-16). MCP adoption in this repo is always a pinned declaration in `mcp.nix` via the `mcp-scout` skill, never an imperative install |
| `cloudflare-docs` | Cloudflare documentation search |
| `cloudflare` | Cloudflare API; needs a one-time browser login and fails gracefully headless |
| `apify` | Apify Store's ready-made scraper/crawler Actors, run **LOCALLY** via `@apify/actors-mcp-server`, authenticated by an `APIFY_TOKEN` read from the Keychain at launch. Switched 2026-08-19 from the hosted `mcp.apify.com` OAuth bridge, which never completed its interactive login under the headless launchd gateway; a missing token warns but does not dark the gateway |
| `macos-automator` | AppleScript/JXA automation — needs a one-time macOS Accessibility (TCC) grant, see [`mcp-gateway-accessibility-tcc.md`](mcp-gateway-accessibility-tcc.md) |
| ~~`mobile-mcp`~~ | **MOVED 2026-09-30** to the `android-phone` plugin (#657 batch 1). No longer on the gateway |
| `postgres` | local Postgres (incl. the RAG store) |
| `wordpress` | docdyhr/mcp-wordpress (pinned) — **CLIENT-SIDE** WordPress admin over a live site's REST API with an Application Password (nothing installed on the site). Creds are Keychain items `mcp:silvercreek.ai:wp_url`/`:wp_user`/`:wp_app_password`, read BY SERVICE NAME (the `$WP_*` names are only env bindings) and injected by the generated `mkGeneratedStdio` wrapper — `wpMcp` is gone; canonical **www** host required, and the password must be a 24-alphanumeric Application Password, not a login password |
| `wordpress-adapter` | the official WordPress MCP Adapter (**server-side, SILVERCREEK.AI PROD**), reached via a Keychain-injecting `mcp-remote` wrapper against `https://www.silvercreek.ai`; always-on since prod is always reachable |

## Publishing — `config.fleet.publicMcpServers`

There is no `local.mcpGateway.public` option any more. The roster is a fleet constant in
`modules/parts/identity.nix`, and it drives three things from one list: the proxy's own server
set, the `cloudflared` connector agent (`nix-mcp-tunnel-connector`), and the Cloudflare
registrations.

Narrow it by deleting names there; the next apply DROPS their Cloudflare objects, which the
`mkMcpPublicTofu` drop-guard makes you confirm (`MCP_PUBLIC_ALLOW_DROPS=1`).

**Narrowing is now a PLANNED MIGRATION, not an exception.** #657 moves eight entries out in
batches. Because § Parity is blind to the plugin side, the order inside each batch is the whole
safety argument — do it exactly this way, one batch at a time:

1. **Declare first, in the plugin.** Add the server to the owning plugin's `.mcp.json` in
   `github:kattakath/skills` and push; start a fresh Claude Code session and **call one of its
   tools**. A declared-but-broken plugin server looks identical to a working one until called.
2. **Then delete here** — the name from `local.mcpGateway.hostedServers` (`modules/shared/mcp.nix`)
   **and** from `config.fleet.publicMcpServers` (`modules/parts/identity.nix`), in the SAME commit.
   Deleting one side alone is what `mcp-published-parity` exists to catch; deleting both is what it
   cannot.
3. **Re-tier.** Update the bracketed tier counts in `identity.nix` so they still sum to the new
   entry total. A batch that leaves the arithmetic unlanded is the drift this repo keeps re-fixing.
4. `git add -A ; nix fmt ; nix flake check` — then `activate`.
5. **One `cf-*` apply per batch**, not per server: `MCP_PUBLIC_ALLOW_DROPS=1 nix run
   .#mcp-public-apply` drops the batch's Cloudflare objects.
6. **`nix run .#mcp-public-sync`** so the portal re-polls and stops advertising the dropped tools.
7. **Say what Desktop lost.** Each moved server leaves Claude Desktop and the Cowork bridge
   entirely (`modules/shared/claude-desktop.nix` § THE PLUGIN CONSEQUENCE). Record it in the PR
   body; nothing detects it.

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
  `extraHomeModules` was fully retired 2026-09-15, and **two** of the four above are what
  survived its list of seven — so those four are the WHOLE roster now, not a public subset of
  a longer private one (the per-address reasoning lives in `hosts/macos.nix`'s own comment on
  the option, #524). Runbook:
  [`gmail-mcp-multi-account-runbook.md`](gmail-mcp-multi-account-runbook.md).

## Auth caches

OAuth tokens cache per-machine in `~/.mcp-auth`. `cloudflare` needs a one-time browser login
and fails gracefully headless; `apify` instead reads `APIFY_TOKEN` from the Keychain at launch
(no OAuth) and likewise warns without darkening the gateway if the token is missing.

## Which lane — ONE OWNER PER SERVER

A capability arrives one of three ways, and since 2026-09-30 the choice is **not** "gateway by
default". It is decided by **ownership**, and the rule has exactly one question in it:

> **Is this server the tool half of a skill this fleet already ships?**
> Yes → it belongs to that skill's marketplace plugin. No → it stays on this gateway, permanently.

| Lane | It belongs here when | The consequence you are accepting |
|---|---|---|
| **Owning marketplace plugin** (`github:kattakath/skills`) | a skill/agent/command in that plugin is the **reason** this server exists — the plugin already ships the prose, the server is its hands (`page-lab` ← `chrome-devtools` + `kapture`; `android-phone` ← `mobile-mcp`; `mac-app-send` ← `macos-automator`; `harvest` ← `mcpfinder`; `claude-code-nix` ← `nixos`) | **Claude-Code-only.** Gone from Claude Desktop and Cowork (`claude-desktop.nix`). No `flake.lock` pin. No Keychain credential — `.mcp.json` interpolates `${ENV_VAR}` only. Invisible to `mcp-published-parity` |
| **This gateway** | **nothing owns it** — it is a fleet utility, or it carries identity/credentials/machine reach that a plugin cannot express | Declarative, pinned, Keychain-wired, account-agnostic, and reachable by **every** client through one portal URL. Costs a portal registration and a slice of the leaked-service-token blast radius |
| claude.ai connector | the surface is **Anthropic-native** (Claude Docs, Excalidraw), or a **vendor OAuth** you would otherwise rebuild for low volume (Slack, Drive) | **Per-account state, clicked in a web UI** — undeclarable, unpinnable, re-done by hand per account |

**The three groups that structurally CANNOT move, whatever plugin might want them:**

| Group | Why it is stuck here |
|---|---|
| `gmail-*` (four entries) | **Identity.** The roster is `local.mcpGateway.gmail.accounts` in `hosts/macos.nix:329` — real addresses, one process and one OAuth session per account, each token out of the login Keychain. A plugin `.mcp.json` can express none of that, and the accounts are not a plugin's business |
| `desktop-commander` | **RCE.** A shell, published by operator decision and tiered as machine control on purpose (#660). Moving it into plugin-owned stdio would hand its lifecycle to whatever plugin claimed it and drop it out of the tier arithmetic that keeps the blast radius legible |
| the generic utilities — `fetch`, `duckduckgo`, `memory`, `sequential-thinking`, `context7`, `json-yaml-toml`, `mcp-jq`, `apify`, `cloudflare`, `cloudflare-docs`, `wordpress`, `wordpress-adapter` | **No owner exists.** They are fleet-wide lookup/compute or credentialed prod surfaces; no single skill is their reason. Inventing a skill-less plugin to hold them was considered and rejected in #658 — it buys a wrapper and loses the pin, the Keychain and Desktop |

**Why the gateway still wins for everything unowned.** This Mac drives a personal Claude Max
account *and* an organisation Teams account, so anything account-scoped must be configured twice
and drifts; a reset Mac restores the gateway from `activate`, and restores nine connectors by
clicking through nine OAuth flows.

**The measurement, 2026-09-23** (every MCP tool call across 21 days of transcripts): gateway
**~3,200 calls / 94%**, all nine claude.ai connectors **218 / 6%**, marketplace plugins **76**
— of which Neon alone was 70. Standardising *everything* on plugins is still the one option the
data excludes; the ownership split is not that, and the moved servers are the low-volume tail.

**The security upside, which is the strongest argument for the split.** `identity.nix`'s machine-
control tier goes **[5] → [1]** (now at **[3]**: `kapture` and `mobile-mcp` left in batch 1): `macos-automator`, `chrome-devtools`, `kapture` and `mobile-mcp`
become local plugin stdio, **not portal-reachable at all**. A leaked Access service token then
reaches one machine-control server (`desktop-commander`) instead of five.

**Retired framing — "duplication is only worth removing when it is pure" (2026-09-30).** That rule
said a plugin's MCP half "duplicates a gateway server for no gain", and it argued *against* the
decision above; it is replaced by **one owner per server**. What survives from it is the
observation, not the verdict: a plugin ships more than a server (`context7@context7-marketplace`
also brings a `docs-researcher` agent that fetches docs in a subagent), so count what a plugin
ships. `context7` is the one deliberate duplicate left — it has an owner-less gateway entry *and*
a plugin — because the plugin's agent and the gateway's Keychain-wired server answer different
questions.

## Adding a server

Always via the `mcp-scout` skill / `/mcp-scout` command: discover → vet → **pick the lane**
(§ Which lane) → **declare**. For a gateway server that means `mcp.nix` (pinned) plus
`config.fleet.publicMcpServers`, `.claude/settings.json` permission rules (allow read-only tools,
deny anything that writes outside its remit), and a `nix-*` `arg0` basename for any wrapper per
[`launchd-naming.md`](../.claude/rules/launchd-naming.md). For a plugin-owned server it means that
plugin's `.mcp.json` in `github:kattakath/skills` and **nothing in this repo** — which also means
no pin, no Keychain credential and no Claude Desktop. Imperative installer CLIs and
config-writing install tools are never used in either lane.

## Related

- [`mcp-gateway-accessibility-tcc.md`](mcp-gateway-accessibility-tcc.md) — the one-time
  Accessibility (TCC) grant `macos-automator` needs.
- [`gmail-mcp-multi-account-runbook.md`](gmail-mcp-multi-account-runbook.md) — multi-account
  Gmail setup, auth, and a documented silent-wrong-account failure mode.
- [`mcp-public-exposure-design.md`](mcp-public-exposure-design.md) — the PUBLISHED gateway's
  design and the Cloudflare side. Read its **§10 then §11** first: the two-proxy model the body
  describes was collapsed on 2026-09-22, and §11 is the 2026-09-30 ownership split — narrowing now
  restores structural absence without losing the capability for Claude Code.
- [`private-home-modules.md`](private-home-modules.md) — the `extraHomeModules`/`hostedSites`
  composition seams, and the nixpi deploy runbook.
