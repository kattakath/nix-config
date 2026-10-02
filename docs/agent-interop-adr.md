# ADR-007 — Cross-agent interop: ACP as the rail, and the two paths that are closed

**Status:** **DECIDED 2026-09-29. Partially implemented** — `acpx` packaged and installed
(§7a), the two stale agent pins bumped (§7b). The Antigravity lane is **closed on licensing**
(§4) and the `claude mcp serve` lane is **closed on security** (§3). Nothing further is
planned; §8 names the conditions that would reopen either.

**The ask, verbatim:** *"We have Grok Build and Antigravity CLI installed … Is there a way
Claude Code can (or vice-versa) effectively utilize them when required? … By extending the AI
Agents to each other, powerful things can be done which otherwise would not be possible …
see if there's any industry standard framework/protocol/setup for this."*

**Verdict:** the notion is sound and a real standard exists — but it is **not** the one the
question implies, **two of the motivating premises are false**, and the most obvious
implementation would have silently disabled every guardrail in this repo.

---

## 1. Framing correction

All three CLIs are agent **harnesses**, not models. The sharper point is that all three are
already **MCP clients with plugin systems and headless contracts**, and all three are in the
**ACP agent registry**. The problem was never "can they talk" — it was "over which protocol,
in which direction, and at what cost".

| | headless | MCP client | MCP server | ACP agent |
|---|---|---|---|---|
| `claude` 2.1.268 | `-p` | yes | **yes** (`mcp serve`) | via `claude-agent-acp` |
| `grok` 1.0.45 | `-p/--single` | yes | no | **native** (`grok agent stdio`) |
| `agy` 1.2.13 | `-p/--print` | yes | no | via `agy_acp_server.par` |

---

## 2. The protocol landscape, and why ACP wins

| Protocol | Transport | Verdict for one macOS box |
|---|---|---|
| **ACP** (Zed, Agent *Client* Protocol) | JSON-RPC over **stdio** | **CHOSEN** |
| MCP | stdio / Streamable HTTP | Right for *tools*, wrong for *agents* |
| **A2A** (Google → Linux Foundation) | HTTPS / gRPC only | **REJECTED — transport fit** |
| ACP (IBM/BeeAI, *Communication*) | REST | **DEAD** — archived 2025-08-25, merged into A2A |
| AGNTCY, AG-UI | — | Wrong layer (discovery; agent↔frontend) |

**A2A is the rejected option that deserves naming**, because it is the one most people would
reach for. It is genuinely mature — v1.0 GA, 8-company LF TSC, six SDKs. It loses on one
fact: **every binding is network**, discovery is keyed to a signed `.well-known` URI on a
domain, and the security model exists to keep agents from *different organisations* opaque to
each other. On one machine under one UID that is all cost and no benefit — you would stand up
TLS and OAuth so one binary could call another.

**Decisive measurement (2026-09-29):** A2A strings present in the three agent binaries —
`claude` **0**, `agy` **0**, `grok` **0**. MCP strings in the same binaries, as a positive
control — **686 / 2,013 / 188**. The protocol is not merely unadopted here; it is absent.

**MCP is not the answer either, by its maintainers' own direction.** The `sampling` primitive
— the only one that let a server run a nested agent loop — is **deprecated** (SEP-2577,
stated cause "low client adoption"), eligible for removal 2027-07-28. MCP's design principle
#3 also forbids a server from seeing conversation context, which blinds any agent placed
behind a tool boundary. The sanctioned direction is **Skills over MCP** — ship instructions,
not a black-box agent.

**The one caveat on ACP:** agent→agent *chaining* is an RFD with a published prototype, not a
shipped feature. ACP today is a **client↔agent** protocol. `acpx` is the client.

---

## 3. CLOSED: `claude mcp serve` into the other agents

The obvious move is one command per agent:

```
agy  mcp add claude-code claude mcp serve
grok mcp add claude-code -s user claude -- mcp serve
```

Both are accepted. **Do not do this.** Measured 2026-09-29 against `claude` 2.1.268 over a
real JSON-RPC stdio handshake — every guardrail layer in this repo was bypassed:

