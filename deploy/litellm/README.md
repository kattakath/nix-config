# LiteLLM proxy — dedicated tunnel + Cloudflare Access + Google SSO

Runs the LiteLLM OpenAI-compatible proxy as its own container behind a
**dedicated** remotely-managed Cloudflare Tunnel at `litellm.kattakath.com`,
fronted by **Cloudflare Access**. Access decides who reaches the origin at all;
past Access the proxy authenticates two audiences differently:

- **Humans** log in to the **Admin UI** with **Google Workspace SSO**
  (`@kattakath.com`). They never see the master key.
- **API clients** authenticate with per-key **virtual keys** issued from the
  Admin UI — *not* the shared master key. The master key stays **server-only**.

The Admin UI, virtual keys, spend tracking and the SSO user table all require a
database, so the stack now also runs a **Postgres** container (internal-only,
named volume for persistence).

## Auth model — three checkpoints

| Checkpoint | Humans (browser) | API clients (programmatic) |
|---|---|---|
| 1. Cloudflare Access | Google login, allowed if `@kattakath.com` | service token headers `CF-Access-Client-Id` / `CF-Access-Client-Secret` |
| 2. Reach LiteLLM | — | — |
| 3. LiteLLM auth | LiteLLM Google SSO (`/sso/callback`), restricted to `kattakath.com` | `Authorization: Bearer <virtual-key>` |

The **master key** (`LITELLM_MASTER_KEY`) is never distributed. It exists only so
the server can bootstrap and mint virtual keys; humans use SSO and clients use
virtual keys. This is strictly safer than handing out the master key.

### Cloudflare Access ↔ LiteLLM Google SSO

LiteLLM runs its own Google OAuth login and, on success, Google redirects the
browser to `https://litellm.kattakath.com/sso/callback`. That redirect is a
normal browser navigation to the Access-protected hostname, so it must **first
clear Cloudflare Access**. The clean way to make it survive Access is the
**Access allow policy scoped to the `kattakath.com` email domain**
(`email_domain = { domain = "kattakath.com" }`): the user authenticates to Access
with Google once, and — already being an `@kattakath.com` identity — sails straight
through to LiteLLM's own SSO. Both layers gate on the *same* Workspace domain
(Access via the email-domain policy, LiteLLM via `ALLOWED_EMAIL_DOMAINS`), so
they can never disagree.

> **Why not a path bypass?** You *could* add an Access `bypass` policy on
> `/sso/*`, but a bypass punches an **unauthenticated hole** in Access for that
> path — anyone on the internet could hit the callback endpoint. The
> email-domain allow keeps Access default-deny end-to-end (defense in depth) and
> is the recommended policy. We do **not** use a bypass.

This is the **HTTP-ingress + Access** container path — distinct from the per-host
**SSH connector** model in `scripts/cf-one-provision.sh` /
`docs/tunnel-architecture-and-runbook.md` (which is SSH-only, one tunnel per
NixOS host, no Access). Here the tunnel ingress is an HTTP service resolved by
**docker-DNS name** (`http://litellm:4000`) from inside the connector's network
namespace, and an Access self-hosted app sits in front of the public hostname.

## Layout

```
deploy/litellm/
├── docker-compose.yml   GENERATED — rendered from packages/litellm-compose.nix
│                        (litellm + postgres + cloudflared, shared internal net,
│                         no host port)
├── .env.example         copy -> .env (gitignored), fill in keys/DB/SSO/token
└── README.md            this runbook
infra/cloudflare/litellm.nix      terranix account-side provisioning (OpenTofu)
packages/litellm-compose.nix      Nix source that renders docker-compose.yml
packages/litellm-image.nix        the nix-built litellm:latest image
```

`docker-compose.yml` is **not hand-written** — it is rendered from
`packages/litellm-compose.nix` (via `pkgs.formats.yaml`) with
`nix build .#packages.<system>.litellmCompose`. The Cloudflare account side is
provisioned declaratively by the terranix module `infra/cloudflare/litellm.nix`,
applied with `nix run .#cf-litellm-apply` (OpenTofu) — there is no imperative
provisioning shell script.

## Runbook

### Step 0 — Google OAuth client (one-time, already done)

A Google Cloud **OAuth 2.0 Web** client exists in project `kattakath-family`
with:

- **Authorized redirect URI**: `https://litellm.kattakath.com/sso/callback`
- **Authorized JavaScript origin**: `https://litellm.kattakath.com`

