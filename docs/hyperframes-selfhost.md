# HyperFrames self-host — operator runbook (cold path)

Self-host **Kinocut + HyperFrames** behind **Caddy**, **sigbit/mcp-auth-proxy**
(Google OAuth + email allowlist), and **Tailscale Funnel on the Linux engine
only** (Darwin host stays isolated).

Public tree: [`packages/hyperframes-selfhost/`](../packages/hyperframes-selfhost/).  
Installer: `./install.sh` (two-phase; see below).  
Test plan: [`hyperframes-selfhost-test-plan.md`](./hyperframes-selfhost-test-plan.md).

## Architecture

```
Internet ──HTTPS──▶ Tailscale Funnel (container on Linux engine)
                         │
                         ▼
                      Caddy :8080   (plain HTTP; Funnel terminates TLS)
                         │
                         ▼
              mcp-auth-proxy :8090  (OAuth 2.1 AS + Google + allowlist)
                         │ stdio
                         ▼
                   Kinocut (`kino`) + HyperFrames CLI + FFmpeg
```

| Layer | Pin / choice | Notes |
| --- | --- | --- |
| Funnel | `tailscale/tailscale:v1.84.0` | Kernel networking (`TS_USERSPACE=false`); Funnel must be **enabled on the tailnet** |
| Proxy | `caddy:2.10-alpine` | `flush_interval -1` for SSE |
| OAuth | `mcp-auth-proxy` **v2.10.2** | Flags: `--external-url`, `--listen`, `--no-auto-tls`, `--data-path`, `--google-*` |
| App | `kinocut[image]==1.11.1` + `hyperframes@0.7.73` | HeyGen hosted MCP is **not** self-hostable |

### Allowlist semantics (blocking knowledge)

Upstream `pkg/auth/google.go`: if **both** `allowedUsers` and `allowedWorkspaces` are empty, **any** Google account is authorized. Matching is exact `slices.Contains` on emails.

`--google-allowed-users` is a **comma-separated** string; `splitCSV` splits and trims. Always set `GOOGLE_ALLOWED_USERS` non-empty (install + entrypoint require it).

## Cold setup (operator checklist)

Validated 2026-07-26 on Docker Desktop **linux/arm64**.

### A. Google Cloud (before or during install)

1. Project with **Google Auth Platform** enabled.
2. OAuth consent → **External** (Internal needs Workspace).
3. Prefer **Production** for long-lived MCP refresh tokens; **Testing** works for smoke but Test users + ~7-day refresh expiry.
4. Create **OAuth client → Web application** (not Desktop).
5. Save Client ID + secret → `.env` (`GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`).
6. **Redirect URI** (after Funnel hostname is known):
   ```text
   https://<TS_HOSTNAME>.<tailnet>.ts.net/.auth/google/callback
   ```
   Example live: `https://hyperframes.tail3d97d8.ts.net/.auth/google/callback`
7. Test users (if Testing): same emails as `GOOGLE_ALLOWED_USERS`.

### B. Tailscale

1. Enable **Funnel** on the tailnet (first enable may require  
   `https://login.tailscale.com/f/funnel?node=…` printed by `tailscale funnel`).
2. **Keys → Generate auth key**:
   - Description: e.g. `HyperFrames-SelfHost`
   - **Reusable: ON**
   - **Ephemeral: OFF**
   - Tags: optional
   - Expiry: e.g. 90 days
3. Put `TS_AUTHKEY=tskey-auth-…` in `.env`.

### C. Install (Linux VM or Docker Desktop Linux engine)

```bash
cd packages/hyperframes-selfhost   # or exported public tree
cp .env.example .env               # if needed
# fill TS_AUTHKEY + GOOGLE_* (+ GOOGLE_ALLOWED_USERS)
chmod 600 .env
./install.sh
```

**What install.sh does (two-phase):**

1. Ensure Docker is up.
2. Start **only** `tailscale` with auth key.
3. Wait for MagicDNS (`tailscale status --json` → `Self.DNSName`).
4. Write `EXTERNAL_URL=https://<dns>` into `.env`.
5. `docker compose up -d --build` (Caddy + MCP image).
6. Best-effort `tailscale funnel --bg http://127.0.0.1:8080`.
7. Wait for `GET http://127.0.0.1:8090/healthz` → `{"status":"ok"}`.
8. Print MCP URL + Google redirect URI.

**Do not** set `TS_EXTRA_ARGS=--accept-dns=false` — the official image already wires accept-dns; a second flag crashes with  
`flag provided multiple times`.

### D. Verify

```bash
docker compose ps
./scripts/doctor.sh

# Loopback (always works inside shared netns):
docker exec hf-tailscale wget -qO- http://127.0.0.1:8090/healthz
docker exec hf-tailscale wget -S -O- --post-data='{}' \
  --header='Content-Type: application/json' http://127.0.0.1:8080/mcp
# expect HTTP 401

# Public Funnel (host DNS may fail on *.ts.net — use public resolver):
dig +short hyperframes.<tailnet>.ts.net @8.8.8.8
curl -i -X POST "https://hyperframes.<tailnet>.ts.net/mcp" \
  -H 'content-type: application/json' -d '{}'
# expect HTTP 401 Unauthorized
```

### E. Connect MCP clients

- Server URL: `https://<host>.ts.net/mcp`
- Complete Google login as an allowlisted email.
- Deny check: second Google account **not** in `GOOGLE_ALLOWED_USERS` (and not a Test user if still Testing).

## Nix dual delivery

```bash
nix run .#hf-export -- ./dist/hyperframes-selfhost
# rsync to VM, then ./install.sh
```

**Terraform / OpenTofu:** optional and secondary. Prefer `install.sh` + compose.  
Do **not** run `tofu` against a directory that contains both hand-written `main.tf` and terranix `config.tf.json` (duplicate resources). Prefer one path only.

## Ops gotchas (from cold install)

| Symptom | Cause | Fix |
| --- | --- | --- |
| `hf-tailscale` restart loop, `accept-dns` multiple times | `TS_EXTRA_ARGS=--accept-dns=false` | Remove it |
| `EXTERNAL_URL is unset` on compose | Empty `.env` value | Let install bootstrap; never leave required empty for raw `compose up` |
| Funnel: “not enabled on your tailnet” | Account flag | Open the printed login.tailscale.com/f/funnel URL |
| Host `curl` cannot resolve `*.ts.net` | Local DNS | `dig @8.8.8.8` or `--resolve` with public A records |
| “No serve config” | Serve JSON not applied yet | `tailscale funnel --bg http://127.0.0.1:8080` after Funnel enabled |
| OAuth any Google user works | Empty allowlist | Never ship empty `GOOGLE_ALLOWED_USERS` |

## Related

- Public README: [`packages/hyperframes-selfhost/README.md`](../packages/hyperframes-selfhost/README.md)
