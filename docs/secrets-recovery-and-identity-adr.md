# ADR-004: secrets recovery via GCP Secret Manager, Google-canonical identity, and two deferrals

**Status:** **Decided. Phases 1 and 2 of 3 shipped** 2026-09-20 — Phase 1 docs and markers,
Phase 2 the `keychain-secrets` extension (§9 is its execution record). Phase 3 (shape-not-content
AWS capsule, `googleAccount` binding, template, the Access-policy diff) follows the §8 answers
recorded in §9.0. **What `macos` builds has not changed:** `backend.type` is still `"none"` on the
host, and under that default the loader, `home.activation` and the `darwin-system` drv were
measured byte-identical to the pre-ADR-004 tree.

**Read §9 before trusting §§1-8.** It records what Phase 2's execution found the design (and
the brief it came from) got wrong. Where §9 and an earlier section disagree, §9 is what the
tree does.

**Deciders:** Ismail Kattakath.

**How this was produced:** a read of README, ADR-001/002/003, `modules/parts/{identity,hosts,
compose}.nix`, the whole `keychain-secrets` capsule, `pgvector-local.nix`, every ast-grep rule,
the template and `bootstrap.sh`, in that order; a baseline `nix flake check` / `nix flake show`
(29 check rows, 82 green rows, 0 failures); a read-only probe of the live Cloudflare Access
policy and IdP objects, and of the operator's `gcloud` session; and a grep inventory of every
committed identifier. Nothing in §7 or §8 is recalled — each line names the file and line it
came from.

---

## 1. Context

Three facts, each already true in this tree, set the problem:

1. **Secrets have no durable source of truth.** The login Keychain is authoritative for every
   personal token (`local.keychainSecrets`), and it is the ONLY copy. A wiped Mac loses every
   value; `bootstrap.sh` says so and calls the loss acceptable because vendors re-issue. That was
   the right call for a keypair. It is a poor one for ~20 API tokens whose re-issue is twenty
   dashboard visits.
2. **Identity is already Google-shaped, undeclared.** GitHub signs in through Google, FlakeHub /
   Determinate authenticate with the Google identity, and Cloudflare Access's only IdP is the
   Workspace domain (measured 2026-09-20: IdP `Kattakath Google Workspace`, type `google-apps`,
   `apps_domain = kattakath.com`). Yet `modules/parts/identity.nix` has no Google binding at all
   — it is GitHub-centric (`userName`, a noreply `userEmail`).
3. **Engine and personal config are one repo, deliberately** (§4), and the seam between them is
   visible only where a comment happens to say so.

## 2. Decision

1. **GCP Secret Manager becomes the durable source of truth for the operator's personal
   secrets; the login Keychain becomes a fast local cache.** Nothing about how a secret reaches a
   process at runtime changes — the loader, `secret exec`, Touch ID prompts, the index grammar all
   stay byte-identical. What is added is the *write/rehydrate side*, inside the existing
   `keychain-secrets` capsule, as operator-invoked commands only.
2. **GCP, not AWS, because identity is universal on Google.** Every human in this fleet has a
   Workspace account by definition; AWS is a privileged, per-product exception granted to
   specific people (§3 of `identity-and-offboarding.md`). A recovery path gated on the exception
   would leave the baseline human without one.
