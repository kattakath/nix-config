# Test plan — HyperFrames self-host

Scope: Linux VM stack (Funnel → Caddy → mcp-auth-proxy → Kinocut + HyperFrames), plus Nix export/apply path.

## 0. Preconditions

| # | Check | Pass criteria |
| --- | --- | --- |
| 0.1 | Linux VM has Docker 24+ + compose v2 | `docker compose version` works |
| 0.2 | Tailscale tailnet has Funnel enabled | Admin console → Funnel allowed for tagged nodes / user |
| 0.3 | Google OAuth Web client in **Testing** | Test users listed; redirect URI prepared |
| 0.4 | aarch64 image build feasible | VM is aarch64 (or amd64 with matching binary arch) |

## 1. Package / export integrity (Darwin or CI)

| # | Step | Pass criteria |
| --- | --- | --- |
| 1.1 | `git add -A && nix eval .#packages.aarch64-darwin.hf-export.meta.name` (or build) | Derivation evaluates |
| 1.2 | `nix run .#hf-export -- /tmp/hf-test` | Tree copied; `install.sh` executable; `terraform/config.tf.json` present |
| 1.3 | `jq . < /tmp/hf-test/terraform/config.tf.json` | Valid JSON; contains `local_sensitive_file` / `null_resource` |
| 1.4 | Shellcheck install scripts (optional) | `shellcheck install.sh scripts/*.sh image/entrypoint.sh` clean or documented exceptions |

## 2. Cold install on VM

| # | Step | Pass criteria |
| --- | --- | --- |
| 2.1 | Rsync export to VM | Files present under `~/hyperframes-selfhost` |
| 2.2 | `./install.sh` with real secrets | Compose builds; containers `hf-tailscale`, `hf-caddy`, `hf-mcp` running |
| 2.3 | MagicDNS resolution | install prints `https://<name>.ts.net` and writes `EXTERNAL_URL` |
| 2.4 | Funnel | `docker exec hf-tailscale tailscale funnel status` shows HTTPS proxy to `:8080` |

## 3. Local health (on VM)

| # | Step | Pass criteria |
| --- | --- | --- |
| 3.1 | `./scripts/doctor.sh` | All critical checks OK |
| 3.2 | Loopback Caddy | `wget -qO- http://127.0.0.1:8080/` returns from mcp-auth-proxy (not connection refused) |
| 3.3 | Kinocut binary | `docker exec hf-mcp kino doctor` (or `kino --help`) succeeds |
| 3.4 | HyperFrames binary | `docker exec hf-mcp hyperframes --version` (or help) succeeds |

## 4. OAuth / MCP protocol

| # | Step | Pass criteria |
| --- | --- | --- |
| 4.1 | Unauthenticated MCP | `curl -i -X POST "$EXTERNAL_URL/mcp" -H 'content-type: application/json' -d '{}'` → **401** + WWW-Authenticate / OAuth discovery hints |
| 4.2 | AS metadata | `curl -fsS "$EXTERNAL_URL/.well-known/oauth-authorization-server"` (or proxy equivalent) returns JSON with authorization/token endpoints |
| 4.3 | Allowlisted user | Claude/Grok custom connector → Google login as allowlisted email → connected |
| 4.4 | Deny non-allowlisted | Second Google account **not** in `GOOGLE_ALLOWED_USERS` (and not a Test user) fails closed |
| 4.5 | Tool list | Authenticated client `tools/list` includes Kinocut / HyperFrames tools (e.g. hyperframes_* or video tools) |

## 5. Functional render smoke

| # | Step | Pass criteria |
| --- | --- | --- |
| 5.1 | Init composition | Via MCP or `docker exec -w /workspace hf-mcp hyperframes init smoke` creates project files |
| 5.2 | Render (short) | Minimal HTML composition renders to MP4 under `/workspace` without crash (timeout ≤ 5–10 min on small VM) |
| 5.3 | Workspace mount | Output file visible on VM host under `WORKSPACE_DIR` |

## 6. Isolation / posture

| # | Step | Pass criteria |
| --- | --- | --- |
| 6.1 | Darwin has no Funnel | Host `tailscale funnel status` absent or unused for this service |
| 6.2 | No host port publish | `docker compose` does not publish 80/443 on the Mac; only VM runs compose |
| 6.3 | Stop Funnel | Stopping `hf-tailscale` removes public access; private data remains on volume |

## 7. Day-2 ops

| # | Step | Pass criteria |
| --- | --- | --- |
| 7.1 | Restart mcp | `docker compose restart mcp` recovers healthz |
| 7.2 | Rotate Google secret | Update `.env`, `docker compose up -d mcp`, OAuth still works |
| 7.3 | Re-run install.sh | Idempotent; no duplicate destructive reset of workspace media |
| 7.4 | OpenTofu path | `TF_VAR_*=… tofu apply` in `terraform/` (or `nix run .#hf-apply`) converges |

## 8. Failure injection

| # | Step | Pass criteria |
| --- | --- | --- |
| 8.1 | Bad `TS_AUTHKEY` | Tailscale container logs auth error; install warns clearly |
| 8.2 | Empty allowlist | Container refuses to start or rejects all logins |
| 8.3 | Wrong redirect URI | Google error page; README points at correct callback path |
| 8.4 | Disk full on render | Kinocut/HyperFrames error surfaces in MCP tool result / logs |

## Sign-off

| Role | Name | Date | Result |
| --- | --- | --- | --- |
| Implementer | | | |
| Operator | | | |

Record: EXTERNAL_URL, image digests (`docker images`), and `kino doctor` summary (no secrets).
