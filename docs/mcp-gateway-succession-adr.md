# ADR-006: IBM ContextForge is a PORTAL-layer alternative, not `mcp-proxy`'s successor

**Status:** **Decided (name only). NOT implemented** — 2026-09-23. Nothing has shipped:
`modules/shared/mcp.nix` still runs `pkgs.mcp-proxy` v0.12.0, there is no `contextforge` package,
no second port, and no behaviour change on any host.

**This ADR was amended the day it was written, and the amendment is the point.** It was drafted as
"ContextForge succeeds `mcp-proxy`". That framing is a **category error**: a ContextForge *gateway*
federates peers that are ALREADY HTTP/SSE and rejects stdio outright (§3), so it cannot replace a
stdio bridge — it sits ABOVE one. The layer it actually competes with is the **Cloudflare MCP
Portal**, which this fleet already runs. §1a is that comparison, and it is the section to read
first; the original framing survives nowhere in this document.

**Read §12 before trusting §§1-11, and read §13 — it is still empty.** ADR-002's §9 had to
overturn four of its own "ADOPT" rows. This document is only the design state. Where execution
later disagrees, execution wins and §13 records it.

**Deciders:** Ismail Kattakath.

**How this was produced:** six parallel research passes, each then adversarially refuted against
the primary artifact. Where a refutation stood, the correction is what is written below — several
headline claims from the first pass did **not** survive and are marked as corrections rather than
quietly dropped. Primary artifacts read: `IBM/mcp-context-forge` at `main` — `mcpgateway/{main,
translate,translate_header_utils,schemas,config}.py`, `services/{gateway,server}_service.py`,
`common/validators.py`, `pyproject.toml`, `SECURITY.md`, `CONTRIBUTING.md`, `DCO.txt`,
`docs/docs/manage/{oauth,identity-propagation,dcr,catalog}.md`, ADR-041/042; the GitHub API for
contributors, commits, releases, issues and security advisories; the PyPI JSON and simple-index
APIs for `mcp-contextforge-gateway` 1.0.10 and `cpex` 0.1.2/0.1.3/0.1.4; the 1.0.10 wheel itself,
downloaded and unzipped; and `nix eval` against **this repo's pinned nixpkgs**
(`ef34387ddd751e1ab8857adf4676492d32eb24ec`) for every dependency version quoted. Anything not
verifiable that way is marked **UNVERIFIED** in place.

---

## 1. Decision

1. **IBM ContextForge (`IBM/mcp-context-forge`, PyPI `mcp-contextforge-gateway`) is the named
   candidate for the PORTAL layer** — federation, auth, identity, per-server policy, catalog. It is
   **NOT** a candidate to replace `pkgs.mcp-proxy`, which does a different job (stdio → HTTP) that
   ContextForge does not do at all.
2. **It is not adopted now**, and on today's evidence the Cloudflare MCP Portal **wins** (§1a). No
   packaging, no port, no registration change in this PR.
3. **`mcp-proxy` stays either way.** Adopting ContextForge would ADD a layer, not remove one — the
   stdio bridging still has to happen, whether by `mcp-proxy` as today or by 27
   `mcpgateway.translate` sidecars (§3).
4. **It is not bought for the startup barrier.** §2 shows the barrier is a property of *one
   process spawning 27 stdio children sequentially*, and §8's cheaper adjacent option fixes it
   **without ContextForge at all**. ContextForge is bought for **identity propagation and per-user
   downstream credentials** (§5) — which are **currently unreachable through this fleet's
   Cloudflare portal**, and that is why this is a future decision and not a present one.
5. **Hard requirement on any migration:** the published path segment is derived **deterministically
   in Nix** (a UUIDv5 of the server name), never read back from a database. See §7.
6. **Hard requirement on any migration:** the Admin UI and Admin API stay **off**, and adoption is
   declarative — no `mcp-scout` violation, no admin-UI registration.

## 1a. The comparison this ADR was missing — ContextForge vs the Cloudflare MCP Portal

