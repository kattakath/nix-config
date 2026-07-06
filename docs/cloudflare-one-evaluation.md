# Cloudflare One / ZTIA Evaluation & Decision

## Decision

We evaluated **Cloudflare One Zero Trust Infrastructure Access (ZTIA)** — identity-gated SSH backed by **short-lived, CA-signed certificates** — as an alternative to the current static-key model for the NixOS hosts.

**Decision: do NOT adopt at the current solo / two-NixOS-host scale. Keep the loginless static-key model.**

At one operator, one key, two low-value personal NixOS hosts, and a working LAN break-glass, ZTIA's audit / revocation / central-policy benefits are largely theoretical, while the costs (a hard IdP + WARP + Access + CA login dependency, more moving parts to own, periodic browser re-auth, an unconfirmed machine/CI path) are real. This document records **what ZTIA would look like if built**, **why we passed**, and **the concrete triggers that would make us revisit** — so a future reader (or future us) doesn't have to re-derive it.

**Nothing in this evaluation has been applied.** No Cloudflare resource was created; no `.nix` file was changed. All Nix snippets below are illustrative.

> **Update:** Cloudflare One is separately being adopted in this repo for **MCP (Model Context Protocol) tool aggregation** — an unrelated use case that is the reason the earlier LiteLLM proxy container path was dropped. That adoption does not change or revisit the ZTIA-for-SSH decision recorded below: this document's evaluation and "do not adopt" verdict for SSH access still holds as-is. Treat the two as independent decisions about the same vendor, not a single evolving plan.

