# HyperFrames self-host (Linux VM + Terranix)

Self-host **Kinocut + HyperFrames** on a local **aarch64 Linux VM**, with:

- **Tailscale Funnel only inside the VM** (Darwin host stays isolated)
- **Google OAuth in Testing mode** + email allowlist
- **Caddy** reverse proxy
- **sigbit/mcp-auth-proxy** (popular MCP OAuth 2.1 gateway)
- **Terranix** in this flake generating plain OpenTofu for a **public, non-Nix** install tree

## Architecture (validated)

```
                    ┌─────────────────────────────────────────────┐
 Darwin host        │  nix-config (terranix + packages/)          │
 (isolated)         │  nix run .#hf-export / .#hf-apply           │
 no Funnel          │  admin via Tailscale SSH to VM (optional)   │
                    └──────────────────┬──────────────────────────┘
                                       │ rsync / scp / git
                                       ▼
                    ┌─────────────────────────────────────────────┐
 Linux VM           │  docker compose                             │
 (aarch64)          │                                             │
                    │  Internet ──HTTPS──▶ Tailscale Funnel        │
                    │                         │                   │
                    │                         ▼                   │
                    │                      Caddy :8080            │
                    │                         │                   │
                    │                         ▼                   │
                    │              mcp-auth-proxy :8090            │
                    │              Google OAuth + allowlist        │
                    │                         │ stdio             │
                    │                         ▼                   │
                    │              Kinocut (`kino`) MCP            │
                    │              + HyperFrames CLI + FFmpeg      │
                    └─────────────────────────────────────────────┘
```

### Why this composition

| Requirement | Choice | Rationale |
| --- | --- | --- |
| Self-host HyperFrames | **HyperFrames CLI** + **Kinocut** | HeyGen’s MCP at `mcp.heygen.com` is **cloud-only**. OSS HyperFrames is the renderer; Kinocut is a battle-tested MCP with 18 HyperFrames tools. |
| MCP OAuth + Google Testing allowlist | **sigbit/mcp-auth-proxy** | Drop-in OAuth 2.1/DCR/PKCE for MCP; native `--google-allowed-users`. |
| Host isolation | **Funnel only on VM** | Darwin never opens inbound or Funnel; admin path is outbound Tailscale if needed. |
| Reverse proxy | **Caddy** | Minimal config, SSE-friendly `flush_interval -1`. |
| Dual delivery | **Terranix + public tree** | Nix is source of truth; `hf-export` emits a plain GitHub-ready repo with `install.sh`. |

## Paths in this flake

| Path | Role |
| --- | --- |
| `infra/hyperframes/stack.nix` | Terranix module → `config.tf.json` |
| `packages/hyperframes-selfhost/` | Public install tree (compose, Dockerfile, install.sh, terraform) |
| `packages/hyperframes-selfhost.nix` | `hf-export` / `hf-apply` / `hf-doctor` apps |
| `docs/hyperframes-selfhost-test-plan.md` | Verification plan |

## Operator flow (Nix / Darwin)

```bash
# 1) Export the public tree (safe to publish as its own GitHub repo)
nix run .#hf-export -- ./dist/hyperframes-selfhost

# 2) Copy to the Linux VM
rsync -a ./dist/hyperframes-selfhost/ user@hyperframes-vm:~/hyperframes-selfhost/

# 3) On the VM — interactive one-command install
ssh user@hyperframes-vm 'cd ~/hyperframes-selfhost && ./install.sh'
```

Or fully non-interactive on the VM after export:

```bash
export TF_VAR_ts_authkey=…
export TF_VAR_google_client_id=…
export TF_VAR_google_client_secret=…
export TF_VAR_external_url=https://hyperframes.<tailnet>.ts.net
export TF_VAR_google_allowed_users=ismail@kattakath.com
export HF_STACK_DIR=~/hyperframes-selfhost
nix run github:kattakath/nix-config#hf-apply
```

## Non-Nix flow (public repo)

```bash
git clone https://github.com/kattakath/hyperframes-selfhost.git
cd hyperframes-selfhost
./install.sh
```

## Google OAuth (Testing mode)

1. Create a **Web** OAuth client.
2. Redirect URI: `https://<vm-magicdns>.ts.net/.auth/google/callback`
3. Publishing status: **Testing**.
4. Add the same emails as **Test users** and as `GOOGLE_ALLOWED_USERS`.

## MCP client URL

```
https://<vm-magicdns>.ts.net/mcp
```

## Security boundaries

- Secrets only in VM `.env` / TF variables / Keychain on the Mac for export automation — never in Nix store literals.
- Funnel is the only public ingress; deny by stopping Funnel or the tailscale service.
- Email allowlist is enforced by mcp-auth-proxy independent of Google Testing.

## Related

- Existing Mac MCP OAuth (Cloudflare Access Managed OAuth): [`docs/mcp-connector-oauth-runbook.md`](./mcp-connector-oauth-runbook.md) — different trust domain (kapture on Darwin). This HyperFrames stack deliberately uses **Tailscale Funnel + mcp-auth-proxy** on a VM instead.
- Test plan: [`docs/hyperframes-selfhost-test-plan.md`](./hyperframes-selfhost-test-plan.md)