The first draft compared ContextForge against `mcp-proxy`. Wrong pairing. `mcp-proxy` bridges stdio
to HTTP; ContextForge **cannot** (§3). What ContextForge replaces is the layer above:

| | **Cloudflare MCP Portal** (today) | **ContextForge** |
|---|---|---|
| Runs where | **Cloudflare's edge** — zero processes on this Mac | **This Mac** — 1 gateway + 2 forked jq workers |
| Federation of N servers behind one URL | ✅ | ✅ |
| Authentication | **Google Workspace SSO via Access** | JWT / OAuth it issues itself |
| Per-server authorization | ✅ — per-server Access apps, three tiers (ADR-006 predates none of this; applied 2026-09-23) | RBAC / teams |
| DDoS absorption, TLS, anycast | ✅ **free, always-on** | ❌ — would need the tunnel anyway |
| Secrets to operate | **0** | **≥2** (`JWT_SECRET_KEY`, `AUTH_ENCRYPTION_SECRET`) |
| Packaging cost | **0** — it is a managed service | §6 — not in nixpkgs |
| Per-user credential injection **into a local stdio child** | ❌ **impossible** — a remote portal cannot set env vars on this Mac's children | ✅ **the one genuine advantage** |

**The portal wins on every axis but one.** That one — injecting a different credential into a local
child process per caller — is structurally impossible for *any* remote gateway, which is why it is
the only reason ContextForge is named at all. And §5 shows it is **currently unreachable**, because
the mechanism needs the client to send a custom header and grok.com sends none.

**Consequence for anyone reading this later:** adopting ContextForge means **self-hosting a layer
Cloudflare currently gives you free**, and carrying two secrets, a database and a package to do it.
Do not start that because the gateway feels slow — see §2, it is not.

## 2. The measured weakness — and the one that measured fine

Measured 2026-09-23 against the live `127.0.0.1:8097` gateway, **not** estimated.

| Test | Result | Verdict |
|---|---|---|
| 1 / 10 / 20 / 40 concurrent `initialize` calls | 0.051 / 0.082 / 0.104 / **0.167 s** wall | **Concurrency is NOT the problem** |
| Per-request cost across that sweep | 50.8 ms → **4.2 ms** | It pipelines; cost *falls* under load |
| Time until all 27 servers ready | ~**29.4 s**, all within **300 ms** of each other | **All-or-nothing** |
| Time until TCP `:8097` accepts a connection | ~**20 s** | Binary: refused, then fully ready |

**The wait is `max(server init)`, and one slow server delays every server.** The coupling is
already written down in-repo at `modules/shared/mcp.nix:1138-1147`: children are handshaked
sequentially, all live in one `AsyncExitStack`, and the listening socket is not created until the
loop completes. Upstream agrees it is structural — open issues **#229** ("prevent SSE runtime
disconnect from crashing entire proxy"), **#232**, **#237**, **#248**.

**An ADR that justified a replacement on performance would contradict this table.** The
concurrency hypothesis was tested and **rejected on measurement**.

## 3. What ContextForge actually is — four premises corrected

The operator's stated premises going in were: *heavy, Kubernetes-shaped, ships a useless GUI; but
it's Python, which is good; it can run MCP servers on the host with stdio, no problem; and the
per-user credentials story is the reason.* Three of the four are wrong in some part. They are
recorded here **so they are not re-derived**.