Its `client_id` / `client_secret` are already recorded in `deploy/litellm/.env`
(the client_id is public; the secret is gitignored). If you ever rotate the
client, update `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in `.env` and keep the
redirect URI exactly as above — LiteLLM's callback path is fixed at
`/sso/callback` and is derived from `PROXY_BASE_URL`.

### Step 1 — build + load the image (any Docker host)

```bash
# from the repo root:
nix build .#packages.x86_64-linux.litellmImage
docker load < result          # -> litellm:latest
```

(Use `.#packages.aarch64-linux.litellmImage` on an arm64 Docker host.)

### Step 2 — provision the Cloudflare side (needs the user's live CLOUDFLARE_API_TOKEN)

Everything in this step is account-side and **must be run by the operator with a
live token**. Provisioning is Nix-native via **terranix** — the module
`infra/cloudflare/litellm.nix` is rendered to OpenTofu config and applied by the
flake app `cf-litellm-apply`. The token needs, on this account/zone:

- Account : Cloudflare Tunnel : Edit
- Zone : DNS : Edit (kattakath.com)
- Account : Access: Apps and Policies : Edit
- Account : Access: Service Tokens : Edit

```bash
# from the repo root:
CLOUDFLARE_API_TOKEN=… nix run .#cf-litellm-apply
```

This renders `infra/cloudflare/litellm.nix` and runs `tofu init` + `tofu apply`,
writing OpenTofu state (gitignored) into the current working directory. It is
declarative (OpenTofu reconciles to the desired state — re-run to converge).

Then read the secrets back from the OpenTofu outputs (they are marked
`sensitive`, so plain `tofu output` masks them — use `-raw`):

```bash
tofu output -raw tunnel_token                 # -> TUNNEL_TOKEN
tofu output -raw service_token_client_id      # -> CF-Access-Client-Id
tofu output -raw service_token_client_secret  # -> CF-Access-Client-Secret
```

### Step 3 — fill in .env

`.env` is gitignored; never commit it. `GOOGLE_CLIENT_ID` /
`GOOGLE_CLIENT_SECRET` are already populated. Fill the rest:

```bash
# (if starting fresh)  cp deploy/litellm/.env.example deploy/litellm/.env
# edit deploy/litellm/.env and set:
#   OPENAI_API_KEY        your OpenAI key
#   LITELLM_MASTER_KEY    strong random (openssl rand -hex 32) — SERVER-ONLY
#   POSTGRES_PASSWORD     strong random (openssl rand -hex 24)
#   DATABASE_URL          postgresql://litellm:<that-password>@postgres:5432/litellm
#   TUNNEL_TOKEN          from `tofu output -raw tunnel_token`
#   CF_ACCESS_CLIENT_ID   from `tofu output -raw service_token_client_id`
# already set: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, PROXY_BASE_URL,
#             ALLOWED_EMAIL_DOMAINS=kattakath.com
# leave PROXY_ADMIN_ID blank for now (set it after first login — Step 6).
```

`DATABASE_URL` must embed the SAME password as `POSTGRES_PASSWORD`, and its host
is the docker-DNS name `postgres` (the compose service).

### Step 4 — render the compose file

The compose file is Nix-rendered from `packages/litellm-compose.nix`; build it,
then either copy it into `deploy/litellm/` or run it in place:

```bash
# from the repo root:
nix build .#packages.<system>.litellmCompose   # -> ./result (a docker-compose.yml)
cp result deploy/litellm/docker-compose.yml     # option A: copy it in
# — or run it directly without copying:
docker compose -f result up -d                  # option B: run from ./result
```

(Use the appropriate `<system>` for your Docker host, e.g.
`x86_64-linux` or `aarch64-linux`.)

### Step 5 — start it

```bash
cd deploy/litellm
docker compose up -d                  # if you copied result here (Step 4, option A)
docker compose logs -f postgres       # wait for "database system is ready"
docker compose logs -f litellm        # LiteLLM runs DB migrations automatically on boot
docker compose logs -f cloudflared    # watch the connector register
```

Compose starts `postgres` first and only starts `litellm` once Postgres reports
healthy (`depends_on: service_healthy`). LiteLLM runs its Prisma **schema
migrations automatically on first boot** against `DATABASE_URL` — there is no
separate one-shot migration command to run. (If you ever need to force it
manually: `docker compose exec litellm litellm --config <path> --use_prisma` is
not required in normal operation.)

The proxy is now reachable at `https://litellm.kattakath.com` — through Access.

### Step 6 — first login becomes admin

