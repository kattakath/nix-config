# Test plan — HyperFrames self-host

Scope: Funnel → Caddy → mcp-auth-proxy → Kinocut + HyperFrames.  
Cold path validated 2026-07-26 on Docker Desktop linux/arm64 (partial public Funnel + 401).

## 0. Preconditions

| # | Check | Pass criteria |
| --- | --- | --- |
| 0.1 | Docker Engine 24+ + compose v2 (Linux or Docker Desktop Linux VM) | `docker compose version` works |
| 0.2 | Tailscale tailnet can enable Funnel | Funnel enable URL succeeds |
| 0.3 | Google OAuth **Web** client | Redirect URI set to `https://<dns>/.auth/google/callback` |
| 0.4 | `.env` present, mode 0600, gitignored | `GOOGLE_*` + `TS_AUTHKEY` + non-empty `GOOGLE_ALLOWED_USERS` |
| 0.5 | mcp-auth-proxy flags match entrypoint | `--help` lists external-url, listen, no-auto-tls, data-path, google-* |

## 1. Package / export (Nix)

| # | Step | Pass criteria |
| --- | --- | --- |
| 1.1 | `nix build .#packages.aarch64-darwin.hf-export` (or target system) | Derivation builds |
| 1.2 | `nix run .#hf-export -- /tmp/hf-test` | Tree + executable install.sh; **do not** put terranix JSON beside hand `main.tf` if both present |
| 1.3 | Validate export JSON if used alone | Valid JSON when tofu path is used in isolation |

## 2. Cold install

| # | Step | Pass criteria | Status (2026-07-26) |
| --- | --- | --- | --- |
| 2.2 | `./install.sh` with real secrets | Containers `hf-tailscale`, `hf-caddy`, `hf-mcp` running; EXTERNAL_URL rewritten from MagicDNS | **pass** |
| 2.2b | Two-phase order | Tailscale healthy before MCP image build completes | **pass** |
| 2.2c | Funnel enable | `tailscale funnel status` shows HTTPS → `:8080` | **pass** (after tailnet Funnel enable) |

## 3. Local health

| # | Step | Pass criteria | Status |
| --- | --- | --- | --- |
| 3.1 | `./scripts/doctor.sh` | Critical checks OK | partial |
| 3.2 | Loopback Caddy | Request to `127.0.0.1:8080` reaches mcp-auth-proxy (401 OK) | **pass** |
| 3.3 | `docker exec hf-mcp kino` / doctor | Binary present | not fully exercised |
| 3.4 | `hyperframes` on PATH in image | CLI present (pinned 0.7.73) | after rebuild |

## 4. OAuth / MCP

| # | Step | Pass criteria | Status |
| --- | --- | --- | --- |
| 4.1 | Unauthenticated MCP | Public or loopback `POST /mcp` → **401** | **pass** (loopback + public Funnel with public DNS) |
| 4.2 | AS metadata | `/.well-known/oauth-authorization-server` JSON | **pass** |
| 4.3 | Allowlisted user | Browser OAuth as allowlisted email → tools/list | **manual / pending** |
| 4.4 | Deny non-allowlisted | Other Google account fails closed | **manual / blocking until proven live** |
| 4.4b | Empty allowlist fail-closed | entrypoint requires `GOOGLE_ALLOWED_USERS` | **pass** (code + flag audit) |
| 4.4c | CSV split | `--google-allowed-users` help says comma-separated; `splitCSV` | **pass** (upstream source + binary --help) |

## 5. Functional render smoke

| # | Step | Pass criteria |
| --- | --- | --- |
| 5.1–5.3 | HyperFrames init/render under `/workspace` | Optional; not required for auth gate |

## 6. Isolation / posture

| # | Step | Pass criteria |
| --- | --- | --- |
| 6.1 | Darwin host no Funnel for this service | Funnel only on `hf-tailscale` container |
| 6.2 | Host listen inventory | `lsof -iTCP -sTCP:LISTEN` on Mac: no accidental public bind of mcp/caddy |
| 6.3 | Host not required as Funnel node | Stack works with Docker Desktop alone |

## 7. Day-2 ops

| # | Step | Pass criteria |
| --- | --- | --- |
| 7.1 | Restart mcp | Recovers healthz |
| 7.2 | **Netns restart** | `docker compose restart tailscale` (or recreate): document whether caddy/mcp need recreate (shared `network_mode: service:tailscale`) |
| 7.3 | Install idempotency | Second `./install.sh`: no wipe of workspace media; EXTERNAL_URL stable |
| 7.4 | Rotate Google secret | Update `.env`, recreate mcp, OAuth still works |

## 8. Failure injection

| # | Step | Pass criteria |
| --- | --- | --- |
| 8.1 | Bad `TS_AUTHKEY` | Clear logs; restart loop or auth failure |
| 8.2 | Empty allowlist | Container refuses start |
| 8.3 | Wrong redirect URI | Google error page |
| 8.4 | `TS_EXTRA_ARGS=--accept-dns=false` | Must **not** be set (double-flag crash) |

## Sign-off

| Role | Date | Result |
| --- | --- | --- |
| Cold install + 2.2 / 3.2 / 4.1 | 2026-07-26 | pass on Docker Desktop arm64 |
| 4.3 / 4.4 browser | | pending human |

Record: EXTERNAL_URL, image digests, `kino`/`hyperframes` versions — never secrets.
