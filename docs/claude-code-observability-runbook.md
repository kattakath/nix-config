# Claude Code routing telemetry — operator runbook

Claude Code ships native OpenTelemetry support
(`CLAUDE_CODE_ENABLE_TELEMETRY=1`) that emits a `claude_code.tool_decision`
event on every tool-permission decision, tagged with a `source`
(`config`/`hook`/`user_temporary`/`user_permanent`/`user_reject`/`user_abort`).
That `source` field is exactly the deterministic-vs-model-judgment signal
this fleet needs: every `user_temporary`/`user_permanent` decision is a
routing choice a human still had to make in the moment, and a recurring one
is a concrete candidate for the next `pretooluse-bash-guard.js`-style
hardening pass. This runs a local
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) as a
launchd agent to receive that telemetry and land it in a file for `/routing-review`
to analyze — no external service, no dashboard, nothing leaves the machine.

## Pieces

| Piece | Role | Lives |
|---|---|---|
| `services.claudeOtel` | Enables the collector + generates its config; exposes `otlpEndpoint`/`eventsFile` options | `modules/shared/claude-otel.nix` |
| `otelcol-contrib` (`pkgs.opentelemetry-collector-contrib`) | The collector binary itself — official upstream, prebuilt/substitutable on `aarch64-darwin`, no local compile | nixpkgs |
| `launchd.agents.claude-otel-collector` | Always-on launchd agent (same `RunAtLoad`/`KeepAlive` shape as `mcp-gateway`), auto-wrapped to `nix-claude-otel-collector` by `hm-launchd` | `modules/shared/claude-otel.nix` |
| `programs.claude-code.settings.env` | The `CLAUDE_CODE_ENABLE_TELEMETRY`/`OTEL_*` env vars Claude Code reads from `~/.claude/settings.json` at startup | `modules/shared/home.nix` |
| `~/.local/state/claude-otel/events.jsonl` | Rotating JSONL (50 MiB, 5 backups) of `claude_code.*` log events | `$HOME`, never in git/store |
| `nix run .#claude-otel-doctor` | Runtime health check: launchd agent loaded, OTLP port listening, events file freshness | `packages/claude-otel-doctor.nix` |
| `/routing-review` | Reads the events file, buckets `tool_decision` by `source`, proposes deterministic hardening | `.claude/commands/routing-review.md` |
| `routing-review-digest.js` | `SessionStart` nudge — mirrors `superhook-digest.js`: surfaces unreviewed `user_temporary`/`user_permanent` decisions in context, only once a small threshold is crossed | `.claude/hooks/routing-review-digest.js`, wired in `.claude/settings.json` |

## Scope: real Mac only

Gated on `isMacosHost` (`networking.hostName == "macos"`) — the same gate as
the RAG stack, MCP public tunnel, and telegram. `macvm` keeps base Claude
Code + the MCP gateway but gets no telemetry collector and no `env` block,
same as those other Mac-only sub-features. This is a deliberate scope limit,
not an oversight: `macvm`'s own Claude Code sessions (as the `aloshy`
persona) are not captured by this system.

## Setup

