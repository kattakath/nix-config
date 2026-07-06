# ZTIA SSH Rollout Runbook — `nixpi` (Cloudflare Access for Infrastructure)

> Complements [`docs/tunnel-architecture-and-runbook.md`](tunnel-architecture-and-runbook.md)
> (the generic ZTIA design + condensed rollout order in its §9). This document
> is the concrete, step-by-step operator walkthrough for executing that
> rollout on this account — same order, same rules, more detail. Nothing here
> contradicts that doc; read it first for the "why," then use this as the
> "how."

**Account ID**: `<ACCOUNT_ID>` — find via: Cloudflare dashboard → any zone →
right sidebar **API** panel, or `https://dash.cloudflare.com/<ACCOUNT_ID>`
in the URL bar once a zone/account is selected; also returned by
`GET /accounts` with a scoped API token.
**Zone**: `kattakath.com` (`<KATTAKATH_ZONE_ID>`) — find via: dashboard →
select the `kattakath.com` zone → right sidebar **API** panel, or
`GET /zones?name=kattakath.com`.
**Zero Trust org / team domain**: `kattakath.cloudflareaccess.com` — find via:
Zero Trust dashboard → **Settings** → **Custom Pages** (or the login URL
shown at first Zero Trust setup); the team name portion is whatever you chose
when the org was created.
**Existing tunnel to reuse**: `nixrpi` — id `<NIXPI_TUNNEL_ID>` (healthy, 4
conns, ingress today is bare `ssh://localhost:22`) — find via: Zero Trust
dashboard → **Networking** → **Tunnels**, or
`GET /accounts/<ACCOUNT_ID>/cfd_tunnel` and match by name.
**Repo**: `/Users/aloshy/ismailkattakath/nix-config` (branch `main`,
greenfield fleet rewrite)

This is a documentation-only runbook. Nothing in it was executed by the agent
that wrote it — no Cloudflare object was created/modified, no file in the repo
was edited. Follow it yourself, in order. Do not skip ahead to step 7
(static-key removal) before step 6 (verified login) — that is the one hard
lockout risk in the whole plan.

---

## 0. What you're building

`nixpi` already has a working, loginless SSH path: a Cloudflare Tunnel
connector (`modules/nixos/cloudflared.nix`, token-based, unchanged by any of
this) carrying `ssh://localhost:22`, authenticated today by a single static
ed25519 key baked into `modules/nixos/core.nix`. ZTIA adds an identity +
short-lived-certificate layer **on top of the same tunnel** — it does not
replace the connector. When you're done: a WARP-enrolled Mac authenticates via
your identity provider, Cloudflare's hosted SSH CA mints a short-lived cert
scoped to UNIX user `ismail`, and `nixpi`'s sshd trusts that CA via
`TrustedUserCAKeys`. The static key is removed only at the very end, and only
after the cert path is proven to work.

---

## 1. PREREQUISITES

### 1a. Fix the API token scope gap

Read-only reconnaissance often finds that
`GET /accounts/{acct}/access/gateway_ca` and
`GET /accounts/{acct}/infrastructure/targets` both fail with `Authentication
error (code 10000)` while every other Access-family call succeeds with the
same token. Per current Cloudflare docs this is a distinct token permission,
separate from `Access: Apps and Policies`:

> Required API token permissions: at least one of `Access: SSH Auditing
> Write` / `Access: SSH Auditing Read`

**Fix — mint or edit a token with this scope:**

1. Dashboard → **My Profile** → **API Tokens**
   (`https://dash.cloudflare.com/profile/api-tokens`).
2. **Create Token** → scroll down → **Create Custom Token**.
3. Name it something like `nixpi-ztia-provisioning`.
4. Under **Permissions**, add:
   - **Account** → **Access: SSH Auditing** → **Edit** (Edit covers both
     generating the CA and reading it back; Read alone is not enough to
     create it).
   - **Account** → **Access: Apps and Policies** → **Edit** (needed for the
     Infrastructure Access application + policy).
   - **Account** → **Zero Trust** → **Edit** (covers the
     `cloudflare_zero_trust_infrastructure_access_target` resource itself;
     this is the scope `flake.nix`'s own comment on `cf-ssh-apply` already
     documents: "Account Zero Trust:Edit").