3. **The Secret Manager resource name is the *reference*** that maps cache ↔ source. It lives
   alongside the cached value on the Mac, never in this public repo (see §8.2 for the tension
   this creates with the brief's proposed option surface).
4. **`mode = "reference"` exists for anything that touches agent logs:** only the resource name
   is exported; the consuming tool resolves it at call time. A resource name without an SSO
   identity to dereference it is a pointer to nothing.
5. **Activation never touches any of it.** `darwin-rebuild switch` does not call `gcloud`, does
   not contact Secret Manager, does not write the Keychain. Asserted by comment now and, in
   Phase 2, by an ast-grep rule in the style of `capsule-must-not-reach-out.yml`.
6. **The Google Workspace account is declared canonical** — a `googleAccount` binding lands in
   `identity.nix` in Phase 3, with the single-lever offboarding property written down in
   `docs/identity-and-offboarding.md` (shipped in Phase 1).
7. **The engine/operator seam is made visible, not enforced:** a grep-able
   `# OPERATOR-ONLY …` marker on every operator-specific block (28 markers across 8 files,
   Phase 1).

## 3. Consequences

- **Three secret models coexist, and the doc says so** (`docs/secrets-and-keychain.md` § Three
  models): agenix for host-bound NixOS/macOS material; firmware-partition planting for nixpi's
  first boot; Secret Manager → Keychain for the operator workstation. None replaces another.
- **A fresh Mac gives nothing up:** bootstrap → `gcloud auth login` (SSO) → `secrets-rehydrate`
  → Keychain repopulated → biometrics as before.
- **The conceal hooks (`secret copy`, `pb-conceal`, the guard's "use the verb that fits")
  become a second layer.** The primary defence for anything log-adjacent is `mode = "reference"`.
- **A new command surface, four verbs, each `--help`-bearing and idempotent:**
  `secrets-rehydrate`, `secrets-push <service> <account>`, `secrets-status`,
  `secrets-resolve <ref>`. Phase 2.
- **Baseline behaviour is proved, not asserted:** the Phase 2 gate is a check that, with
  `backend` unset, `hosts/macos.nix` evaluates to byte-identical `home.activation` output.

## 4. Deferred — stated with the trigger that un-defers each

### 4.1 Namespace rename (`local.*` → an org-branded prefix)

`local.*` stays. 22 option declarations, every doc, every ast-grep rule and two host files use
it, and it collides with nothing today. **Trigger:** these modules are consumed by a *second*
flake alongside third-party modules that could also claim `local.*`. Until then a rename is
pure churn — one `mkRenamedOptionModule` per option, one release of overlap, zero benefit.

### 4.2 Repo split (engine vs. personal)

Stays fused. The split was tried (`nix-personal`, retired 2026-09-15): with one author on both
sides every engine change needed a pin bump in the personal repo or things silently vanished
between activations. A pin is a feature when the two sides move at different speeds and a tax
when they move together. **Trigger:** a second human. **The escape hatch, when it fires:** the
personal flake points its `nix-config` input at a **local working copy** during development —
`path:../nix-config`, or `--override-input nix-config path:$PWD/../nix-config` — and pins to a
rev only at release. Both benefits, neither tax. Not implemented; the OPERATOR-ONLY markers
are the grep that makes the eventual split mechanical.

## 5. Rejected — and why, so it is not re-litigated

| Option | Verdict | Why |
|---|---|---|
| **iCloud Keychain sync as the backup** | Rejected | It is a *sync* system, not a backup: not granular, a restore overwrites everything, and Apple Passwords has no shell client. A recovery path with no CLI cannot be part of `bootstrap → rehydrate`. |
| **AWS Secrets Manager / SSM as the backend** | Rejected | AWS access is the privileged exception, granted per product to specific people. The baseline human has a Google account and nothing else — see §2.2. |
| **sops-nix** | Rejected (reaffirmed) | agenix replaced it 2026-07-08 for the simpler age/SSH model; nothing here changes that trade. agenix keeps the host-bound side untouched. |
| **A per-capsule Postgres** | Rejected (reaffirmed) | `local.rag.pgvector` is the fleet's one loopback Postgres; any capsule needing Postgres sets that flag. Two consumers already ride it (the RAG, the `macos-throwaway` CI job). Dedup by construction. |
| **A parallel `secrets-backend` capsule** | Rejected | The read side already lives in `keychain-secrets`; the write/rehydrate side belongs next to it. A second capsule would be two owners of one Keychain index. |

## 6. What this gives up — stated, not buried

1. **A cloud dependency for recovery.** Today recovery needs a Mac and a vendor dashboard.
   After Phase 2 it needs a Google login and a GCP project that still exists. The project is the
   Workspace-tenant one (§8.1) — losing the Workspace loses recovery, which is the single-lever
   property working as designed, but it is worth saying that the lever cuts both ways.
2. **A second place a secret exists.** Secret Manager is encrypted at rest and IAM-gated, but a
   value that existed only in a Keychain now also exists in a Google project. The `push` verb is
   deliberately never bulk and never runs at activation, so this is opt-in per secret.
3. **Resource names on the Mac in plaintext** — in the item comment or a small local manifest.
   Useless without an identity, but visible to any process that can read the Keychain metadata
   or the manifest. `mode = "reference"` does not hide the name; it hides the value.

## 7. Phase 1 inventory — committed identifiers, FOR APPROVAL (no diff was made)

The brief's rule: no real account id, project id, tenant id, gist id or personal email in a
committed file **outside** `modules/parts/identity.nix`. Grepped 2026-09-20 across the whole
tree, `.claude/` included. Each row names what it is and what the proposed move would be; **none
of these has been moved**.

| # | Where | What | Proposed disposition |
|---|---|---|---|
| 1 | `hosts/macos.nix:301-314` | AWS SSO start-URL id `d-…`, two 12-digit account ids, role names, regions — written into `~/.aws/config` by `programs.awscli.settings` | **Move** → local `~/.aws/config` (already the rule ADR-003 §10.3 and `repo-map.md` § bedrock-gate *claim* holds — the code contradicts the docs since the 2026-09-15 fold-in). The new `local.cloudCli.aws` capsule ships `config.example` with placeholders. |
| 2 | `hosts/macos.nix:277-280` | four personal Gmail addresses (`local.mcpGateway.gmail.accounts`) | **Ask.** The comment argues they are already public elsewhere in the tree. They are still personal emails outside `identity.nix`. Options: leave (marked OPERATOR-ONLY, done), or move the list to a Keychain item / local file the module reads at launch. |
| 3 | `modules/shared/home.nix:997-1010, 1265-1280` | three git-identity emails in `*.inc` files and in `allowedSigners` | **Ask.** Same shape as #2. The `infin8.inc` work identity is already hand-placed outside the repo (home.nix:990) — the same treatment would fit `silvercreek.inc` / `izzykatt.inc`. |
| 4 | `modules/parts/identity.nix:40` | JSON Resume gist id | **Leave** — inside `identity.nix`, now marked OPERATOR-ONLY. |
| 5 | `modules/parts/identity.nix:100-101, 115` | Cloudflare account id, two zone ids | **Leave** — identifiers, inside `identity.nix`, marked. |
| 6 | `infra/cloudflare/{mcp-public,nixpi-tunnel}.nix` | Access IdP UUID, reusable policy UUID | **Leave** — resource ids, not tenant ids; they are how terranix references existing account objects. (§8.4 is about the policy's *content*, not its id.) |
| 7 | `.claude/settings.json:133` | one 32-hex id | **Ask** — looked like a Cloudflare id by shape; not verified. |
| 8 | `packages/next-right-thing/render.sh:12` | one personal email in a code comment (an example payload) | **Trivial** — replace with `someone@example.com` when Phase 3 touches nearby files. |
| 9 | `docs/*.md`, `sites/ismail-landing/index.html`, `CLAUDE.md:80` | emails in prose, a mailto on the operator's own landing page, an ssh target | **Leave** — documentation and published website content, not configuration. |
| 10 | `secrets/secrets.nix:19` | `macos` host SSH public key, operator public key | **Leave** — public keys are public by construction; agenix recipients. |

## 8. Open — conflicts found in Phase 1 that need the operator's call before Phase 2

These are where the brief and the tree disagree. Per the brief's own rule ("stop and ask"),
Phase 2 does not start until each has an answer.

### 8.1 `<<GCP_PROJECT_ID>>`
`gcloud` is signed in as the Workspace account with project **`kattakath-family`** selected
(read 2026-09-20; the token then needed an interactive re-login, so whether Secret Manager is
*enabled* on it is **unverified**). Confirm this is the project, or name another.

### 8.2 `items = [ … ]` does not exist, and adding it reverses a standing rule
The brief says "`items` — existing shape — extend each item". The capsule has **no** `items`
option: secret *names* live only in the Keychain index, and `CLAUDE.md` § Security states "no
secret names live in `.nix` either (the Keychain index is authoritative)". Declaring items in
Nix would put every service name — and, via `ref`, the **GCP project id** — into this public
repo, which the brief's own §4.1 ("never in the public repo") and §8.5 forbid. Two ways out,
both additive:
- **(a)** keep names out of Nix: `backend.project` / `backend.prefix` default to `null` in
  Nix and are set once on the Mac (a Keychain item `__secrets_backend__` or a `0600` manifest);
  refs are derived `${prefix}${service}/${account}` at runtime; `mode` is a per-item token in
  the index grammar (additive: a new `!` marker, say) or the manifest.
- **(b)** accept names in Nix as the brief literally says, and accept that this repo then
  carries service names and a project id.
**Recommendation: (a).** It honours every rule already in force and still delivers the four
verbs.

### 8.3 AWS profiles are back in Nix, contradicting ADR-003 §10.3
`repo-map.md` says `~/.aws/config` "left every repo"; `hosts/macos.nix:297` writes it with real
account ids (inventory #1). Phase 3's `local.cloudCli.aws` is the fix; confirm the two profiles
may leave Nix for a hand-placed `~/.aws/config` (with `config.example` as the template).

### 8.4 The Access policy is an email rule, not a domain rule
Measured 2026-09-20 via the API: reusable policy `mcp-allow-operator` (`b3bd8c38-…`) is
`decision = allow`, `include = [ { email = "ismail@kattakath.com" } ]`. The IdP is already the
Workspace domain. Offboarding today therefore needs a policy edit. **Proposed diff, not
applied:** declare the policy in terranix (`tofu import` the existing object) with
`include = [ { email_domain = { domain = domainName; } } ]`, optionally `require`-ing the
Google IdP. Consequence to weigh: *every* Workspace account on the domain would then pass — with
one human that is the same set; with a second it is the intended set.

### 8.5 The placeholders
| Placeholder | Proposed value | Source |
|---|---|---|
| `<<GCP_PROJECT_ID>>` | `kattakath-family` | live `gcloud config` (§8.1) |
| `<<GCP_SECRET_PREFIX>>` | `fleet/` | brief's example; nothing in the tree constrains it |
| `<<WORKSPACE_DOMAIN>>` | `kattakath.com` | `identity.nix:20`, IdP `apps_domain` |
| `<<GOOGLE_OIDC_APP>>` | `Kattakath Google Workspace` (IdP `3227ee11-…`, type `google-apps`) | live API read |
| `googleAccount` | `ismail@kattakath.com` (= `${loginName}@${domainName}`) | gcloud active account; the Access policy's email |

## 9. Correction record — what Phase 2 found

### 9.0 The §8 answers (operator, 2026-09-20)
Names stay OUT of Nix (§8.2 option a). Placeholders confirmed as §8.5 lists them. Inventory
#1 (AWS profiles), #2 (Gmail list) and #3 (git identities) may all move to local content in
Phase 3. The Access-policy email→domain diff is to be DRAFTED in terranix in Phase 3, never
applied by an agent.

### 9.1 `items[].ref` became annotations + a derived id — the brief's option surface did not ship
There is no `items` option and no `ref`/`mode` per item in Nix. A secret's id is
`sanitize(prefix + SERVICE)` and SERVICE / ENV / account / mode ride on the GCP secret as
**annotations**, so the mapping is derivable in both directions with nothing committed. The
local manifest (`refs.tsv`) is a cache plus the one non-derivable thing, an explicit `--ref`
override. Consequence: **`fleet/` cannot be the prefix** — Secret Manager ids allow only
`[A-Za-z0-9_-]` (read from `gcloud secrets create --help`), so the default is `fleet-`.

### 9.2 The CLIs are installed only when a backend is declared — a deviation, measured
The brief implied the four commands exist whenever the capsule is enabled (`secrets-status`
"runs without network when backend is unset"). First cut did that, and the real host's
`home.activation` **moved** — home-manager's fonts derivation hashes over `home.packages`, so
adding four packages changed two activation scripts and the `darwin-system` drv. Gating the
packages on `backend.type != "none"` restored byte-identity on all three (loader,
`home.activation`, drv) and is the stricter reading of *declaring ≠ installing*. With a backend
declared, `secrets-status --offline` is the no-network path.

### 9.3 `--quiet`, or a disabled API is a false success
Measured: with the Secret Manager API **not enabled** on `kattakath-family`, `gcloud secrets
list` **prompted** ("enable and retry? y/N") from inside `secrets-rehydrate`, the loop ran over
nothing, and the command reported `0 written` with exit 0. Every gcloud call now runs
`--quiet`, and listing goes through one `list_remote` that dies with gcloud's own error line.
The same run established the **operator action Phase 2 cannot take**: enable
`secretmanager.googleapis.com` on the project (console link is in the error text).

### 9.4 No delete-then-add
The brief specified "delete-then-add, since `security` cannot update in place". The capsule's
own writer `set-secret` already uses `add-generic-password -U` (update in place) and is the
index's single writer, so rehydrate pipes values into it and never touches the Keychain
directly. Reuse over a second writer.

### 9.5 A one-line loader diff that the fixture could not see
The fixture check compared two configs that both carried the new module text and passed,
while the REAL host's loader gained one whitespace-only line from an empty `optionalString`
on its own line. Caught only by the pre/post capture of the real host; fixed by attaching the
interpolation to the preceding `fi`. Lesson, same as ADR-002 §9.4: a fixture proves shape, a
capture of the real host proves identity — keep both.

### 9.6 Session probing is not permission probing
`gcloud auth print-access-token` succeeded while `gcloud projects list` had failed minutes
earlier with "reauthentication failed" — the two go through different scopes. `require_session`
is therefore necessary but not sufficient; `list_remote`'s loud failure is what actually gates
a run.

## Measured (filled in at each gate)

| Metric | Baseline (2026-09-20) | After Phase 1 | After Phase 2 | After Phase 3 |
|---|---|---|---|---|
| `flake.nix` lines | 415 | 415 | 415 | |
| `nix flake check` rows (`checks.*`) | 29 | 29 | 30 | |
| green rows in `nix flake check` | 82 | 82 | 87 | |
| capsules | 6 | 6 | 6 | |
| `local.*` option roots | 22 | 22 | 22 | |
| `OPERATOR-ONLY` marker lines | 3 (prose variants) | 31 (28 added) | 31 | |
| ast-grep rules | 5 | 5 | 6 | |
| `macos` `darwin-system` drv | baseline | identical | identical (`backend.type = "none"`) | |