| Premise | Verdict | Evidence |
|---|---|---|
| "Heavy, built for Kubernetes, useless GUI" | **WRONG** | `pip install`-able. `config.py:236 database_url = "sqlite:///./mcp.db"` — SQLite is the default, Postgres/Redis are optional. `config.py:1171 mcpgateway_ui_enabled = False` and `:1172 mcpgateway_admin_api_enabled = False` — the UI is **off by default**. Redis is only needed for multi-worker leader election. |
| "It's Python, which is good" | **TRUE for the build** | An earlier pass claimed a Rust build (`Cargo.toml`, `crates/`, ADR-042). **Refuted:** `pyproject.toml:6-8` sets `build-backend = "setuptools.build_meta"`; the published artifact is `mcp_contextforge_gateway-1.0.10-py3-none-any.whl` — pure-Python, `Root-Is-Purelib: true`, **zero** `.so`/`.dylib`/`.pyd` entries. ADR-042 is `Status: Proposed`. `crates/mcp_runtime` is **deprecated 2026-06-11, sunset 2026-07-07**. |
| "…but watch the JS" | **NEW COST** | `pyproject.toml:11-12` registers `build_py = mcpgateway.tools.builder.build_hooks.BuildPyWithUI`, an npm/Vite/Tailwind build gated on `BUILD_UI_ASSETS=true`. The **wheel already contains** the 141 built assets; a git-tag build does not. **Build from the wheel, never the git tag.** |
| "Runs stdio servers on the host, no problem" | **FALSE as stated** | `schemas.py:3163` — `STDIO: ... not supported for gateways`; `:3179 GATEWAY_SUPPORTED_TRANSPORTS: frozenset = {"SSE","STREAMABLEHTTP"}`. The gateway forks **nothing**: `grep subprocess\|Popen\|create_subprocess mcpgateway/main.py` returns one hit, a comment. |

### The stdio mechanism, corrected

Each stdio server needs its own **sidecar bridge**:

```
python3 -m mcpgateway.translate --stdio "<cmd>" --expose-streamable-http --port <n>
```

`translate.py:415` is the proof it is a real host child — `asyncio.create_subprocess_exec` on the
`shlex`-split argv, no shell, no container, inherited env. **So `desktop-commander` and
`macos-automator` keep real filesystem and AppleScript access** — the showstopper that killed
MetaMCP and Docker MCP Gateway is cleared. The cost is topology:

| | today (`mcp-proxy`) | ContextForge |
|---|---|---|
| Processes | 28 (1 supervisor + 27 children) | ≈**57** (1 gateway + 2 forked jq workers + 27 `translate` + 27 children) |
| Loopback ports | 1 | **28** |
| launchd agents | 1 | **28** |
| Secrets required | **0** | **≥2** — `JWT_SECRET_KEY`, `AUTH_ENCRYPTION_SECRET` (+ a platform admin password) |

**That decomposition is simultaneously the whole cost and the whole fix for §2's barrier.** The
gateway's `lifespan` (`main.py:1457`) never waits on a peer; health is a background task with
per-peer deactivation (interval 60 s, `health_check_timeout = 30` at `config.py:2900`,
`unhealthy_threshold = 3`). But nothing in ContextForge's *documentation* promises bind-before-ready
or lazy peer connection — **§2's fix is read from source at `main`, not from a supported contract.**

## 4. Governance — is "a name we can trust" justified?

**Justified as an active, genuinely multi-contributor Apache-2.0 project. Over-stated if read as
"an IBM product with support guarantees" or "a hardened security boundary."**

| Signal | Measured |
|---|---|
| Licence / contribution | **Apache-2.0**; **DCO 1.1 sign-off, no CLA** (`DCO.txt`, `CONTRIBUTING.md:160,164`) |
| Contributors, last 90 days | **314 commits, 37 distinct authors**; no author above ~12%. 167 all-time |
| Founder | `crivetimihai` holds **1143** all-time commits (~5× the next) but **1 commit in 90 days, last 2026-06-26**. Merge and release authority has handed over to `ja8zyjits`, `msureshkumar88`, `Lang-Akshay` |
| Releases | **28**, v0.1.0 (2025-06-05) → GA v1.0.0 (2026-05-01) → **v1.0.10 (2026-09-07)**, a patch every 12-16 days; 15 commits in the last 7 days |
| Issues | **746 open issues / 2752 closed**; 224 open PRs / 2382 merged. (A raw `open_issues_count` of **970** is those two open figures summed — GitHub counts PRs as issues.) Median close latency **5.8 d**, p90 **14.8 d** |
| Advisories | **19 published GHSAs — 4 critical, 8 high, 7 medium**; **13 in August 2026 alone**; CVE-2026-53708/53709/53710/53711 |
| Supply chain | SBOM targets, `.snyk`/`.grype.yaml`/`deny.toml`/cargo-vet all present — but **no PyPI Trusted Publishing, no PEP 740 attestations, no provenance, no signed release assets** |

