# ADR-011 — Grafana Cloud as the fleet's observability hub

**Status:** **DECIDED 2026-11-02; steps 1–5 LIVE 2026-11-03** (§ 6). The decisions in § 3 are the operator's,
taken click-to-select after a read-only census. Each build step (§ 6) lands as its own PR and is
proven by a real datapoint arriving and a dashboard panel returning data.

**Question.** How do signals from every corner of the fleet — hosts, CI, SaaS, and the
operator's life domains (career, finance, work-life, happiness) — reach one place that can
visualise them, alert on them, and show improvement trends longer than a SaaS retention window?

## 1. Verdict

- **Hub:** the existing Grafana Cloud stack `kattakath` (free tier). OTLP push in, PromQL/LogQL out.
- **Fits the free tier with room:** the census estimates **~3.1k of 10k active series (31%)** and
  **~2.4 of 50 GB logs/month (5%)** for the full plan — *if* the three filters in § 5 ship with it.
- **Long history is not Grafana's job.** A daily, deterministic rollup copies one row per KPI per day
  into a Drive Sheet; Grafana charts it back. Retention stays a cache, never the record.
- **The privacy boundary is the stack.** Persona-tier signals go to a **separate stack**; finance
  leaves its source only as ratios.

## 2. Census (method, not data)

- A 9-agent read-only sweep (8 corners + 1 merger) on 2026-11-02 found **81 unique sources** from
  115 corner rows. It read shapes and counts only — no values, titles or amounts.
- The census itself is **not in this repo** (it carries per-person figures — the no-data rule). It
  lives with the operator's Workspace notes.
- **Largest blind spot:** `nixpi` ships nothing today, and was unreachable during the sweep, so
  every nixpi figure is an estimate the first nixpi PR must re-measure.
- **Prerequisite found:** the stack had **0 alert rules and 0 contact points**. Nothing could page.

## 3. Decisions

| Area | Decision | Rejected alternative, and why it lost |
|---|---|---|
| Claude Code OTel (`modules/home/claude-otel.nix`) | **Metrics only** to Grafana (~150 series); `session.id` never a label. Logs stay in the local file. | Filtered logs too — ~1 GB/mo and the record carries `tool_input`; the local file already serves `/routing-review`. |
| Alerts | **Email** contact point to the operator identity's address. | Slack — client-shared workspace; healthchecks.io channel — needs a webhook for no gain. |
| Discreet / persona domain | **Separate Grafana stack and org**, never linked to `kattakath`. | Restricted folder in the main stack — folder permissions would be the only wall, and every session's Grafana connector reaches the main stack. |
| Long-term history | **GitHub Actions daily cron → deterministic script → Drive Sheet**, keyless auth by Workload Identity Federation (`google-github-actions/auth`) to a new service account in `infra/gcp/foundation.nix`; Grafana's official Google Sheets datasource reads it back. | Claude cloud routine — the model would sit in the data path (ADR-010 lane rules; "no bulk data through the model"), and plugin MCP servers measured **403** in cloud runs. A Mac launchd job — misses every day the Mac sleeps. |
| Home | **This repo**: ADR, rollup job, WIF account, shippers. | A new `kattakath/observability` repo — a second home for one design. |
| nixpi shipper | **Grafana Alloy** (`services.alloy`, pinned nixpkgs `nixos/modules/services/monitoring/alloy.nix`), WAL in `/run` so the SD card takes no writes; substituted from Cachix, never built on the Pi. | node-exporter (67 MiB vs 449 MiB closure) — logs would need a second agent, two configs, two pins. |
| nixpi credential | **Firmware-partition plant** (the `nixpi-provision` lane `cloudflared-token.age` already uses), a write-only token. | Host-decrypted agenix — a reflash rotates the host key; pull from the Mac — only works while the Mac is awake. |
| Mac shipper | **Extend the existing `otelcol-contrib`** in `claude-otel.nix` (host metrics + self-telemetry pipelines). | nix-darwin (pin `ff0e21a4`) and home-manager (pin `095fef2f`) ship **no** Alloy or otelcol module — grepped; only `services.prometheus.exporters.node` exists on nix-darwin, which covers metrics alone and adds a second agent. |
| CI | **Grafana GitHub datasource plugin** — query-time, 0 stored series; read-only fine-grained PAT kept in Grafana. | A pushed queue-wait metric — 9 samples so far; deferred. |
| Probes | **Synthetic Monitoring HTTP** (public site + Access host, TLS and domain expiry), **credential-expiry** gauges, **backup age**, **GitHub security-alert counts**. | ICMP — stayed green through the 8-day 2026-10 outage. |
| Finance | **Ratios and freshness only**, computed **at source** (the ledger build pushes counts; raw data never reaches a collector). | Absolute CAD — a financial-tier leak if the stack is ever exposed; collector-side redaction — one bad filter leaks rows. |
| Career | **Application funnel** (stage counts, weekly velocity, days since last application; stage enum normalised first) + the **live evidence-quality** gauges. | Gmail and interview-calendar counts — not chosen. |
| Work-life | **Work hours = Mon–Fri 09:00–17:30 America/Toronto**, one constant. Every work-life *source* is **deferred**. | Calendar work blocks — only as good as calendar hygiene. |
| Happiness | **Deferred** — the operator names these signals; none are guessed. | — |