| Control | Result |
|---|---|
| User-scope `permissions.deny` (28 entries, incl. `Bash(age -d*)`) | **BYPASSED** |
| Same, with project scope loaded | **BYPASSED** |
| Project `PreToolUse` hook (`pretooluse-bash-guard.js`) | **NEVER FIRED** |
| `Read(//run/agenix/**)` deny | **BYPASSED** |
| `--settings` with blanket `deny: ["Bash"]` | **BYPASSED** |
| `--restricted` / `--permission-mode plan` / `--tools` | accepted, **no effect** (or server dies silently) |

This is **documented intended behaviour**, not a defect —
[Anthropic's MCP docs](https://code.claude.com/docs/en/mcp): *"The server only exposes Claude
Code's tools to your MCP client, so your own client is responsible for implementing user
confirmation for individual tool calls."*

The consequence is specific to this fleet: **`modules/home/claude-guardrails.nix`, the
superhook guard and `modules/darwin/claude-managed-settings.nix` are all client-side.** On
this path there is no client of ours, so the managed-settings tier — the one that "cannot be
retracted by any lower scope" — is simply not on the wire.

Two further reasons, either sufficient on its own:

- **~23.1k tokens per turn, forever.** The 26 exposed tool schemas measure 92,533 bytes;
  `Bash` alone is 12,136. Every `grok`/`agy` turn would carry that.
- **Wrong abstraction.** It exposes *hands*, not a *mind*: you get `Bash(command)`, never
  `ask_claude(prompt)`.
- **It outlives whatever started it.** Added 2026-09-29, after the research that produced
  this ADR demonstrated the failure on itself: the subagent probing `claude mcp serve` ran
  a ~20-second pipeline, reported `completed`, and left the server **alive for 59 minutes**.
  A pipeline ending in a stdio server does not exit when its writer finishes — the server
  holds stdin open and the whole tree hangs. It then **ignored `SIGTERM`** and needed
  `kill -9`. So the surface with no permission gate is also the one that quietly stays
  resident after the thing that launched it is gone. Check `ps`, not the agent list.

**If inbound delegation is ever wanted, the answer is `claude-agent-acp`**, which has a
permission round-trip and a session, not a raw toolbox.

---

## 4. CLOSED: wrapping Antigravity at all

Two independent findings, either of which closes the lane.

**(a) The premise was false.** Measured from the `init` event of a real headless `agy` run —
the complete 57-tool list contains **no YouTube tool, no Drive, no Docs, no Maps**. The
binary does contain `YoutubeVideoContext`, `GoogleDriveSource`, `GoogleMaps_*` symbols, but
those are google3's vendored **datapol/proto-visibility annotation registry** plus
enterprise-only knowledge-base connectors — not capabilities. `search_web` exists but returns
**prose, not grounding chunks**; the public Gemini API's `google_search` + `url_context` are
strictly more transparent.

So the motivating example — "Antigravity has privileged access to YouTube transcripts" — does
not hold. There is no Google-proprietary data access here that Claude Code lacks.

**(b) It is a named licensing breach.** [antigravity.google/terms](https://antigravity.google/terms/),
verbatim:

> *"Using third party software, tools, or services to access the Service (e.g. using OpenClaw
> with Antigravity OAuth) is a breach of this Agreement. Such actions may be grounds for
> suspension or termination."*

An MCP shim, an `acpx` wrapper, or a LiteLLM route over the Antigravity **login** is the
literal named example. This is a licence term, not a technical limit, so no amount of
engineering makes it acceptable.

**The ToS-clean alternative, if the capability is ever wanted:** the Gemini API managed agent
(`POST …/v1beta/interactions`, documented as "the same harness as the Antigravity IDE"),
billed pay-as-you-go against a Gemini API key — not the consumer Antigravity session.

Packaging `agy` itself stays fine: installing a vendor's CLI and running it interactively is
what it is for. What is closed is **driving it from another agent**.

---

## 5. OPEN and already solved: the Grok lane

Claude→Grok delegation needs **no new code**. `xai-grok-build` — installed, and **authored by
xAI** — already ships a 1,107-line bridge with a `grok-delegate` subagent, session transfer,
`--resume`, background jobs, and `--permission-mode plan`, running under this repo's own
`nix-agent-workspace` sandbox profile (`modules/home/default.nix`).

That sandbox is the part worth keeping in view: it is **kernel-enforced** (macOS Seatbelt) and
denies `~/.ssh`, `~/.aws`, `~/.docker`, `~/.config/gh`, `**/*.pem`, `**/*.age`, `**/.env`.
**No equivalent profile exists for `agy`** — which is a second, independent reason §4 stays
closed.

### 5a. Images: delegate to the CLI, do NOT call the API

Two research passes reached opposite conclusions here, so the reasoning is recorded rather
than the answer alone. The disagreement dissolves once the **billing lane** is named:

| Path | Who pays |
|---|---|
| `grok` under **session auth** (this machine) | **The SuperGrok subscription** — no marginal cash |
| `api.x.ai/v1/images/generations` | **Prepaid API credits** — $0.04–$0.05 per image, real cash |

So the general rule "an API-shaped capability does not deserve an agent loop" is **correct in
general and wrong here**: the agent loop is already paid for, and the API is not.

**The trap that makes this load-bearing:** `XAI_API_KEY` **takes precedence over session
credentials**. Exporting it into the environment of any delegation wrapper silently moves
image spend onto prepaid billing. Do not set it there.

**Model pin:** `grok-imagine-image-quality` ($0.05) retires **2026-11-02**, redirecting to
`grok-imagine-image-2.0` at `quality:"low"`. 2.0 is *cheaper* ($0.04) and is the id xAI's docs
recommend, so `~/.grok/config.toml` now sets `features.image_gen_model_override` explicitly
rather than inheriting the remote default. That file is **not** Nix-managed (deliberately —
it holds session credentials), so this is operator state, recorded here because it is
otherwise invisible.

---

## 6. Cost — why delegation is not free

Measured 2026-09-29, trivial prompt ("Reply with exactly: OK"):

| Invocation | Cost | Wall |
|---|---|---|
| `claude -p --model haiku` (full config: CLAUDE.md + plugins + skills) | **$0.2362** | 2.8s |
| same, `--safe-mode` (customizations off) | $0.0047 | 0.9s |
| `grok -p --sandbox read-only` | 53,851 input tokens before the prompt is read | ~8s |
| `agy -p --model gemini-3.8-flash-low` | **quota 429** | 108s, 6 retries |

**A trivial delegation into our own Claude Code costs 50× the same prompt with customizations
off.** The scaffolding is the bill, not the task. Delegation earns its keep for a genuine
second opinion or a fresh context window — not for a capability that is really one API call,
and never for "Claude reasoning via Antigravity" (which would be paying Google to proxy
Anthropic).

---

## 7. What was implemented

### 7a. `acpx`, packaged and installed

`packages/acpx.nix` → `environment.systemPackages` in `hosts/macos.nix`, beside `grok` and
`agy`. It is the only maintained headless ACP client, and it carries the controls a hub needs:
`--permission-policy` (autoApprove/autoDeny/escalate/defaultAction), `--deny-all`,
`--allowed-tools`, `--max-turns`, `--timeout`, `--format json`, `--no-fs`, `--no-terminal`.
`acpx compare` runs one prompt across several agents.

Three packaging traps, all measured, all recorded in the package header:

- Upstream ships **pnpm-lock.yaml and no package-lock.json**, so `buildNpmPackage` cannot
  consume it — `fetchPnpmDeps` + `pnpmConfigHook` is the supported path.
- **`fetcherVersion = 2` was REMOVED in the 26.11 release**; 4 is required.
- **`pnpmConfigHook` does not bring `pnpm` with it** (the deprecated `pnpm.configHook` did) —
  omitting it fails with `'pnpm' binary not found in PATH`.

`engines.node >= 22.13` is real, and the fleet default `nodejs` is 20.x, so the package pins
`nodejs_22` itself rather than inheriting.

### 7b. Two stale pins bumped, and the verification doctrine corrected

| Package | Was | Now |
|---|---|---|
| `grok` | 1.0.30 | **1.0.45** |
| `antigravity-cli` | 1.2.4 | **1.2.13** |

`packages/grok.nix`'s header claimed *"grok is closed-source … there is no source to build."*
**That is now false** — `xai-org/grok-build` is Apache-2.0 Rust with a `Cargo.lock`. The
header was corrected: the reasons that survive are signature preservation and keeping a Rust
toolchain out of the closure, not the absence of source.

Its verification doctrine also changed. The original pin was byte-compared against the copy
the vendor's updater had left in `~/.grok/downloads` — a check only available for a version
the updater happened to fetch, and weak anyway (both copies come from the same bucket, so it
proves transport, not origin). **Bumps are now verified by Mach-O signature**, which is
strictly stronger:

```
codesign --verify --strict <artifact>   # exit 0
Authority=Developer ID Application: X.AI Corporation (5Y6N3AJ54S) → Apple Root CA
```

`antigravity-cli` gets a **better** check than grok, because Google publishes one. The build
id in its URL (`1.2.13-6662628811079680`) is not derivable from the version and must be read
from the vendor manifest, whose endpoint comes from `DOWNLOAD_BASE_URL` in
`https://antigravity.google/cli/install.sh`:

```
curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_arm64.json
→ { "version", "url", "sha512" }
```

The vendor `sha512` matched byte for byte for 1.2.13. `agy` is **also** Developer ID signed
(Google LLC, `EQHXZ8M8AV`), and that survives the derivation — it needs no `dontFixup` because
the payload is extracted by the `installPhase` rather than unpacked as a source.

---

## 8. What would reopen a closed path

- **§3 (`claude mcp serve`)** — reopens only if Anthropic gives the served surface a
  permission gate that honours `permissions.deny` and `PreToolUse`. Until then, `-p` or
  `claude-agent-acp` under `acpx --permission-policy` is the inbound answer.
- **§4 (Antigravity)** — reopens only on a licence change, or by moving to the Gemini API
  managed agent with its own key. A capability finding alone is not enough; the ToS is the
  binding constraint.
- **ACP v2** — the schema sits at `v2.0.0-alpha.5` beside stable v1. A2A's own v0.3→v1.0 jump
  was wire-breaking and stranded its bridge ecosystem, which is the precedent to watch.

---

## 9. Weakest assumptions

1. **That ACP v2 lands compatibly.** This is the load-bearing bet behind §7a. *What would
   settle it:* the published v2 migration note.
2. **That `acpx`'s registry breadth is depth.** The "41 agents" count is from ACP's own
   registry, which does not distinguish native in-tree support from a thin wrapper. Only three
   were verified individually. *What would settle it:* `initialize` + `session/new` +
   `session/prompt` against each, diffing which `session/update` events and `fs/*` /
   `terminal/*` methods are actually honoured.
3. **That `image_gen` is reachable from headless `grok -p`.** Inferred from the tool enum, not
   measured; the docs call `/imagine` "conditionally available", which is about entitlement
   rather than headless mode. *What would settle it:* one `grok -p … --output-format
   streaming-json` and a read of the `available_commands` event.

---

## 10. Sources

Primary, all read 2026-09-29: [agentclientprotocol.com](https://agentclientprotocol.com) ·
[openclaw/acpx](https://github.com/openclaw/acpx) ·
[a2aproject/A2A](https://github.com/a2aproject/A2A) ·
[MCP 2026-07-28 deprecations](https://modelcontextprotocol.io/specification/2026-07-28/deprecated) ·
[SEP-2577](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2577) ·
[ACP→A2A wind-down](https://lfaidata.foundation/communityblog/2025/08/29/acp-joins-forces-with-a2a-under-the-linux-foundations-lf-ai-data/) ·
[code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp) ·
[antigravity.google/terms](https://antigravity.google/terms/) ·
[docs.x.ai/developers/models](https://docs.x.ai/developers/models) ·
[docs.x.ai pricing](https://docs.x.ai/developers/pricing)
