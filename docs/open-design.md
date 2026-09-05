# OpenDesign — the declared/imperative boundary

OpenDesign (`nexu-io/open-design`, Apache-2.0) is an Electron design-agent desktop app.
This page is the honest map of **what this repo declares** and **where declarative
management stops** — the app is a signed, self-stateful GUI, so the boundary is real
and deliberate, not an omission.

## What is declared (and where)

| Layer | Where | Mechanism |
|---|---|---|
| The app itself | `hosts/macos.nix` `homebrew.casks` | Cask `open-design`, `greedy = true`. `brew bundle` passes `--adopt` to fresh cask installs, so the pre-existing hand-dragged `/Applications` copy was adopted in place — no re-copy, no touch of the app's state. |
| Its self-updater: **off** | `hosts/macos.nix` `launchd.user.envVariables.OD_UPDATE_ENABLED = "0"` | nix-darwin emits `launchctl setenv` at activation; Finder/Dock-launched GUI apps inherit it (same mechanism as the GUI PATH in `modules/darwin/core.nix`). Versioning belongs to brew: `greedy` opts the cask past `onActivation.upgrade = false`, and Homebrew's autobump keeps the cask current. |
| MCP registration | `modules/shared/mcp.nix` (Client side A) | Per-client **stdio** entry in `programs.claude-code.mcpServers` — the home-manager module writes it into a managed plugin `.mcp.json`, never `~/.claude.json`. Not gateway-hosted: upstream is stdio-only and has a silent-death bug (#7273) that would dark all hosted servers. |
| Tool permissions | `.claude/settings.json` | Only the read-only tools (`list_*`, `get_*`, `search_files`) are pre-allowed; anything that writes stays prompt-gated. |

## Why the updater is disabled

The in-app updater does **not** overwrite `/Applications`. It extracts payloads into
`~/Library/Application Support/Open Design/launcher/…/versions/<v>/payload/` and relaunches
from there (upstream #7264). Measured on this machine before this config existed:

- the MCP registration pointed at a **0.20.2** launcher payload while `/Applications`
  held **0.21.1** — a silent, permanent version split;
- ~1.7 GB of debris accumulated (`launcher/` 913 MB + `updates/` 755 MB).

With `OD_UPDATE_ENABLED=0` + the greedy cask, `/Applications` is the only copy that ever
runs, and updates land at activation under operator control.

## Why the MCP entry looks the way it does

- **Interpreter** = the app's own Electron helper with `ELECTRON_RUN_AS_NODE=1` —
  upstream's sanctioned invocation; keeps the bundled `better-sqlite3` on its
  Electron ABI.
- **`OD_DATA_DIR`** is mandatory (without it the CLI falls back to `<cwd>/.od` inside
  the read-only bundle → EPERM, upstream #848) and must be absolute (upstream #390).
  It is derived from `config.home.homeDirectory` — never a hardcoded `/Users/…`.
- **No `--daemon-url`** — its absence keeps sidecar re-discovery working across
  daemon restarts *and* keeps the headless bootstrap armed (an explicit URL disables
  bootstrap entirely, per the guard in the bundle's `mcp-bootstrap` chunk).
- **Cold start**: when no daemon is reachable, the stdio process launches the app
  headless via `/usr/bin/open -g -j … --args --headless` and polls
  `/api/health` for up to 60 s. Measured working here (windowless daemon runs from
  `/Applications`). `od daemon start --headless` also exists (hidden from top-level
  `--help`) as a manual fallback.

## What stays imperative — and why

| Surface | Why it cannot be declared |
|---|---|
| `~/Library/Application Support/Open Design/…` (~1 GB: SQLite, projects, artifacts, Chromium profile) | The app's live mutable state. `OD_DATA_DIR` is upstream's only relocation lever; the content itself must stay writable. |
| **BYOK provider keys** (`data/media-config.json`, written `0644` with plaintext keys — an upstream bug; no Keychain support exists in the app) | The daemon reads `OD_*_API_KEY` env vars cleanly, but env can only reach processes *this repo spawns* (the MCP process / bootstrapped daemon), not a Finder-launched desktop — and `launchd.user.envVariables` values land in the world-readable store, so secrets can never go there. A split credential store is worse than one honest imperative one. Keys are entered in the app's Settings UI. |
| Cloud sign-in / OAuth tokens | Upstream forces login (issue #7275); tokens are app-managed state. |
| Installed plugins (`od-plugin-lock.json`) | `od plugin install` mutates a lockfile + SQLite by design. Nothing installed today beyond the bundle; revisit only if that changes. |
| `/Applications/Open Design.app/Contents/**` | Notarized seal over 14,698 files — any edit voids it. Nix never touches the bundle. |
| One-time: `claude mcp remove open-design -s user` | The app's UI had written an imperative user-scope entry into `~/.claude.json`; the Nix entry lives in a different scope, so the old one duplicates rather than being shadowed and had to be removed once by hand. |

Deliberately **not** on `macvm`: a 914 MB GUI app plus ~1 GB of state has no role in the
lean VM (its cask list is its own — `hosts/macvm.nix`).

## Verification

```bash
claude mcp list                      # open-design must come from the managed plugin, not ~/.claude.json
pgrep -fl "Open Design"              # after a cold-start tool call: daemon runs from /Applications, --headless
launchctl getenv OD_UPDATE_ENABLED   # → 0 after activation
brew list --cask | grep open-design  # cask owns the app
```