**Read the advisories both ways.** Publishing 19 coordinated advisories with 4 CVEs is what a
project taking disclosure seriously looks like. But the *class* is pre-hardening: a default JWT
signing key `"changeme"` accepted in the default environment shipped **twice**
(`GHSA-5424-f25v-29r8`, `GHSA-8pcq-mx48-hjvj`), plus SSTI→RCE in the prompt renderer, a
RestrictedPython sandbox escape, multiple SSRFs, and cross-tenant BOLA.

`SECURITY.md` is unusually candid and its own words are the finding: the Admin UI *"should never
be exposed in production"* (`:8`); *"there are no backported security patches or long-term support
branches"* (`:29` — **stale**: a `v1.0.7` support line demonstrably exists, tag `v1.0.7-20260921`);
*"perform a security audit of the codebase yourself"* (`:30`); *"ContextForge is not a standalone
product"* (`:32`); *"expect breaking changes between minor versions"* (`:60`).

**In this fleet's posture — loopback-bound, one human, UI and Admin API off — nearly every
advisory class is neutralised.** Exposed, it would not be. Say that, not "IBM, therefore safe."

**One thing the IBM name does not cover:** `cpex`, the one dependency missing from nixpkgs and
imported unconditionally by 19 gateway modules, is published by **`contextforge-org`** — a
separate GitHub organisation created 2025-10-25, 9 public repos, **13 stars**, no stated IBM
affiliation. See §6.

## 5. Per-user credentials — the reason for the choice, and why it is unreachable today

**The primitives exist and are documented.** An earlier pass called this unverified because it
grepped only the README; that was wrong. `docs/docs/manage/oauth.md:32` "Authorization Code (user
delegation)", `:163-189` per-user `OAuthToken.learned_aud` with an explicit per-user-over-per-gateway
rationale, `:226` the gateway applies the exchanged token as `Authorization: Bearer` on the upstream
call; `docs/docs/manage/dcr.md:264` per-user delegated OAuth tokens; plus separate identity
propagation (ADR-041, RFC 8693 on-behalf-of). All **opt-in and default-off**.

**And they are not reachable through this fleet's portal. This is the blunt part.**

| Client | Can send a per-project header? | Why |
|---|---|---|
| **grok.com** | **No — hard blocker** | `infra/cloudflare/mcp-public.nix:658-660`: *"takes a URL and nothing else — no header field"* |
| **Claude Desktop** | **No** | `modules/shared/claude-desktop.nix:126-131` — `exclude = [ "url" "type" "enabled" "headers" ]` |
| **claude.ai / claude.com** | **Static, immutable, four max** | Beta-gated to some orgs; each header **name needs Anthropic's prior approval**; values are **immutable after connector creation**; `Authorization` unavailable on an OAuth connection |
| **The portal hop** | **Originates its own** | `mcp-public.nix:589-591` sets `auth_type = "bearer"` with the fixed Access service-token pair — it presents credentials, it is not a transparent header proxy |

**Even if the portal did forward client headers, claude.ai caps you at four immutable
pre-approved values and grok.com has none. The clients are the binding constraint, not the
portal** — which is why no probe is needed to settle it.

**Separately, ContextForge's own `--enable-dynamic-env` is not a per-project isolation primitive.**
`translate.py:392` stops the existing child before starting a new one — **one child, killed and
respawned**, not one child per credential. `translate.py:705-751` throttles restarts to one per
**30 s** with **no error branch**: inside that window, project B's tool calls execute silently
under **project A's credential**. The multi-protocol path (`:1896`, `:1969`) has the same restart
with **no throttle at all**, plus a 500 ms sleep per request. Three open upstream defects sit in
this exact plumbing — **#6963**, **#6447**, **#6781** — all filed by external reporters, and
#6963's own fix PR notes the bad behaviour is *pinned by a passing unit test*.