None beyond normal activation — `darwin-rebuild switch --flake .#macos` (or
via `nix-personal`, see the fleet's standard activation runbook) brings up
the collector and writes the env block. No OAuth, no accounts, no manual
step. Verify with:

```bash
nix run .#claude-otel-doctor
```

## What's captured, and why (the privacy scoping decision)

Only `OTEL_LOGS_EXPORTER=otlp` is set — no metrics exporter, no traces
exporter (traces need Anthropic's beta flag and add nothing this system
needs). Within logs, `OTEL_LOG_TOOL_DETAILS=1` is **on**, deliberately: it's
required to see real `tool_name`/`skill.name`/`mcp_tool_name` values instead
of redacted `custom`/`mcp` placeholders — without it, the whole point of the
system (which specific skill/tool/command is being routed by judgment)
is invisible.

`OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`, and
`OTEL_LOG_RAW_API_BODIES` are **left unset**. None of them are needed for
routing analysis — they'd capture actual prompt/response text and full API
request/response bodies, which this system has no use for and should not
retain. What lands in `events.jsonl` is tool/skill/decision metadata only:
which tool, which skill, which MCP server, accept/reject, and the decision
source. Never prompt or response content.

## Trigger for the review loop: a SessionStart nudge, not a schedule

`routing-review-digest.js` runs at every `SessionStart` (same mechanism as
`superhook-digest.js`): it reads `events.jsonl`, filters to
`user_temporary`/`user_permanent` `tool_decision` events newer than
`.claude/hooks/.routing-review-state.json`'s `reviewedAt`, and — only once
that count crosses `NUDGE_THRESHOLD` (currently **3**, a provisional
placeholder chosen before any real usage data existed) — prints a one-line
summary into context suggesting `/routing-review`. Below threshold, or if
already reviewed, it stays completely silent (never blocks, never throws).

This is deliberately **not** a scheduled/cron job — it only fires when
you're already in a Claude Code session, mirroring every other log-review
loop in this repo (`/superhook-review`, `/pretooluse-review`). Retune
`NUDGE_THRESHOLD` once real sessions show the actual volume of
human-judgment decisions; there was zero real data when `3` was picked.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `claude-otel-doctor` reports launchd agent NOT LOADED | Config not activated yet, or activation predates this feature | `darwin-rebuild switch --flake .#macos` |
| `claude-otel-doctor` reports OTLP port NOT LISTENING | Collector crashed or never started — check its log | `tail ~/Library/Logs/claude-otel-collector.log` |
| Events file absent | No Claude Code session has run with telemetry active since the collector came up | Run a Claude Code session, then re-check |
| `events.jsonl` has entries but `skill.name`/`mcp_tool_name` show as `custom`/`mcp` | `OTEL_LOG_TOOL_DETAILS` didn't take effect — settings not activated, or a stale Claude Code session predates the env change | Re-activate, then start a **new** Claude Code session (env vars are read at process startup) |
| `events.jsonl` lines fail to parse (leading NUL bytes / garbage before the JSON) | **Never manually truncate `events.jsonl` while the collector is running** — the process holds its own file handle and write offset; an external truncate (`: > events.jsonl`) desyncs that offset from the file's actual size, and the next write lands past a hole of NUL bytes (a sparse file), corrupting that line. Found and reproduced during this feature's own verification. | Restart the collector to reset its offset cleanly (`launchctl kickstart -k gui/$(id -u)/org.nix-community.home.claude-otel-collector`), *then* remove/truncate the file — never the other way around. Normally you should never need to do this manually at all: the file exporter's own rotation (`max_megabytes`/`max_backups`) handles size management. |

## Security notes

- Everything is **localhost-only** — the collector binds `127.0.0.1:4317`
  (grpc) / `127.0.0.1:4318` (http); no external network egress, no auth
  token, no TLS needed because nothing crosses a network boundary.
- No prompt or response content is ever captured (see scoping section
  above) — only tool/skill/decision metadata.
- `events.jsonl` lives under `$HOME`, never in the Nix store or git.
- This is a personal, single-operator observability tool, not a
  multi-tenant or fleet-wide telemetry pipeline — no `OTEL_RESOURCE_ATTRIBUTES`
  team/org tagging is configured, since there's no second consumer of this
  data.

## Source

| Path | What |
|---|---|
| `modules/shared/claude-otel.nix` | Collector config generation + launchd agent |
| `modules/shared/home.nix` | Import + `services.claudeOtel.enable` + `programs.claude-code.settings.env` |
| `packages/claude-otel-doctor.nix` | Health check, wired as `nix run .#claude-otel-doctor` |
| `.claude/commands/routing-review.md` | The analysis/hardening-proposal loop |
| `.claude/hooks/routing-review-digest.js` | `SessionStart` nudge, registered in `.claude/settings.json` |
| `.claude/hooks/.routing-review-state.json` | Gitignored — `reviewedAt` bookkeeping shared by the digest and the review command |