5. Under **Account Resources**, scope to this one account (or "All accounts"
   if that's your only account).
6. **Continue to summary** → **Create Token**. Copy the secret immediately —
   it is shown once.
7. Export it in your shell for later steps — **never** put it in Nix, git, or
   argv:
   ```bash
   export CLOUDFLARE_API_TOKEN='<paste-token-here>'
   ```

### 1b. Enroll `macos` in WARP / Cloudflare One Client

ZTIA SSH via the Cloudflare One Client requires the client device (`macos`,
per `hosts/macos.nix` — client only, no server modules) to be WARP-enrolled
*before* any login test can happen. Confirm device enrollment status first via
dashboard: **Zero Trust** → **Team & Resources** → **Devices**.

1. Download the **Cloudflare One Client** (formerly WARP) for macOS:
   `https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/download/`
   — grab the current stable `.pkg` for macOS (arm64/Apple Silicon build; this
   fleet is aarch64-only end to end).
2. Install it, launch it, and when prompted for your **team domain**, enter
   the team name portion of your Zero Trust team domain (e.g. `kattakath` for
   `kattakath.cloudflareaccess.com`).
3. Authenticate via your IdP. Find out which IdP(s) are configured via:
   dashboard → **Zero Trust** → **Settings** → **Authentication** →
   **Login methods** (each entry shows its type and an id, e.g.
   `<GOOGLE_IDP_ID>` for a Google Workspace connection); the built-in
   Cloudflare one-time-PIN IdP is always available as a fallback. Sign in
   with your Workspace identity.
4. Confirm enrollment succeeded — dashboard: **Zero Trust** → **Team &
   Resources** → **Devices**. You should now see this Mac listed.
5. Set the client to **Traffic and DNS** mode (check the device profile:
   **Zero Trust** → **Settings** → **WARP Client** → **Device settings
   profiles** → default profile — confirm `service_mode_v2.mode = "warp"`;
   if it shows `tunnel_protocol = "masque"` or similar, no profile edit
   should be needed, just confirm the client itself is in this mode, not
   "Gateway with DoH" / DNS-only).

**Also check — `allow_authenticate_via_warp`:** live Access org settings
(`GET /accounts/{acct}/access/organizations`) may show
`allow_authenticate_via_warp: false`. This flag governs whether Access
applications can authenticate a session using the WARP device identity
instead of a fresh browser/IdP prompt. For Infrastructure (ZTIA) SSH apps this
may or may not matter — the infra-target flow can authenticate differently
than browser SSO — but flip it to confirm if step 6 (end-to-end verify) stalls
on an unexpected auth prompt:

- Dashboard: **Zero Trust** → **Settings** → **Authentication** → look for
  "Enable Auth via Warp to Apps" (or equivalent wording) → toggle on → Save.

Treat this as a **fallback to check**, not a required prerequisite — verify
step 6 first before touching it.

---

## 2. GENERATE / CONFIRM THE SSH CA

There is no Terraform resource for the CA itself — this is dashboard/API
only, and it's idempotent (a second POST returns
`access.api.error.gateway_ca_already_exists` rather than creating a second
CA).

**Dashboard (one-click, current UI as of the Nov 2025 changelog):**

1. **Zero Trust** → **Access controls** → **Service credentials** → **SSH**.
2. Select **Add a certificate**.
3. Under **SSH with Access for Infrastructure**, select **Generate SSH CA**.
   A new row appears in the short-lived certificates table:
   **SSH with Access for Infrastructure**.
4. Select that row.
5. Copy the **CA public key** shown. You can return to this page to copy it
   again at any time — it is not a one-time reveal like an API token secret.

**API equivalent** (needs the `Access: SSH Auditing` Edit-scoped token from
step 1a):

```bash
# If no CA exists yet:
curl "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/access/gateway_ca" \
  --request POST \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN"

# If one already exists (or the POST above returns
# access.api.error.gateway_ca_already_exists), fetch it instead:
curl "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/access/gateway_ca" \
  --request GET \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
```

Either path returns a `public_key` field — that is the value you need next.

**IMPORTANT — run this BEFORE assuming none exists.** A read-only
reconnaissance pass without the properly-scoped token cannot determine
whether a CA already exists on the account (the scope gap in 1a masks it).
Once you have the properly-scoped token, `GET` first. If one already exists,
do not generate a second — just copy the existing public key.

### Commit the real CA public key

Replace the placeholder in the repo:

```bash
cd /Users/aloshy/ismailkattakath/nix-config
```