## 6. Packaging cost, measured against the pinned nixpkgs

| Fact | Measured |
|---|---|
| In nixpkgs? | **No.** `nix search nixpkgs contextforge` → no results; `repo:NixOS/nixpkgs contextforge` → **0** PRs/issues |
| Core dependencies | **43 requirement lines = 41 distinct packages**; **40 present** in the pin, **1 missing** (`cpex`) |
| Extras-implied, easy to miss | `uvicorn[standard]`, `pydantic[email]`, `httpx[http2]` imply **email-validator, uvloop, httptools, watchfiles, python-dotenv, websockets** — all present, all must be listed explicitly (nixpkgs has no extras) |
| Below their declared floor | **14** — widest: `starlette` 1.3.1 vs `>=1.6.0`; `typer` 0.25.1 vs `>=0.27.1`. Plus `pygithub` for `cpex` → **15 relax entries** |
| Exactly **at** their floor | **12 more** — one upstream minor bump roughly doubles the relax list |
| Two-sided constraint | `filelock>=3.32.0,<3.33.0`; the pin has 3.29.7 and **upstream is already at 4.0.1** — a permanent override, not a future risk |
| Python | `requires_python <3.14,>=3.12`. **The pin's `pkgs.python3` is 3.14.7 — illegal.** Target `python313` (3.13.15): `nix build --dry-run` → **1 derivation to build** vs **34** for `python312` |
| Prior art | Exactly one: `awill1988/dotfiles` (uv2nix, `sourcePreference = "wheel"`). **Do NOT carry its `wrapper.py` patch** — it backports a v1.0.0-RC-3 fix onto 0.9.0, the old block does not exist in 1.0.10, and `--replace-fail` would **hard-fail the build** |

**`cpex` is the one real new derivation and it is load-bearing.** 19 `mcpgateway/*` modules import
`cpex.framework` at module top level, `main.py` and `auth.py` among them — `PLUGINS_ENABLED=false`
does not drop it. **Pin 0.1.3**, not the latest: 0.1.4 requires `mcp>=2.0.0`, which conflicts with
the gateway's own `mcp<2,>=1.28.1` and drags in two more unpackaged deps (`httpx2`, `mcp-types`).
IBM knows — `pyproject.toml` carries `[tool.uv.exclude-newer-package] cpex = "2026-09-07…"`.
0.1.3 is itself a 279 KB pure wheel with one floor miss.

**Shape:** two `format = "wheel"` derivations against `python313` — `cpex` as
`buildPythonPackage`, the gateway as `buildPythonApplication`. This would be the **first**
`buildPython*` in the repo (only `python3.withPackages` exists today), so the header comment must
carry the `upstream-first` reasoning per `.claude/rules/upstream-first.md`.

**With no upstream provenance, the pinned Nix hash is the trust root.** There is nothing to verify
against.

## 7. Migration shape in this repo, and the riskiest step

**Files that change:** `modules/shared/mcp.nix` (the bulk — one agent becomes ~28),
`modules/parts/identity.nix` (a second port constant), `infra/cloudflare/mcp-public.nix`
(**2 lines**), `modules/parts/terranix.nix`, `modules/parts/checks.nix`, `docs/mcp-gateway.md`
(rewrite), `docs/repo-map.md`, `CLAUDE.md`, `.claude/skills/mcp-scout/SKILL.md`, plus a new
`packages/contextforge.nix`.

**Files that do NOT change:** `modules/shared/claude-desktop.nix` — clients dial
`https://mcp.kattakath.com/mcp` and never the port, so **zero client churn**.
`modules/darwin/logging.nix` derives rotation from the composed agent sets, so ~27 new agents get
rotation **free**.

**`checks.<system>.mcp-published-parity` survives** — it compares `local.mcpGateway.hostedServers`
against `fleet.publicMcpServers` as sets, both directions, and is agnostic about what hosts them.
**Invariant to state now:** its two sides must keep coming from *different modules*. The repo has
already lived through a sibling check whose arms collapsed into one expression and "went on
reporting success while asserting nothing."