## 4. Signal model

| Kind | Use for | Transport |
|---|---|---|
| Heartbeat | "did it run" | healthchecks.io, the `fleet.heartbeats` registry (`modules/parts/heartbeats.nix`) |
| Metric | counts, gauges, ratios | OTLP push (collector, Alloy, or a best-effort script) |
| Log | troubleshooting only, WARN+ | Alloy `loki.source.journal` on nixpi; otelcol `filelog` on the Mac |
| Annotation | deploys, activations | Grafana annotations from `activate` / deploy |

- **Every pipeline copies the agentic-jobseek evidence pattern** (its ADR-0007 § 5): heartbeat →
  structured run record as source of truth → deterministic script turning it into OTLP,
  best-effort (never fails the job) → dashboard → alert only where action is needed.
- **Naming:** `<domain>_<thing>_<unit>`, snake_case, closed-enum labels only. Sparse gauges are read
  with `last_over_time(...[30d])` or they blank after 5 minutes.

## 5. What NOT to collect

- **Cardinality bombs:** `session.id` as a label (~41k series); repo, company or bundle-id labels.
- **Volume bombs:** the raw macOS unified log (~350 GB/mo — 7x the tier); unfiltered Claude logs.
- **Content:** prompt and transcript bodies, `tool_input`, email/calendar/Slack text, payees,
  amounts, client IPs, SSIDs, heartbeat URLs (they embed the ping key), secret names or values.
- **Neon by connection:** a DB scrape wakes compute and burns the free CU cap; use the API.

## 6. Build order (one PR each), and what actually shipped

| Step | What | Status |
|---|---|---|
| 1 | Alerting baseline — email contact point, 70% usage alerts, root policy → email | **Done** (Grafana: folder `fleet`, group `free-tier`) |
| 2 | Audiobookshelf health | **Folded into 4.** `serviceHeartbeat.requireUnits` means "public site not serving", and Audiobookshelf is LAN-only, so it is in Alloy's unit allowlist and alerted by Grafana instead |
| 3 | Claude Code metrics via the existing collector | **Done** — #1046; #1047 adds `deltatocumulative` (Claude Code exports DELTA sums, which the OTLP gateway rejects with HTTP 400) |
| 4–5 | nixpi Alloy metrics + journald → Loki | **Done as one PR** — #1048 (Grafana group `nixpi`). Knock-on: the SD image passed GitHub's 2 GiB asset limit; #1049 re-encodes it at zstd -19 (−14.7%) |
| 6 | GitHub datasource plugin | **Done** — Grafana datasource `github`, authenticated as the read-only GitHub App `kattakath-grafana-readonly` (org repos; the private key lives only in Grafana). The operator chose an App over an expiring PAT |
| 7 | Synthetic probe, credential expiry, backup age, security-alert counts | **Done** — Synthetic Monitoring check `nixpi-public-site` (3 probes, 5 min; it covers TLS expiry). `packages/fleet-gauges.nix` (hourly launchd agent `nix-fleet-gauges`) pushes credential expiry, open GitHub security alerts and Time Machine state. The Access host is NOT probed: Cloudflare's edge answers 302 even with the tunnel down |
| 8 | Mac host metrics in the existing collector | **Done** — a `metrics/host` pipeline (otelcol `hostmetrics`: cpu, memory, load, paging, 3 volumes, `en*` interfaces), `service_name="macos-host"`, ~170 series measured |
| 9 | Finance at-source ratios push | |
| 10 | Career funnel + evidence quality | |
| 11 | Daily rollup (WIF account, Sheet, Sheets datasource) | **Done** (#1053; run 41573492727 wrote 19/21 KPIs and `fleet-history` read it back) — `infra/gcp/foundation.nix` (WIF pool admitting ONLY `grafana-rollup.yml`@main by numeric repo/owner id; keyless writer; read-only reader), `.github/workflows/grafana-rollup.yml` + `scripts/grafana-rollup.py`, Grafana datasource `fleet-history`. The Sheet is a STORE only. The reader holds the stack's one Google key: Grafana Cloud's WIF mode runs as the signed-in user and breaks alerting and public dashboards |
| 12 | Separate persona stack — its own design, its own identity | **Deferred by operator 2026-11-03.** Until it exists, nothing persona-tier goes into the `kattakath` stack |

## 7. Weakest assumptions

- **WIF → Sheets write** on a Workspace-owned Sheet shared to the service account. Standard, but
  unmeasured here — step 11 proves it with one real row.
- **nixpi numbers** are estimates (unreachable during the census) — step 4 re-measures.
- **Retention:** the brief said 14 days; the stack label reads 31 days for logs. Either way the
  Sheet holds the trend, so the decision does not hinge on it.
