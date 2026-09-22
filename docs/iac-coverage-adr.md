# ADR-005 — Everything declarative: Cloudflare under terranix, GCP alongside it

**Status:** **DECIDED and FULLY IMPLEMENTED 2026-09-22 — phases 0 through 4.** Four decisions
taken in §3, all five stacks live, every one re-planning clean. §6 records what each phase
actually delivered, §8 what executing them invalidated, and §8a/§8b the traps each one cost.

**The ask, verbatim:** *"make sure the Cloudflare config is clean, lean and up to date, and
henceforth we maintain it via IaC … so that we have everything declarative and consistent. Need
to do the same exercise with Google Cloud/Workspace."*

**Verdict:** achievable for Cloudflare, and **smaller than it looks** once the account is
measured rather than estimated (§2). Not symmetric for Google: the Workspace provider is dead
upstream (§5), so "the same exercise" cannot mean the same mechanism.

---

## 1. Why this is an ADR and not a task

Three constraints turn a housekeeping job into a decision with consequences:

1. **This repo is public.** Committing a zone publishes its mail routing, DKIM selectors,
   verification tokens and every subdomain — for domains that are not all the operator's.
2. **Terraform state has been lost twice**, both times to a wrong working directory. Adding a
   third stack multiplies an already-realised hazard.
3. **A dead dependency in the identity root** is not the same risk as a dead dependency in a
   build tool, and the Workspace provider is dead.

ADR-001..004 set the precedent that changes of this shape get written down before they get
built. This is that record.

---

## 2. The measured gap

Measured 2026-09-22 against the live account (read-only API sweep), **not** estimated:

| | Managed by terranix | Unmanaged |
|---|---|---|
| DNS records (all 7 zones) | 5 | **93** |
| DNS records (`kattakath.com` only) | 4 | **~21** |
| Zone settings | 8 (`kattakath.com`) | 6 zones |
| Redirect rulesets (ours) | 1 | 6 |
| Access apps / policies / tokens | **all 32** | 0 |
| Tunnels + MCP portal + registrations | **all 47** | 0 |
| Workers | 0 | 1 (`mta-sts`) |

Two corrections to the first-pass reading, both of which shrink the work:

- **Most rulesets are not ours.** Each zone shows 3-4 rulesets, but three are Cloudflare's own
  (`Cloudflare Normalization Ruleset`, `Cloudflare Managed Free Ruleset`, `DDoS L7 ruleset`).
  Exactly **one** per zone is authored (`redirect-www-to-apex-<zone>`), and `kattakath.com`'s is
  **already managed**. cf-terraforming has a specific fix for people who import the managed ones
  by mistake; do not be one of them.
- **`kattakath.com`'s zone settings and redirect are already covered** by the `cf-tunnel` stack.

**So the phase-1 job is ~21 DNS records, not 98.** The headline number was true of the account
and false of the decided scope.

### What is already right, and stays untouched

`ssl=strict`, `min_tls_version=1.2`, `always_use_https=on`, HSTS on (6 months, nosniff) —
declared in `infra/cloudflare/nixpi-tunnel.nix`, verified live. Both tunnels healthy (4
connections each). One service token, expiring 2027-09-12. One IdP.

---

## 3. The decisions

| # | Decision | Chosen |
|---|---|---|
| 1 | Where zone data lives | **In-repo, `kattakath.com` only** |
| 2 | State backend | **Cloudflare R2** |
| 3 | Google scope | **GCP declarative; Workspace stays a runbook** |
| 4 | Sequencing | **This ADR first, then build** |

### 3.1 In-repo, `kattakath.com` only

The instinct "DNS is sensitive, keep it private" is **half wrong, and the half matters.** DNS is
world-readable by design: anyone can query `kattakath.com` and get every record this repo would
commit. Publishing the operator's own zone discloses approximately nothing that `dig` does not.

What a public commit *does* disclose is **aggregation across domains that are not only the
operator's** — `silvercreek.ai`, `dontsell.ai`, `aloshy.ai`, `snoringirl.com`, `etuper.com`,
`izzykatt.ca`. Publishing another business's zone in a personal public repo is someone else's
disclosure to make.

So the line is drawn by **ownership, not by secrecy**: the operator's own zone goes in the
public repo, the rest stay hand-managed until they have a home of their own.