> Doc-retrieval note: every Cloudflare-specific claim below was checked against current Cloudflare One docs on **2026-07-03**; cited URLs are inline (see [Sources](#sources)). Items that could not be confirmed are flagged in [Open flags](#open-flags-need-live-verification) rather than asserted from memory. The single most important such flag: **Access service tokens are documented for HTTP apps only** — the machine/CI path over ZTIA SSH is an open question, not a confirmed capability.

---

## Mental model: what CF One would (and would not) replace

The clearest way to reason about this decision:

> **Cloudflare One replaces the keys to reach _my own stuff_ — not the tokens to log into _other people's stuff_.**

- **In scope for ZTIA:** SSH into my own hosts. Today that is a static ed25519 key; ZTIA would swap it for _identity + a short-lived certificate_ minted per login.
- **Out of scope, unchanged:** every credential for third-party services — `gh` / `docker` / `hf` / `claude` logins, the Cachix write token (a GitHub Actions secret), and the git SSH **signing** key. Those stay exactly where they are (macOS login Keychain, one-time CLI logins, GitHub Actions secrets). ZTIA touches **SSH login auth only**; nothing else in the [secrets model](../CLAUDE.md) moves.

This framing matters because it bounds the blast radius: adopting ZTIA is a change to _one credential type on the NixOS hosts_, not a re-architecture of the repo's secrets strategy.

---

## Today's baseline (what ZTIA would change)

This fleet has two NixOS hosts — `nixpi` (Raspberry Pi 4, aarch64, the live server with a public Cloudflare Tunnel + Caddy) and `nixvm` (aarch64 UTM/QEMU sandbox VM, no tunnel, no public ingress by design) — plus `macos` (aarch64-darwin, MacBook client only; it never accepts inbound SSH). Only `nixpi` reaches SSH over Cloudflare today; `nixvm` is LAN/local-only. SSH into `nixpi` looks like this:

| Layer | Today | Where it lives |
|---|---|---|
| **Connectivity** (packets reach sshd) | Remotely-managed (token) Cloudflare Tunnel on `nixpi` only. A hardened `systemd.services.cloudflared-connector` runs `cloudflared --no-autoupdate tunnel run`, with the tunnel token read from a plain operator-placed environment file (no encryption, no rekey step — see the repo's [secrets model](../CLAUDE.md) for the `/etc/secrets` convention). | `modules/nixos/cloudflared.nix`; operator-placed secret file on `nixpi` |
| **Authorization** (are you allowed) | **None.** The public hostname has no Access policy — reaching the tunnel is gated purely by possession of the ed25519 private key. This is _why_ sshd is locked keys-only. | Cloudflare account (ingress `<host>.kattakath.com → ssh://localhost:22`) |
| **Identity** (who are you) | **None.** | — |
| **Credential** (what sshd trusts) | A single static key: `users.users.ismail.openssh.authorizedKeys.keys = [ "ssh-ed25519 …STGsS" ]`, with `PasswordAuthentication = false`, `KbdInteractiveAuthentication = false`, `PermitRootLogin = "no"`. | `modules/nixos/core.nix` |
| **Client reach** | An ad-hoc (not yet declaratively wired) `ProxyCommand = "cloudflared access ssh --hostname %h"` reaches `nixpi.kattakath.com`. Loginless: no WARP, no interactive auth. | `modules/shared/home.nix` (currently declares only a `*.local` block; see `docs/tunnel-architecture-and-runbook.md` §7) |
| **Break-glass** | avahi/mDNS publishes `<host>.local` on the LAN; LAN SSH with the same key bypasses Cloudflare entirely. | `modules/nixos/core.nix` (`services.avahi`) |

**What ZTIA changes:** it inserts an **identity** layer (an IdP login) and an **authorization** layer (an Access policy) in front of SSH, and replaces the static authorized key with **short-lived certificates** minted per-login by a **Cloudflare-hosted SSH CA**. The static key stops being the credential; your Access identity becomes the credential.

---

## Architecture & flow (if built)

ZTIA decomposes SSH into three independent layers that compose on top of connectivity:

| Layer | Component | Today | Under ZTIA |
|---|---|---|---|
| **Connectivity** | Cloudflare Tunnel *or* WARP Connector | token tunnel | WARP client (Traffic + DNS mode) on the operator device + a connector on the host side |
| **Authorization** | Access **Infrastructure application** + policy | none | one Infra app targeting the 3 hosts; Allow-your-identity policy; default-deny |
| **Identity** | IdP (OTP / Google / GitHub OIDC) | none | one IdP; login via WARP browser enrollment |
| **Credential** | Cloudflare **SSH CA** → short-lived cert | static ed25519 key | ephemeral cert signed by the CA, principal from the Access identity |

### Human SSH flow (WARP + IdP → cert)

```
                                        ┌─────────────────── Cloudflare edge ───────────────────┐
  ismail@mac                              │                                                        │
  ssh ismail@nixpi                        │  Access (Infra app) ── policy: allow ismail@… ──> ALLOW  │
     │  WARP client (Traffic+DNS)       │        │                                               │
     │  intercepts TCP:22 to target IP  │        ▼                                               │
     ├────────────────────────────────► │   SSH CA signs a SHORT-LIVED cert                      │
     │                                  │   principal = permitted SSH user (from policy)         │
     │  (WARP already holds an          │        │                                               │
     │   Access session from IdP login) │        ▼                                               │
     │                                  │   forwards to host connector ──────────┐               │
     └──────────────────────────────────────────────────────────────────────────┼──────────────┘
                                                                                  ▼
                                                              nixpi sshd: TrustedUserCAKeys /etc/ssh/ca.pub
                                                              validates cert → principal maps to unix user ismail
                                                              (no authorized_keys entry needed)
```

1. Device enrolled in WARP; user logged into the IdP once → WARP holds an Access session.
2. `ssh ismail@<target>`; WARP intercepts the connection to the target IP.
3. Access evaluates the Infra app policy for this identity + target + SSH user.
4. On allow, the CA mints a short-lived cert whose principal is the permitted UNIX username.
5. sshd trusts the CA (`TrustedUserCAKeys`), validates the cert, logs the user in. No static key involved.

### Machine / headless SSH flow (service token) — UNCONFIRMED for SSH

Intended: CI/automation authenticates with an Access **service token** (`CF-Access-Client-Id` / `CF-Access-Client-Secret`) against a Service-Auth policy, obtaining non-interactive authorization with no browser login. **However, the current service-tokens doc scopes them to HTTP applications only** and does not describe SSH / Infrastructure Access support. Treat the machine path as an open question (see [Open flags](#open-flags-need-live-verification)); the fallback is a headless WARP enrollment authenticating as the **non-identity** service email.

---

## Cloudflare One resource plan (if ever built)

### Identity provider — recommend GitHub OIDC (OTP as break-glass)

| Option | Pros | Cons | Solo verdict |
|---|---|---|---|
| **One-Time PIN (email OTP)** | zero external dependency; trivial config; good break-glass | **no group claims**; each login is an emailed code (friction); no longer enabled by default | Fine as **fallback/guest**, weak as primary |
| **Google OIDC** | true SSO, silent re-auth if already signed into Google; group support | requires a Google identity + OAuth client | Good if you live in Google |
| **GitHub OIDC** | this repo already leans on `gh`/GitHub heavily; one OAuth app; familiar login | orgs/teams as groups only if you have an org | **Recommended primary** — lowest new surface for this operator |

For a solo operator, groups are moot: policies can match your **email** directly, so IdP choice is really about login ergonomics. **Pick one primary IdP (GitHub) and optionally add OTP as break-glass.** (OTP is not on by default and lacks group membership; switching auth methods drops IdP group evaluation.)

### One Infrastructure Access application covering both NixOS hosts

- **Type:** Infrastructure (Zero Trust → Access controls → Applications → Create new application → **Infrastructure**).
- **Targets** (Zero Trust → Access controls → **Targets** → Add a target): one per host — `nixpi`, `nixvm` — each pinned to its **IP address(es) + virtual network**. Doc constraint: an IP + virtual-network pairing is unique to one target and **cannot be reused**.
- **Protocol/port:** SSH on port **22** per target. Doc: "Access for Infrastructure only supports assigning one protocol per port."
- **Connection context / SSH user:** the permitted UNIX usernames — here `ismail` (optionally the "log in as email alias" toggle). Doc: "Cloudflare will not create new users on the target. UNIX users must already be present on the server." `ismail` already exists on both via `users.users.${username}` in `modules/nixos/core.nix`.

### Access policy

- **One Allow policy:** match **Emails = your address** (or the GitHub identity). On allow, permit SSH user `ismail`.
- **Default-deny:** Access is default-deny — a target with routes but no matching Allow policy blocks all access. No explicit deny rule is needed.
- **(Optional later):** a Gateway Network policy with the **Audit SSH** action to log SSH commands — requires the session proxied through Cloudflare, which ZTIA already does.

### SSH CA (via `gateway_ca` API for command logging)

- Generate the **Cloudflare SSH CA**: Zero Trust → Access controls → **Service credentials** → **SSH** → Add a certificate → "SSH with Access for Infrastructure" → **Generate SSH CA**. Copy the **CA public key**.
- **For SSH command logging you must create the CA via the `gateway_ca` API endpoint** (`POST /accounts/$ACCOUNT_ID/access/gateway_ca`) — the dashboard-generated CA does **not** enable logging. Response field: `public_key`.
- The CA public key is **public** (format `ecdsa-sha2-nistp256 <key> open-ssh-ca@cloudflareaccess.org`) → **safe to commit to Nix**, unlike the tunnel token (which stays a plain operator-placed secret file, never committed).

### WARP enrollment + session duration

- Create a **device enrollment rule** — an Access application of type `warp` (not a device setting), taking a reusable Access policy that permits your identity to enroll.
- WARP must run in **Traffic and DNS mode** with **Gateway proxy for TCP enabled**, plus a **Split Tunnel** Include-mode entry routing each target host's IP/CIDR through the client (matched by a tunnel/connector route).
- **Session duration:** SSH sessions have a documented **maximum expected duration of ~10 hours**; the exact re-auth cadence is a configurable session-duration setting — **exact field + max not confirmed; verify live** (see [Open flags](#open-flags-need-live-verification)). Practically, set it long enough to re-auth roughly once per workday.

### One service token (machine path) — conditional

Create one Access service token (Service credentials → **Service Tokens** → Create Service Token) producing a **Client ID** + **Client Secret** (headers `CF-Access-Client-Id` / `CF-Access-Client-Secret`), paired with a **Service Auth** policy; duration chosen at creation (docs example: `8760h`). **Caveat:** documented for HTTP apps; SSH/Infra support unconfirmed. If unsupported, fall back to a WARP-enrolled headless service login using the non-identity service email `non_identity@<team>.cloudflareaccess.com`, targeted in a device profile.

---

## The main NixOS change (illustrative — NOT applied)

### Trust the Cloudflare SSH CA in sshd (`modules/nixos/core.nix`)

The CA public key is public → embed it directly in Nix (no secret-handling mechanism needed at all — public keys are safe in the world-readable store). sshd must trust it via `TrustedUserCAKeys`:

```nix
# modules/nixos/core.nix — ILLUSTRATIVE, NOT APPLIED
let
  # PUBLIC key of the Cloudflare-hosted SSH CA (safe in the world-readable store).
  cloudflareSshCaPub =
    "ecdsa-sha2-nistp256 AAAA...redacted... open-ssh-ca@cloudflareaccess.org";
  caFile = pkgs.writeText "cloudflare-ssh-ca.pub" cloudflareSshCaPub;
in
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      PubkeyAuthentication = true;
    };
    # Cloudflare docs: place these "above all other directives".
    extraConfig = ''
      TrustedUserCAKeys ${caFile}
    '';
  };
}
```

NixOS renders `sshd_config` from the module's `settings`; `TrustedUserCAKeys` via `extraConfig` is **appended**, not prepended. The doc's "above all other directives" guidance concerns precedence when duplicate directives exist — with a single `TrustedUserCAKeys` and no conflicting `AuthorizedKeys*` overrides, ordering is not expected to matter, but **verify against the rendered config on the pilot host** (see [Open flags](#open-flags-need-live-verification)).

### Principal / user mapping

Under ZTIA the cert principal is the permitted **SSH user** from the Access policy (here `ismail`). sshd validates the cert against `TrustedUserCAKeys` and matches the principal to the login user. **No `AuthorizedPrincipalsCommand` / `AuthorizedPrincipalsFile` is documented as required** for the Infrastructure-Access path — the principal _is_ the UNIX username. (This differs from the older self-hosted `cloudflared access ssh-gen` short-lived-cert flow, which did use principals files; that legacy path's exact directives are unconfirmed.) The UNIX user must pre-exist: it does, via `users.users.${username}`.

### Coexist, then replace `authorizedKeys` (two phases)

- **Phase 1 — coexist (recommended pilot).** Keep `users.users.ismail.openssh.authorizedKeys.keys = [ ed25519 ]` **and** add `TrustedUserCAKeys`. sshd accepts either a valid CA-signed cert **or** the static key. This is the safe migration state: ZTIA works while the old key remains as break-glass.
- **Phase 2 — replace.** Remove the `authorizedKeys.keys` entry so the **only** accepted credential is a CA-signed cert. Do this **per-host**, only after Phase 1 is proven, and **never on both NixOS hosts at once**.

### Connectivity: keep the token tunnel, or move to WARP Connector?

- ZTIA's documented model is **WARP client (Traffic + DNS) on the operator's device + a connector on the host side**, with the target reached by **IP** (`ssh ismail@<target-ip>`), not by the public `<host>.kattakath.com` hostname + `cloudflared access ssh` ProxyCommand used today.
- The existing **token tunnel (on `nixpi` only) can stay as the host-side connector**; ZTIA layers Access + CA on top. Whether the current public-hostname ingress is reused or replaced by an Infra-target IP/network route is a **routing decision to confirm live** — the Infra app matches targets (IP + virtual network), so a **network/private-IP route** is the natural fit, and the public-hostname SSH ingress may become redundant.
- The `ProxyCommand` (once wired declaratively, or used ad-hoc as today) would be **removed** for a ZTIA host (WARP handles interception); it stays only for any host still on the loginless path.
- `nixvm` has no tunnel or public ingress today, so a ZTIA Infra target for it implies **adding** connectivity (WARP Connector or a new tunnel) where none exists now — a bigger first step than `nixpi`, which already has a connector to layer on top of.

### Per-host notes

- **nixpi** (Raspberry Pi 4, durable hardware, the only host with a live tunnel today): the natural **pilot** — it already has a connector to layer Access + CA on top of, no new connectivity required.
- **nixvm** (aarch64 UTM/QEMU sandbox VM, no tunnel/no public ingress by design): adopt only after `nixpi` proves out, and only if this VM's isolation posture is meant to change — ZTIA would require standing up connectivity (WARP Connector or a tunnel) that intentionally does not exist today.
- **macos** is a client only; it never runs sshd or accepts inbound connections, so it has no per-host ZTIA notes of its own — it only needs the WARP client / `cloudflared access ssh` on the operator side.

---

## Coexistence, migration & rollback

**Run alongside the current loginless path:**

1. **Add, don't replace (Phase 1).** Add `TrustedUserCAKeys` while keeping `authorizedKeys`. Both credentials valid.
2. **Keep `.local` as break-glass.** LAN SSH via mDNS + static key never goes through Cloudflare — the deliberate escape hatch if Access/WARP/CA/IdP is down. Do not remove it during migration.
3. **Pilot on ONE host — nixpi only.** Provision the Infra app/target/policy/CA + sshd trust for nixpi alone (it already has a tunnel connector to layer on top of). Prove: authorized login works, unauthorized identity is denied, static-key break-glass still works, `.local` still works.

**Safe pilot sequence:** (1) generate SSH CA via API if you want Audit SSH; (2) create Infra app + nixpi target + Allow policy; (3) set up WARP enrollment + your device; (4) add `TrustedUserCAKeys` to nixpi (Phase 1, coexist), rebuild; (5) test all four outcomes; (6) only then consider Phase 2 and nixvm (which would first need connectivity stood up, since it has none today).

**Rollback:**

- **Fast (config):** revert the `TrustedUserCAKeys` addition (and restore `authorizedKeys` if Phase 2 removed it), then rebuild. The static-key path is git-tracked, so rollback is a revert + rebuild.
- **Instant (operational):** in Phase 1 the static key + `.local` break-glass keep working the entire time, so a broken Access/WARP/CA never locks you out — the escape hatch has zero cloud dependency.
- **Cloud side:** disabling the Access policy or deleting the Infra target reverts authorization; the CA can be left in place harmlessly.

---

## Cost / benefit at solo scale

**What ZTIA genuinely buys:**

- **Identity-bound access + audit.** Every SSH is tied to an IdP identity and logged; optional keystroke/command logging (Audit SSH). Real value once you need "who logged into what, when."
- **No long-lived key to steal.** The credential becomes an ephemeral cert; a leaked laptop key is worthless without a live Access session. Revocation = disable the identity/policy, not re-key every host.
- **Central policy.** One place to say who may SSH where.

**What it costs:**

- **A hard login dependency.** SSH now depends on IdP + WARP + Access + CA all being up and your device enrolled. Today's model has _zero_ such dependency (the `.local` break-glass mitigates this only on-LAN).
- **Cloudflare becomes a chokepoint** for remote access — an outage or account issue blocks SSH (mitigated only by break-glass).
- **Friction:** periodic browser re-auth; WARP installed and running on every client device; the machine/CI path is unconfirmed and may be awkward.
- **Setup + maintenance surface:** an IdP, an Infra app, targets, a policy, a CA, WARP enrollment, device profiles, split-tunnel routing — a lot of moving parts for one operator and two NixOS hosts.

**Why we passed:** at solo scale with two low-value personal NixOS hosts (only one of which is even tunnel-reachable today), the audit/revocation/central-policy benefits are largely theoretical — one user, one key, a working break-glass. The current loginless key model is simpler, has no cloud auth dependency, and is already hardened (keys-only, no passwords, no root, tunnel not publicly routable). ZTIA's payoff appears with multiple users, contractors, compliance requirements, or many hosts — none of which apply today.

### Revisit ZTIA when any of these become true

- **(a) A second human operator** — more than one person needs host access.
- **(b) Contractor / temporary access** — someone should get time-boxed, revocable access without handing out a durable key.
- **(c) A host holds data worth per-session attribution** — you need to answer "who ran what, when" per login.
- **(d) A compliance / audit requirement** — an external obligation to log and centrally govern access.

### Cheapest partial upside (no cert migration)

If you want _some_ of the upside cheaply without moving to certs: **enable Audit SSH logging on the existing path.** The session already traverses Cloudflare, so a Gateway policy with the Audit SSH action can capture SSH activity while the static-key model stays in place. Evaluate this separately from full ZTIA — it is a much smaller change.

---

## Open flags (need live verification)

Verify these against live docs / the CF account before ever building:

1. **Service tokens for SSH.** The service-tokens doc scopes them to **HTTP apps**; SSH/Infrastructure Access support is unconfirmed. Confirm whether a service token can authorize an Infra SSH target, or whether the machine path must use headless WARP + non-identity enrollment.
2. **WARP session duration field + max for SSH.** Docs state a ~10h max SSH session; the exact re-auth/session-duration setting name and bounds were not confirmed. Verify in device-enrollment / session settings.
3. **Connectivity model — tunnel reuse vs IP/network route.** Confirm whether the existing token tunnel + public-hostname ingress is reused, or whether ZTIA requires a **network / private-IP route** (target = IP + virtual network) and the public SSH hostname becomes redundant. Confirm the split-tunnel Include entry aligns with the tunnel route.
4. **CA-for-logging split.** Confirm that only the **`gateway_ca` API-generated** CA enables SSH command logging and a dashboard-generated CA does not — decide API vs dashboard generation accordingly.
5. **sshd directive ordering under NixOS.** The doc says put `PubkeyAuthentication` / `TrustedUserCAKeys` "above all other directives"; NixOS **appends** `extraConfig`. Verify the rendered `sshd_config` on the nixpi pilot accepts the cert — and whether an `AuthorizedPrincipalsCommand` / `AuthorizedPrincipalsFile` is actually needed for the Infra path (docs imply principal = SSH user, no principals file).
6. **Email-alias principal.** If enabling "log in as email alias," confirm the lowercased email prefix resolves to an existing UNIX user or maps to `ismail` — otherwise logins fail (no user auto-creation).
7. **aarch64 target support.** Confirm ZTIA SSH has no arch caveats for aarch64 hosts (`nixpi`/`nixvm` — this fleet is aarch64-only) — nothing in the docs suggested arch limits, but verify before relying on it for the Pi.
8. **IdP re-auth ergonomics.** If choosing GitHub OIDC, confirm silent re-auth behavior; OTP's emailed-code friction is confirmed and makes it a fallback only.

---

## Sources

Retrieved 2026-07-03:

- ZTIA for SSH — https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-infrastructure-access/
- Short-lived certificates — https://developers.cloudflare.com/cloudflare-one/identity/users/short-lived-certificates/
- Infrastructure apps — https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/infrastructure-apps/
- One-Time PIN IdP — https://developers.cloudflare.com/cloudflare-one/identity/idp-integration/one-time-pin/
- Service tokens — https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/
- Self-hosted private app — https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/self-hosted-private-app/
- WARP manual deployment/enrollment — https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/warp/deployment/manual-deployment/

### Repo cross-references

- `modules/nixos/core.nix` — sshd hardening, the static `authorizedKeys` entry, avahi `.local` break-glass.
- `modules/nixos/cloudflared.nix` — the hardened token-connector systemd unit (no-op unless the host sets `services.cloudflared-connector.enable = true`; reads its token from a plain operator-placed file, default `/etc/secrets/cloudflared-token` — no encryption, no rekey step).
- `modules/shared/home.nix` — the darwin-only SSH config; a `cloudflared access ssh` `ProxyCommand` for `nixpi.kattakath.com` is documented but not yet declaratively wired (see `docs/tunnel-architecture-and-runbook.md` §7).
- `hosts/nixvm.nix`, `hosts/nixpi.nix` — per-host tunnel wiring; only `nixpi` enables the connector.
- `CLAUDE.md` — the secrets model (plain operator-placed files at `/etc/secrets/<name>` for system/service creds, never committed; Keychain / one-time CLI logins for personal tokens; Cachix write token as a GitHub Actions secret only).