### The URL question, settled — no spike needed

ContextForge serves per-server Streamable HTTP at `/servers/<id>/mcp` (`main.py:3086`,
`:3730`) — the same *shape* as today, but `<id>` is a **UUID**. An earlier pass called this
fatal and non-reproducible. **Refuted:** `schemas.py:4607` — `id: Optional[str] = Field(None,
description="Custom UUID for the server (if not provided, one will be generated)")`, honoured at
`server_service.py:632-635`; the validator (`common/validators.py:760`) requires a *valid UUID*
but any valid UUID will do.

**So: derive it in Nix as `uuid5(NAMESPACE_URL, "<server-name>")`.** Pure, identical on every
machine, committable. And because `id`, `name` and `hostname` are three independent attributes on
the registration (`mcp-public.nix:586-589`), the Terraform **addresses stay human** — only
`hostname` changes. That is **27 in-place attribute updates, and the drop guard
(`terranix.nix:1129`, which compares addresses) never fires.**

**What is genuinely lost:** human-readable paths. `/servers/9a3f…c1/mcp` in a Cloudflare log tells
a human nothing. That breaks `mcp-public.nix:250-278`'s *"a thing is named after what it points
at"* rule. Upstream's nearest issue, **#4685**, is an OAuth/RFC 9728 request labelled `COULD` —
**do not plan around it landing.**

**UNVERIFIED, and the one pre-flight:** whether the provider treats `hostname` as
`RequiresReplace`. Settle it with `nix run .#mcp-public-plan` before asserting blast radius —
`mcp-public.nix:43-44` demands schemas be verified against the pinned provider, not from docs.

### Riskiest step

**Packaging (§6), not Cloudflare.** Specifically: **relaxing `starlette` 1.3.1 against a `>=1.6.0`
floor**. `pythonImportsCheck` proves the module tree imports; it does not prove starlette 1.3.1
exposes the ASGI APIs ContextForge calls. Upstream starlette is at 1.7.0, so the pin is four
minors behind current — **not a lag nixpkgs closes next week**. This cannot be settled without
running the gateway.

**Second, and it deserves its own paragraph: statefulness.** Today the roster is *entirely* a
function of the Nix closure. ContextForge registers servers into a **database**. The declarative
route is `POST /servers` driven from Nix at agent start — still an idempotent-reconcile problem
against mutable state, and it brushes against `mcp-scout`'s *"installation IS declaration; there
is no other path."* **How a Nix-declared roster reconciles into that DB on every activation is
the genuine unanswered design question.**

**Third:** `main.py` warms a **fork-based jq sandbox before the DB probe**, and its own comment
calls a failure there *"a hard startup failure [that] must propagate"* — while naming **Linux**.
**aarch64-darwin behaviour is UNVERIFIED.**

## 8. Side-by-side cutover — the recommendation

**This is the strongest recommendation this ADR can make, and it needs no Cloudflare change for
the entire proving period.**

1. **Phase 1 — local only, zero terranix, zero risk.** Add `contextForgePort = 8098` to
   `identity.nix` and a **second** Home Manager launchd agent beside `mcp-gateway`. Both run.
   `packages.mcp-worker-probe` already speaks raw MCP `initialize` over HTTP — point it at
   `http://127.0.0.1:8098/servers/<uuid>/mcp` and diff tool counts, startup time and per-server
   readiness against `:8097`. **No apply, no registration, no client reconfiguration.**
2. **Phase 2 — cutover is one line.** `mcp-public.nix:461` `service = "http://127.0.0.1:<port>"`.
   Plan, apply. The portal URL, the 27 registrations, the service token, the DNS record and every
   client config are untouched. **Rollback is the same line reversed.**
3. **Phase 3 — delete the old agent** only after a full activation cycle proves the new one comes
   back at login.