**Accepted cost, stated so it is a choice:** six of seven zones remain non-declarative. The ask
said "everything"; this delivers one zone fully and defers six. That is a narrowing of the
request, taken deliberately, and §7 records the trigger for revisiting it.

**Rejected:** a private data file (ADR-004 phase 3's pattern) — correct for *secrets*, overkill
for records already answerable by a public DNS query, and it would hide the operator's own zone
for no gain. **Rejected:** a private data repo — re-introduces exactly the private layer retired
2026-09-15.

### 3.2 Cloudflare R2 for state

Today there is **no backend block**, by deliberate design: each app pins its own working
directory (`$XDG_STATE_HOME/nix-config-*`, 0700, umask 077, state 0600) because state was lost
twice to `tofu` running in whatever the CWD happened to be.

That fixed the CWD hazard and left a second one standing, which the 2026-09-22 review named:
**tofu state is per-USER.** A second admin account on this Mac has no such directory, so `tofu`
from their session sees a pristine workspace and plans to **create** a tunnel, DNS records and
Access objects that already exist. The `MCP_PUBLIC_ALLOW_CREATE` guard exists precisely because
neither the drop-delta nor the empty-render check can see that case.

A shared remote backend removes the class rather than guarding it. R2 over GCS because the
account already exists, the free tier covers a few hundred KB of state, and it does not couple
Cloudflare's own IaC to a second cloud's availability.

**The known footgun, recorded before it is hit:** R2 does not implement CRC32 checksums, so the
AWS SDK's default returns `Header 'x-amz-checksum-algorithm' with value 'CRC32' not
implemented`. The backend block needs `skip_s3_checksum = true` plus
`skip_credentials_validation`, `skip_metadata_api_check`, `skip_requesting_account_id`,
`skip_region_validation`, `region = "auto"`, and an explicit `endpoints.s3`.

**State encryption is not optional here.** Both existing states hold a tunnel connector token in
plaintext and the MCP one also holds an Access service-token secret. Moving that to object
storage without OpenTofu's state encryption would take a secret that is currently 0600 on one
disk and put it in a bucket. Phase 1 configures encryption in the same change as the backend, or
phase 1 does not ship.

### 3.3 GCP declarative, Workspace as a runbook

See §5. The provider is archived; the identity root is the wrong place for a single-maintainer
fork.

---

## 4. Target shape

Three stacks, one backend, one rule for what belongs where:

> **A stack is a blast radius, not a category.**

| Stack | Owns | Why separate |
|---|---|---|
| `cf-tunnel` | nixpi's tunnel, ingress, hosted-site DNS + zone settings | Breaking it takes the Pi offline |
| `mcp-public` | the published MCP gateway, portal, Access, service token | Breaking it takes the MCP portal offline |
| `cf-zones` **(new)** | `kattakath.com` DNS records not owned above, the `mta-sts` Worker | Breaking it takes **mail** down |

Mail is the argument for the third stack. `MX`, DKIM, DMARC and MTA-STS records are the highest
consequence-per-byte objects in the account and they share no failure mode with a tunnel. They
should not ride in a plan whose other half is a Pi.

### Import mechanism

`cf-terraforming` (0.29.0, in nixpkgs) **for import IDs only** — not for config generation. It
emits HCL; this repo renders JSON from Nix. Generating HCL and hand-translating it would create
exactly the drift this repo exists to prevent.

DNS records are **data**: a Nix list per zone, rendered by one `map`, the same shape
`hostedSites` and `publicMcpServers` already use. The generator stays in Nix; cf-terraforming
supplies the `<zone-id>/<record-id>` pairs that `tofu import` needs.

---

## 5. Google: the asymmetry, and the finding that causes it

**`hashicorp/terraform-provider-googleworkspace` was archived 2025-06-30.** No releases, no
issue triage, no maintenance. A community continuation exists
(`TrogonStack/terraform-provider-googleworkspace`, which also reaches the Drive API).

This matters more here than it would elsewhere. `docs/identity-and-offboarding.md` establishes
the Workspace account as the **single lever**: suspend it and every derived login goes with it.
GitHub, FlakeHub, Cloudflare Access and GCP all trace to it. Putting an unmaintained provider in
the path of that lever means a Google API change could leave the one account that controls
everything unmanageable by the tool that claims to manage it — and the failure would surface at
the worst possible moment, during an offboarding.

| | GCP | Workspace |
|---|---|---|
| Provider | `hashicorp/google`, first-party, active | **archived 2025-06-30** |
| Decision | **Declarative under terranix** | **Runbook, reviewed, not automated** |

**What GCP would cover:** Secret Manager (ADR-004's durable store), service accounts, IAM
bindings, enabled APIs, and the state bucket if 3.2 is ever revisited.

**Blocked:** the survey could not run — `gcloud` returned `Reauthentication failed. cannot prompt
during non-interactive execution`. Active accounts are `ismail@kattakath.com` (project
`kattakath-family`) and `izzy@silvercreek.ai`. An operator `gcloud auth login` gates phase 3.

---

## 6. Phased plan

| Phase | Deliverable | Gate |
|---|---|---|
| **0** | ~~Cleanup~~ — **DONE.** Orphan policy deleted (3 remain, all referenced). `telegram` re-registered twice; it still reads `error` — see below | Import a clean account, not cruft |
| **1** | ~~R2 bucket~~ — **DONE on GCS instead.** The operator opened a billing account, which made GCS available; it also has the native state locking §8.1 flagged as unverified for R2. Bucket `kattakath-tofu-state` (versioned, uniform access, public access prevented, 10 non-current versions), all four stacks migrated, state **encrypted** with a Keychain passphrase via `TF_ENCRYPTION` | met: every stack re-plans clean from the remote backend |
| **2** | ~~`cf-zones` stack~~ — **DONE.** 22 records imported; `cf-zones-plan` reads *"No changes. Your infrastructure matches the configuration."* | met |
| **3** | ~~GCP survey~~ — **DONE.** `infra/gcp/foundation.nix` (APIs, automation identity, state bucket) and `infra/gcp/budget.nix` (a 5 CAD spend ALERT). Everything created by hand during the session is imported, so both re-plan clean | met |
| **4** | ~~`docs/workspace-runbook.md`~~ — **DONE.** It found `ws-domain-admin`, an account no file in this repo mentioned, carrying a long-lived key. The first write-up called that a live hole in the single lever; the Admin console then showed the delegation table **empty**, so it was latent, not live — §8b. The key was deleted anyway, and the account's own description now states what is true | met: reviewed against `identity-and-offboarding.md`, which is consistent with it |

**The gate is the same every time, and it is the only one that matters:** an import is correct
when the plan is **empty**. A non-empty plan after import means the Nix does not describe what is
live, and applying it would change production to match a guess.

---

## 7. What would reopen a decision

| Trigger | Revisit |
|---|---|
| A second business zone needs declarative management | 3.1 — the private-repo option becomes cheaper than six hand-managed zones |
| A second human gets an account on this Mac | 3.2 is already urgent rather than prudent; do phase 1 first |
| The Workspace fork gains a second maintainer or Google ships a first-party provider | 3.3 |
| R2 state locking proves unavailable (§8) | 3.2 — GCS has native locking |

---

## 8. What execution invalidated

Written as "verify before phase 1". Phase 1 then went somewhere else, so items 1 and 2 were
never reached — kept, struck through, because *why* they stopped mattering is the useful part.

1. ~~**State locking on R2.**~~ **MOOT — the backend is GCS.** R2 was never enabled on the
   account (`Please enable R2 through the Cloudflare Dashboard`), the operator opened GCP
   billing instead, and GCS has native locking. The concern that made this item worth writing
   was real; the product it was about is not in the fleet.
2. ~~**State encryption + R2 together.**~~ **MOOT for R2, DONE for GCS.** Encryption shipped in
   the same change as the backend, as §3.2 required. Verified by reading an object back: pbkdf2
   metadata, zero occurrences of any resource type in the payload.
3. ~~**`ismail.kattakath.com` appears in `cf-tunnel` state**~~ — **RESOLVED 2026-09-22, and it
   was real.** `cf-tunnel` state OWNED the record while its render no longer declared it, so the
   next `cf-tunnel-apply` planned a **destroy** of the record serving the GitHub Pages site. The
   drop-delta guard would have refused rather than deleted — the hazard was a permanently blocked
   apply, not data loss. Fixed by `tofu state rm` (untracks, does not delete) and re-import into
   `cf-zones`, which now owns it. The same apply also cleared a second piece of drift: the tunnel
   ingress still routed `ismail.kattakath.com` to the Pi.
4. **cf-terraforming against provider v5.** The provider is 5.25.0 (2026-09-11); confirm the
   generated import IDs match the resource types this repo actually declares.

---

## 8a. Findings from executing phases 0 and 2

| Finding | Detail |
|---|---|
| **`telegram` is stuck on Cloudflare's side** | Through the exact edge path with the exact service token it returns its **5 tools in under a second**, and a *freshly created* registration still reads `error` immediately. Not the server, not the tunnel, not the token — the portal is beta. One server of 26; left as-is rather than chased. |
| **The module system cost an infinite recursion for nothing** | Routing the records through `config.fleet.dnsRecords` recursed: `config` inside a terranix `_module.args` block resolves to *that* module's config. The error names `dnsRecords` rather than the cause. Data with ONE consumer is now a plain list (`infra/cloudflare/kattakath-dns.nix`). |
| **A top-level `assert` in a terranix module is the same trap** | `assert …; { … }` forces a module argument while the module is still being constructed. Both assertions now live inside the rendered value, where they fire at render time. |
| **The record count was 22, not the ~21 estimated** | §2's estimate was one low. |

## 8b. Findings from executing phases 1 and 3

| Finding | Detail |
|---|---|
| **The google provider ignores `CLOUDSDK_CONFIG`** | Its Go auth library reads the well-known ADC path, so `gcloud` was scoped to this repo while `tofu` silently used the GLOBAL credential. It surfaced as a 403 on `iam.serviceAccounts.getAccessToken` that no IAM grant could fix — because the grant was on the right account and the call was not. The devShell now exports `GOOGLE_APPLICATION_CREDENTIALS` as well. |
| **A quota project BREAKS impersonation** | Setting one makes the client attach `x-goog-user-project` to every call *including the impersonation call*, and that header is itself serviceusage-gated. With impersonation the final call carries the service account's credential and needs no quota project at all. |
| **Budget currency must match the billing account** | The account is CAD; a USD budget is rejected as a bare `400 Request contains an invalid argument` — no field violation, no mention of currency, and gcloud returns the identical error. |
| **The foundation stack runs as the OPERATOR, not the SA** | Running it as the automation account would require granting that account serviceUsageAdmin + iam.serviceAccountAdmin + projectIamAdmin — the power to re-grant itself anything. The privileged bootstrap stays with the human; the narrow stacks use the least-privileged identity it creates. |
| **Migrating unencrypted state needs an explicit `unencrypted` fallback method** | An empty `fallback {}` is an `Invalid expression`. The migration config declares `method "unencrypted" "migrate" {}` and references it; the committed prelude has no fallback and sets `enforced = true`, so a post-migration unencrypted payload is an error rather than a silent downgrade. |

## 8c. The rot this ADR kept demonstrating

`checks.<system>.docs-indexed` refuses a document nothing **links**. Nothing refuses a document
nothing **updates**, and every documentation failure in this work was the second kind — a true
sentence that went stale while the thing it described moved:

| Stale claim | Moved underneath it |
|---|---|
| This §'s own status tail: *"Nothing in this note has been applied"* | 20 words after a header reading FULLY IMPLEMENTED |
| `CLAUDE.md`'s pointer here: *"NOT implemented"*, *"R2 backend"* | phases 0-4 shipped; the backend became GCS |
| §6 phase 4: the delegation key *"SURVIVES suspending"* | corrected to latent hours later, then the key was deleted |
| §8.1-2: *"verify before phase 1"* | phase 1 went to GCS, so neither was ever reached |
| `identity-and-offboarding.md`: the `email_domain` caveat | the policy was applied the same day |

**The shape:** a status written once, restated somewhere else, then updated in one place. Every
instance here was a pair — a bold header and its own tail, a document and its index entry, a
finding and the correction that followed it.

**No check is proposed.** "Documentation agrees with reality" is not mechanisable, and inventing
a gate for it would be the bespoke wheel this repo's motto rejects. What is cheap is knowing
where rot collects: **if a status is asserted in two places, that pair is a known rot site.**
Update the pair or assert it once and link.

## 9. What this ADR does not do

- It does not move the six other zones. That is 3.1's accepted cost, not an oversight.
- It does not automate Workspace. That is 3.3, and it is a decision, not a gap.
- It does not touch the Access/tunnel/MCP objects — those are **already** fully declarative, and
  the cheapest way to break working IaC is to re-import it.