1. In a browser, go to `https://litellm.kattakath.com/ui`.
2. Cloudflare Access prompts you to log in with Google — sign in with your
   `@kattakath.com` account (the email-domain allow policy lets you through).
3. LiteLLM's own Google SSO then runs and redirects back via `/sso/callback`.
   `ALLOWED_EMAIL_DOMAINS=kattakath.com` means only Workspace users can complete it.
4. You are now logged in. Open your user in the UI and copy your **`user_id`**.
5. Set it in `.env`:
   ```bash
   # deploy/litellm/.env
   PROXY_ADMIN_ID=<your-user_id-from-the-UI>
   ```
6. Restart just the proxy so the role is applied:
   ```bash
   docker compose up -d litellm       # picks up PROXY_ADMIN_ID
   ```
   Your role is now `proxy_admin`. Subsequent `@kattakath.com` SSO users are created
   as normal internal users (adjust their roles/teams from the Admin UI).

### Step 7 — issue virtual keys for API clients

Humans use SSO; **programs use virtual keys**, never the master key.

- In the Admin UI: **Virtual Keys → + Create New Key**. Scope it (models, budget,
  rpm/tpm, optional team), then copy the generated `sk-…` key once.
- Or via the API (admin only, using the master key server-side):
  ```bash
  curl https://litellm.kattakath.com/key/generate \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"models":["gpt-4o"],"max_budget":50,"duration":"30d"}'
  # -> {"key":"sk-…"}  hand THIS to the client, not the master key
  ```

Each client gets its own revocable, budgeted key. Revoke from the UI or
`/key/delete` without touching anyone else.

## Calling the proxy as an API client (through Access)

Two auth layers on every request — Access, then a **virtual key** (not the
master key):

- `CF-Access-Client-Id` + `CF-Access-Client-Secret` — the Access service token
  (gets you past Access)
- `Authorization: Bearer <virtual-key>` — a per-client virtual key issued in
  Step 7 (gets you past the proxy). The master key is NEVER distributed.

### curl

```bash
curl https://litellm.kattakath.com/v1/chat/completions \
  -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
  -H "Authorization: Bearer ${LITELLM_VIRTUAL_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"ping"}]}'
```

### OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm.kattakath.com",
    api_key=LITELLM_VIRTUAL_KEY,              # a virtual key, NOT the master key
    default_headers={
        "CF-Access-Client-Id": CF_ACCESS_CLIENT_ID,
        "CF-Access-Client-Secret": CF_ACCESS_CLIENT_SECRET,
    },
)

resp = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "ping"}],
)
print(resp.choices[0].message.content)
```

For a **browser** (dashboard) session, the Access email-domain policy lets any
`@kattakath.com` user log in via Google, then LiteLLM's own Google SSO runs behind
it — no service token needed.

## Security notes

- **Access fronts everything.** No request reaches litellm without either the
  service token (API clients) or an allowed Google login (browser). Access is
  default-deny; the browser policy is scoped to the `kattakath.com` email domain.
- **Master key stays server-only.** It is never distributed. Humans log in via
  Google SSO; API clients present a per-client **virtual key**. The proxy rejects
  any API request without a valid `Authorization: Bearer <key>` (virtual key or,
  server-side only, the master key).
- **SSO restricted to the Workspace.** `ALLOWED_EMAIL_DOMAINS=kattakath.com` inside
  LiteLLM and the Access email-domain policy both gate on the same domain.
- **No secrets in git.** Provider keys, master key, Postgres password /
  `DATABASE_URL`, Google client secret, tunnel token, and Access service-token
  secret live only in `deploy/litellm/.env` (gitignored) or the client's own
  secret store — never in a tracked file. The terranix apply keeps secrets in
  OpenTofu state (gitignored) and surfaces them only via `tofu output -raw`.
- **No host port.** Neither the litellm nor the postgres container publishes
  anything to the host; both are internal-only and the cloudflared connector on
  the shared network is the sole ingress. Postgres data persists in the named
  volume `litellm-pgdata`.
- **Teardown.** `nix run .#cf-litellm-destroy` runs `tofu destroy`, tearing down
  the tunnel, DNS record, Access application/policies, and service token in the
  Cloudflare account.

## Which Docker host

Any. The tunnel is **outbound-only**, so no inbound firewall rule, no
port-forward, and no public IP are required on the host — Access + the tunnel
make the deployment host- and location-independent. Pick whatever Docker host is
convenient (a NixOS box, a cloud VM, a laptop) and run the same runbook steps.