**The one wrinkle, stated now rather than discovered:** during overlap **both gateways spawn their
own copy of every stdio server**. That is the exact cost that killed the old two-proxy split —
`modules/shared/mcp.nix:118-119` records ~50 processes and *"two copies fighting over one Gmail
credential file, one MTProto session and one memory graph."* **Mitigation, mandatory: prove
ContextForge against the 10 `domain`-tier read-only servers first** (`mcp-public.nix:229-241` — no
credentials, no persisted state) before pointing it at `memory`, `postgres` or any `gmail-*`.

## 9. Rejected — and why, so it is not re-litigated

| Option | Verdict | Why |
|---|---|---|
| **MetaMCP** | Rejected | **Containerised**, so `desktop-commander` and `macos-automator` lose host filesystem and AppleScript access — a showstopper, not a tuning problem. Compounded by being **unmaintained since 2026-06-22**. |
| **Docker MCP Gateway** | Rejected | **Container per server.** Same showstopper, by design rather than by accident. |
| **mcphub** (`samanhappy/mcphub`) | Rejected — **the runner-up** | Lost on *artifact shape*, not language. It publishes **source**: three native node modules (`better-sqlite3` and `bcrypt` via node-gyp, `@huggingface/tokenizers` via napi/Rust) plus a separate `tsc` + `vite build`. `fetchPnpmDeps` gives you the store but not a working `node-gyp` rebuild, and it pins `pnpm@10.12.4` against the pin's 11.25.0 — the exact `fetcherVersion` trap `packages/metube.nix` and `packages/yt-dlp-web-ui.nix` already document. ContextForge publishes a **pure prebuilt `py3-none-any` wheel** with the UI already inside and 40 of 41 deps in nixpkgs. **"Python is easier" is true for these two specifically — it is not a general rule.** |
| **Doing nothing** | **Chosen for now** | See §1.3 and §11. |
| **27 `translate` sidecars in front of the *existing* `mcp-proxy`** | **NOT rejected — deferred, and it is the honest cheaper option** | Zero new dependencies, zero new secrets, zero URL churn, zero packaging. It fixes §2's barrier outright, because the barrier is one process spawning 27 children sequentially. It buys **none** of §5's identity story. |

## 10. What this gives up — stated, not buried

1. **Human-readable URLs.** `/servers/desktop-commander/mcp` becomes 32 hex characters. A
   Nix-side name→UUID table in the module header is a workaround, not parity, and it breaks
   `mcp-public.nix`'s own naming rule.
2. **Zero-secret operation.** Today's gateway needs **no** secret. ContextForge needs a JWT signing
   key and an encryption passphrase at minimum — and `AUTH_ENCRYPTION_SECRET` becomes a **second**
   lose-it-and-lose-everything passphrase alongside `tofu:state:passphrase`.
3. **A purely closure-derived roster.** A database enters a path that today is 100% Nix.
4. **~28 extra processes and 27 extra ports** on a laptop already running 2 GitHub runners, Tart
   VMs, Colima and a 31 GB ollama model store. **No upstream figure exists for per-sidecar RSS —
   ContextForge publishes no laptop baseline at all.** The only numbers upstream are production
   ceilings (<400% CPU / 4 GB for 16 workers). **This is unmeasured and it is the number that
   decides laptop viability.**
5. **A large multi-tenant surface to solve a single-user problem.** Teams, RBAC, SSO, A2A routing,
   SIEM export, 40+ plugins — for one human's 27 loopback servers. CLAUDE.md's motto says a
   framework *"bigger than the problem warrants"* is **also** a violation. §11's triggers exist
   precisely so that surface is only taken on when something needs it.
6. **A version treadmill with breaking minors.** ~2-week cadence plus *"expect breaking changes
   between minor versions"* means pinning a tag and bumping deliberately, forever.

## 11. Trigger conditions — what starts the migration

**Re-pointed by the §1a amendment.** The question is NOT "when do we replace `mcp-proxy`" — on this
evidence, never: ContextForge cannot do its job. It is **"when would we self-host the portal
layer"**, and the honest baseline answer is *when Cloudflare stops being the right place for it*.
Triggers 1-3 below are the per-user-credential path; **trigger 6 is the one that would move this
on its own.**