Edit `modules/nixos/cloudflare-ssh-ca.pub` — replace the entire placeholder
line with the real `public_key` value copied above, keeping the same one-line
`ssh-<type> <base64> <comment>` format. Leave the explanatory comment block
above it as-is (it documents that this is safe to commit — it's a public key,
and the file is intentionally the hand-filled exception to the "no terranix
for the CA" rule).

```bash
git add modules/nixos/cloudflare-ssh-ca.pub
```

Do **not** commit this without also staging it — `git-purity` rules in this
repo require every `.nix`/tracked file to be staged before any `nix flake
check`/eval pass (this file isn't `.nix`, but stage it anyway for a clean
diff before the next step touches `hosts/nixpi.nix`/`infra/`).

---

## 3. FILL THE PLACEHOLDERS IN `infra/cloudflare/nixpi-ssh.nix`

Read the file's own header comment — it already documents each gap. Here is
the exact list of placeholders/TODOs and what to put in each:

| Field | Current value | What it is | Where to get the real value |
|---|---|---|---|
| `targetIp` | `"192.0.2.10"` (RFC 5737 documentation IP — obviously fake) | The private IP the Infrastructure Access **target** points at; must be reachable through a **Tunnel CIDR route** bound to the `nixrpi` connector | See §3a below — you likely need to create this route first, then use the IP you routed |
| `virtualNetworkId` | `"00000000-0000-0000-0000-000000000000"` (all-zero placeholder) | The virtual network the above route lives in | Dashboard: **Networking** → **Routes** → **Virtual networks**. If none exists yet, either create one or use the account's `default` network's ID (see §3a) |
| `targetHostname` | `"nixpi"` | Label only, NOT used for DNS resolution — this does **not** need to match a live DNS record | Already correct — no change needed |
| `sshPort` | `22` | SSH port on the target | Already correct — no change needed |
| `allowEmailDomain` | `"kattakath.com"` | Your Workspace domain, matches the repo's existing `email_domain` convention | Already correct — no change needed |
| `sshUsername` | `"ismail"` | Must match `users.users.${userName}` on `hosts/nixpi.nix` (via `userName` from `flake.nix`) | Already correct — no change needed |

Only **two values actually need filling in**: `targetIp` and
`virtualNetworkId`. Everything else in the file is already correct for this
account.

### 3a. The Tunnel CIDR route almost certainly does not exist yet — create it first

Reconnaissance against a fresh account typically finds none of the live
tunnels have `warp-routing.enabled: true`, and `nixrpi`'s current ingress
config is a bare `version: 1` SSH-only rule (`ssh://localhost:22` + 404
catch-all) — no private-network routing configured on it at all.

Per current docs, the Infrastructure Access target model wants a private IP
reachable via a **Tunnel CIDR route bound to the same tunnel** the connector
runs (here, `nixrpi`, id `<NIXPI_TUNNEL_ID>`). To add one:

1. Dashboard: **Networking** → **Routes**
   (`https://dash.cloudflare.com/?to=/:account/magic-networks/routes`).
2. Select **Create route** → **Tunnel CIDR**.
3. Select the tunnel **`nixrpi`** (the one with id `<NIXPI_TUNNEL_ID>`).
4. In **Network**, enter the private IP or CIDR you want routed. For a single
   host target like this, a `/32` of `nixpi`'s actual private/LAN IP is the
   simplest choice — e.g. if `nixpi`'s LAN IP is `192.168.1.50`, enter
   `192.168.1.50/32`. **Find nixpi's real LAN IP first**:
   ```bash
   ssh ismail@nixpi.local 'ip -4 addr show | grep inet'
   ```
   (mDNS/`nixpi.local` still works over the LAN today regardless of ZTIA
   status — this is the zero-cloud path to query the host directly.)
5. **Virtual network** dropdown: if this is your first route, there is
   likely no custom virtual network yet — you can either leave this blank
   (assigns to the account's implicit `default` network) or create one first
   (**Networking** → **Routes** → **Virtual networks** → **Create virtual
   network**, e.g. name it `home-lan`). A named VNet is only *required* if
   this route's CIDR overlaps another route in the account — for a single-Pi
   home fleet, `default` is simplest.
6. Select **Create route**.
7. Note the **virtual network ID** shown for the route you just created (or,
   if you used `default`, fetch it via API:
   ```bash
   curl "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/teamnet/virtual_networks" \
     --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq
   ```
   — this lists all virtual networks on the account, including `default`,
   with their UUIDs).

Now fill in the two placeholders in `infra/cloudflare/nixpi-ssh.nix`:

```nix
targetIp = "192.168.1.50";  # nixpi's actual LAN IP, matching the route created above
virtualNetworkId = "<uuid-from-step-7>";
```

(Replace `192.168.1.50` with whatever `ip -4 addr show` on `nixpi` actually
reported.)

```bash
git add infra/cloudflare/nixpi-ssh.nix
```

### 3b. About the `nixrpi` → `nixpi` rename

The tunnel may still be named `nixrpi` (pre-rename era) even though the
repo's host is `nixpi`. This is purely cosmetic — the connector authenticates
by token/UUID, not by name, so renaming is non-disruptive:

```bash
curl "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/cfd_tunnel/<NIXPI_TUNNEL_ID>" \
  --request PATCH \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"name": "nixpi"}'
```

Optional, can be done any time before/after the rest of this runbook — it
does not block `cf-ssh-apply` (the terranix file's `targetHostname = "nixpi"`
is just a label on the Access target, unrelated to the tunnel's own name).

---

## 4. PROVISION — `nix run .#cf-ssh-apply`

Once §3's placeholders are real values and staged:

```bash
cd /Users/aloshy/ismailkattakath/nix-config
git add -A   # git-purity: stage everything before any flake evaluation
CLOUDFLARE_API_TOKEN=<your-scoped-token-from-1a> nix run .#cf-ssh-apply
```

This renders `infra/cloudflare/nixpi-ssh.nix` via terranix and runs
`tofu init` + `tofu apply` (see `mkCfSshTofu` in `flake.nix`). It creates
exactly three Cloudflare objects:

1. **`cloudflare_zero_trust_infrastructure_access_target.nixpi`** — the
   target object (hostname label `nixpi`, the IP + VNet from §3a).
2. **`cloudflare_zero_trust_access_application.nixpi_ssh`** — an
   Infrastructure Access application (name `"nixpi SSH (ZTIA)"`), gating
   SSH/22 against that target.
3. **`cloudflare_zero_trust_access_policy.nixpi_ssh_allow`** — the Allow
   policy: `email_domain = kattakath.com`, `connection_rules.ssh.usernames =
   ["ismail"]`.

### Verify each was created

**Dashboard:**
- **Zero Trust** → **Access controls** → **Applications** → look for
  **"nixpi SSH (ZTIA)"** with type **Infrastructure**.
- Select it → **Policies** tab → confirm the Allow policy with your
  email domain and SSH username `ismail` under **Connection rules**.
- **Zero Trust** → look for an **Infrastructure** / **Targets** view (exact
  nav label may vary by dashboard version) and confirm `nixpi` appears as a
  target.

**API:**
```bash
curl "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/access/apps" \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result[] | select(.type=="infrastructure")'

curl "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/infrastructure/targets" \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq
```
(The second call is the one that 401s without the §1a scope fix — if it
still fails here, your token from step 1a is missing a needed permission;
re-check the `Access: SSH Auditing` grant.)

### Terraform provider schema risk — what to check if `tofu apply` rejects a field

The `cloudflare_zero_trust_infrastructure_access_target` resource schema
should be cross-checked against current provider docs before relying on it.
As of writing, the schema is:

```hcl
resource "cloudflare_zero_trust_infrastructure_access_target" "infra-ssh-target" {
  account_id = var.cloudflare_account_id
  hostname   = "infra-access-target"
  ip = {
    ipv4 = {
      ip_addr            = "187.26.29.249"
      virtual_network_id = "c77b744e-acc8-428f-9257-6878c046ed55"
    }
  }
}
```

This confirms `infra/cloudflare/nixpi-ssh.nix`'s `ip.ipv4.ip_addr` +
`ip.ipv4.virtual_network_id` shape. If `tofu apply` still rejects a field:

1. Check the exact error — `tofu` reports the offending attribute path
   directly (e.g. `Unsupported argument: "virtual_network_id"`).
2. Cross-check the live Terraform Registry page for the pinned provider
   version actually resolved by `tofu init` (look at `.terraform.lock.hcl`
   after init, or the `tofu init` output) at:
   `https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_infrastructure_access_target`
3. A provider major-version bump is the most likely source of drift — the
   schema shape has historically been stable across the v4→v5 provider
   transition for this specific resource, but re-verify against whatever
   version `tofu init` actually pins.
4. If a field genuinely doesn't exist in your resolved provider version, pin
   an older/newer `cloudflare/cloudflare` version in the
   `terraform.required_providers.cloudflare.version` line in
   `infra/cloudflare/nixpi-ssh.nix` and re-run `tofu init -upgrade`.

---

## 5. ACTIVATE ON `nixpi` — rebuild so sshd trusts the CA

`hosts/nixpi.nix` already sets `services.openssh-ca-trust.enable = true` and
keeps `services.cloudflared-connector.enable = true` untouched. Once §2's
real CA public key is committed and staged, rebuild:

```bash
cd /Users/aloshy/ismailkattakath/nix-config
git add -A   # git-purity: stage everything before eval
nix flake check   # sanity check both systems evaluate before touching the live Pi
ssh ismail@nixpi.local 'sudo nixos-rebuild switch --flake github:ismailkattakath/nix-config#nixpi'
```

(Using `nixpi.local` mDNS over the LAN — or your existing static-key path —
for this rebuild, since ZTIA isn't verified yet. Do not rely on any
not-yet-proven ZTIA path to reach the host for this step.)

This activates:
```nix
services.openssh.extraConfig = ''
  TrustedUserCAKeys ${caCfg.caKeyFile}   # -> modules/nixos/cloudflare-ssh-ca.pub, now real
'';
```
The static key stays in place — `removeStaticKey` is still `false` by
default. Both auth paths now coexist.

**Live-verify note** (carried from `docs/tunnel-architecture-and-runbook.md`
§5/§11, still unconfirmed until you do this): NixOS renders `extraConfig`
after `settings`, and there's no competing `AuthorizedKeys*`/
`AuthorizedPrincipals*` directive in `modules/nixos/core.nix` — so
`TrustedUserCAKeys` is expected to take effect cleanly, but this specific
rebuild is the first real-world confirmation of that.

---

## 6. VERIFY END-TO-END

With the Mac enrolled in WARP (step 1b) and the CA + Access app + policy live
(steps 2–4) and `nixpi` rebuilt (step 5):

1. Confirm the target is visible from the client:
   ```bash
   warp-cli target list
   ```
   (or the equivalent view in the Cloudflare One Client GUI). You should see
   `nixpi` listed.

2. Plain SSH — **no ProxyCommand, no `cloudflared access ssh` wrapper** —
   WARP intercepts transparently once enrolled and the route is live:
   ```bash
   ssh ismail@<nixpi-private-ip>   # the targetIp you set in §3a
   ```
   You should be prompted through your IdP session if not already
   authenticated, then land in a shell as `ismail`.

3. **Confirm this succeeded via certificate, not the static key** — do one
   of:
   - Temporarily remove/unload `~/.ssh/id_ed25519` from your local
     `ssh-agent` (`ssh-add -d ~/.ssh/id_ed25519` or start a clean agent) and
     retry the `ssh` command above — if it still logs in, it's the cert path.
   - Or, on `nixpi`, tail the auth log during the attempt:
     ```bash
     ssh ismail@nixpi.local 'sudo journalctl -u sshd -f'
     ```
     and look for a certificate-based accept line (mentions "certificate" /
     the CA fingerprint) rather than a plain public-key accept line.

4. Confirm the session is audited: Dashboard → **Zero Trust** → **Insights**
   → **Logs** → **Access authentication logs** → filter App Type =
   *Infrastructure* → find your login → **Decision** should read `Access
   granted`. (Optional deeper SSH command audit — HPKE-encrypted logs,
   downloadable from **Access controls** → **Service credentials** → **SSH**
   — is a separate, all-plans-available feature; Logpush export to
   SIEM/S3 is Enterprise-only, irrelevant for a solo operator.)

**Do not proceed to step 7 until this entire section passes.**

---

## 7. CUTOVER — drop the static key (ONLY after step 6 passes)

Edit `hosts/nixpi.nix`:

```nix
services.openssh-ca-trust.enable = true;
services.openssh-ca-trust.removeStaticKey = true;   # ADD this line
```

Then:

```bash
cd /Users/aloshy/ismailkattakath/nix-config
git add -A
nix flake check
ssh ismail@nixpi.local 'sudo nixos-rebuild switch --flake github:ismailkattakath/nix-config#nixpi'
```

**Do this rebuild while you still have a working session** (either the
already-open SSH session from step 6, or the LAN/static-key path) — don't
close your only connection before confirming the new generation booted
sshd correctly.

From this point, `nixpi`'s network SSH is ZTIA-cert-only. The static key
(`<static-ed25519-key>` — find the exact value currently deployed via:
`modules/nixos/core.nix`'s `users.users.${userName}.openssh.authorizedKeys.keys`,
or `ssh-keygen -lf` against the local private key it pairs with) is removed
from `authorizedKeys` — anyone who had it can no longer use it.

**Physical console is the permanent break-glass path, unaffected by any of
this.** `services.avahi`/mDNS (`nixpi.local`) and `serial-getty` remain up
regardless of ZTIA/static-key status — this option only ever touches
`authorizedKeys`, never the getty.

### Rollback — if you get locked out

If ZTIA breaks (Cloudflare outage, misconfigured policy, WARP client issue)
**after** the static key is already removed:

1. **Physical console**: attach a keyboard/monitor (or serial console cable)
   directly to the Pi. Log in as `ismail` locally — this never depended on
   sshd, the tunnel, or Cloudflare at all.
2. From that local session, revert `hosts/nixpi.nix`:
   ```nix
   services.openssh-ca-trust.removeStaticKey = false;   # or delete the line
   ```
3. Rebuild locally on the Pi itself:
   ```bash
   cd /path/to/nix-config-checkout-on-the-pi   # or re-clone if needed
   sudo nixos-rebuild switch --flake .#nixpi
   ```
   (If the Pi doesn't have a local checkout, you may need to re-clone the
   repo over the LAN/console session first, or use `nixpi.local` mDNS from
   another LAN device once console access confirms the box is otherwise
   healthy.)
4. This restores the static key immediately; SSH over the LAN/tunnel resumes
   working with the old key while you debug the ZTIA path.

**Faster mitigation without touching Nix at all**: if the SSH path itself is
fine but the *Access policy* is the problem (e.g. IdP misconfigured, policy
too narrow), you can fix this purely on the Cloudflare side — edit or disable
the policy in the dashboard (**Access controls** → **Applications** →
**"nixpi SSH (ZTIA)"** → **Policies**) or via `nix run .#cf-ssh-destroy` +
re-`apply` after fixing `infra/cloudflare/nixpi-ssh.nix` — no host rebuild
needed, since the policy is the revocation/permission lever, not a file on
`nixpi`.

---

## 8. RISKS / GOTCHAS

- **WARP dependency**: once the static key is removed, SSH access to `nixpi`
  from anywhere off the LAN depends entirely on the Cloudflare One Client
  being installed, enrolled, and running on whichever Mac you're using. No
  WARP = no remote SSH (LAN `nixpi.local` mDNS still works from any device on
  the same network, cert-based, regardless).
- **Cloudflare outage → physical console**: if Cloudflare's Access/Gateway
  control plane or the tunnel itself is down, ZTIA SSH is unreachable by
  design (it's not a local fallback mechanism). The only path in during a
  genuine Cloudflare-side outage is LAN mDNS (if the LAN itself is fine) or
  physical console (always). This is a real availability trade against the
  old static-key-over-tunnel model, which only depended on the tunnel, not
  the full Access/Gateway stack.
- **Session duration / re-auth cadence**: WARP-gated SSH sessions have a
  configurable max session/re-auth window; the docs reference roughly a
  ~10-hour ballpark in related material but the exact field for
  Infrastructure Access specifically should be independently confirmed —
  check **Zero Trust** → **Access controls** → **Applications** →
  **"nixpi SSH (ZTIA)"** → session duration setting once the app exists, and
  tune if a long-running session unexpectedly drops.
- **`allow_authenticate_via_warp: false`**: may be off account-wide (§1b).
  Flip only if step 6 fails on an unexpected auth prompt — don't pre-emptively
  change Access org settings you haven't confirmed you need.
- **Tunnel CIDR route is new infrastructure, not just a config flip**: §3a
  is likely a real gap (no tunnel on a fresh account has
  `warp-routing.enabled: true` by default) — budget time for it, it's not a
  checkbox.
- **Any other unrelated tunnels on the account** — don't touch them as part
  of this runbook; decommission decisions for other tunnels are tracked
  separately. Nothing here depends on them or should modify them.
- **Never let cleanup elsewhere touch the `nixrpi`/`nixpi` tunnel's SSH
  ingress or DNS while mid-rollout** — it's the sole live path into the only
  server that matters until step 6 passes.
- **`nixvm` is explicitly excluded** — nothing in this runbook applies to it;
  it deliberately keeps the static key forever, per repo convention.