Checkable, in priority order. **Any one is sufficient.**

| # | Trigger | How it is checked |
|---|---|---|
| 1 | **A client gains per-request custom headers.** grok.com grows a header field, **or** claude.ai's request-header beta becomes generally available **and** mutable **and** allows an operator-chosen name. | Read the vendor's connector docs; the claude.ai constraints are named in §5 — all four must fall. |
| 2 | **A second identity needs the same server with different credentials** and Trigger 1 has already fired. | The operator wants `github` under two accounts simultaneously **and** a client can carry the distinction. Without Trigger 1 this is unreachable and the answer stays two named gateway entries with two Keychain keys. |
| 3 | **`translate`-sidecars-in-front-of-`mcp-proxy` is tried and fails.** | The §9 deferred option is implemented and the ~29.4 s barrier does not fall, or per-agent supervision proves unworkable. Then the decomposition must come with a gateway that expects it. |
| 4 | **`pkgs.mcp-proxy` stops being maintained**, or #229/#232 land a breaking change this fleet cannot follow. | `nix search`/upstream releases: no release in 12 months, or the fleet's config shape no longer expressible. |
| 5 | **ContextForge enters nixpkgs.** | `nix search nixpkgs contextforge` returns a result, or `python3Packages ? mcp-contextforge-gateway` is `true`. This collapses §6 — the single largest cost — to near zero. |

| 6 | **Cloudflare stops being the right home for the portal layer.** The MCP Portal leaves beta on terms this fleet will not take, starts charging per server, is deprecated, or the fleet leaves Cloudflare. | A pricing/deprecation notice, or an operator decision to move off Cloudflare. This is the trigger that would move this ADR **on its own merits** — every other trigger is about credentials. |

**Counter-trigger — what would *un*-name it:** the project archives or stalls (no release in 6
months); a critical advisory class reaches a loopback-only single-user deployment; `cpex`'s
`contextforge-org` stops publishing; or `mcphub` ships prebuilt artifacts with no native modules,
which would re-open §9's runner-up.

## 12. Open, not decided

1. **Laptop footprint is unmeasured.** ~57 processes, no upstream baseline. §10.4.
2. **How a Nix roster reconciles idempotently into ContextForge's DB.** §7. This is the real
   design gap, and it is the one most likely to make the migration ugly.
3. **The jq sandbox's fork-based warm-up on aarch64-darwin.** §7. A hard startup failure path
   whose own comment names Linux.
4. **Whether `hostname` is `RequiresReplace` on the pinned Cloudflare provider.** §7. One
   `mcp-public-plan` settles it.
5. **Whether relaxing `starlette` by three minors works at runtime.** §6. Unresolvable without
   running it.
6. **Whether the `wrapper.py` stdio-corruption bug the prior art patched still exists in 1.0.10.**
   The file was restructured enough that neither confirmation nor denial was possible.

## 13. Correction record

*Empty.* Nothing has been executed. When it is, what execution finds the design got wrong goes
here, and where §13 and an earlier section disagree, §13 is what the tree does.

## Found in passing — stale counts, unrelated to this decision

`kapture` was added 2026-09-23 and four in-repo counts did not follow it:

| Location | Says | Is |
|---|---|---|
| `modules/shared/mcp.nix:407` | "Eleven of the 14 base ones" | 15 base |
| `modules/shared/mcp.nix:755` | "26 today" | 27 |
| `modules/parts/identity.nix:170` | tier brackets "must sum to 26", machine-control `[4]` | 27, and `[5]` |
| `modules/shared/mcp.nix:118-119` vs `docs/mcp-gateway.md:28` | "50 processes for 25 servers" vs a table saying 26 | they disagree with each other |

`serverTier` itself is correct (14 operator + 3 trusted + 10 domain = 27). Also: `CLAUDE.md:399`
and `docs/repo-map.md:2789-2790` both still say ADR-004 is "Phase 1 of 3 shipped" while
`docs/secrets-recovery-and-identity-adr.md:3` says all three shipped — cheap to fix in the same
edit that adds this ADR's index rows.