# ADR-013 — The doctors: what they cover, what gauges take over, and how a run reports

**Status:** **DECIDED 2026-11-03** (every decision here is the operator's, chosen click-to-select).
Docs only; each move in § 5 is its own later PR. § 6 has a **blocker** for the Desktop lane.

**Question.** This repo has two "doctors": `/hygiene` (skill `nix-hygiene`) and `/fleet-doctor`.
Which past incidents would they have caught, which would only an automatic check catch, and which
would nothing catch? What should move out of an agent session into an hourly gauge? And what must
a doctor run emit, so that two runs can be compared without reading prose?

## 1. Verdict

- **Two doctors, two questions. They stay separate.** `/hygiene` audits the repo's **desired
  state**. `/fleet-doctor` audits whether **the world matches it**. Fleet-doctor composes hygiene
  in its step D, and that stays.
- **Coverage today: 46% automatic, 39% doctor-only, 14% nothing** (28 incidents, § 3).
- **Moves 1–6 (§ 5) turn most doctor-only finds into gauges.** One mechanism for all six:
  `fleet-gauges` reads a JSON summary hourly, pushes it to Grafana, and an alert rule fires.
- **Doctors READ gauges and judge; they do not re-measure.** What stays agent-run is doc-truth,
  intent vs effect, triage, and every fix and merge.
- **A doctor run becomes deterministic** (§ 7): default `audit`, reads `origin/<default>`, exits
  0/2/1, reports `vacuous` when it examined nothing, and gives every finding a stable ID.
- **Output formats are standards** (§ 8): **SARIF 2.1.0** for `/hygiene`, the **health check
  response format** draft for `/fleet-doctor`. SARIF is not uploaded to GitHub for now.

## 2. Method

A coverage study on 2026-11-03: every incident recorded in this repo's docs, PRs and agent memory,
classified by what first caught it (or would have). The full study holds per-person and
per-account detail, so it stays out of this repo (the no-data rule). This ADR keeps the shapes.

Standards were each checked at the source the same day (§ 8 gives URLs and versions).

## 3. The 28 incidents

**Caught by** = what catches the class **today**. "Doctor" means only an agent run would.

| # | Incident | Caught by today | Move |
|---|---|---|---|
| 1 | Tunnel dead 8 days (09-23 → 10-01), a FAT mount | Grafana public-site-down + hc nixpi-serving | — |
| 2 | nixpi off the LAN (09-16) | covered | — |
| 3 | A deploy cut its own tunnel (10-21) | symptom only | 6 |
| 4 | Home uplink dies | covered (uplink-watchdog) | — |
| 5 | Counterfeit SD card, rootfs | read-only alert, symptom only | a `nixpi-flash` capacity guard |
| 6 | **Inert nixpi heartbeat (11-02)** | **NONE** | **1** |
| 7 | Rollup cron with no heartbeat | parity check (#1069) | — |
| 8 | Guard missed the new applies | check (#1068) | — |
| 9 | Alloy redaction leak (#1075) | log-redaction check | 5, for new shapes |
| 10 | Frozen nix-ci badge | doctor | 4 |
| 11 | Stale doc claims | doctor | generate, don't write |
| 12 | A check passing on zero tokens | doctor | the `vacuous` rule (§ 7) |
| 13 | `docs-indexed` skipped `docs/map` | doctor | the same class as 12 |
| 14 | fleet-gauges duplicate-label push failure | the stopped-reporting alert | — |
| 15 | A silent `tmutil` failure | doctor | 2 |
| 16 | **Dry-run poisoned the narinfo cache** | **NONE** | **6** |
| 17 | A darwin break from a nixpkgs bump (#895) | advisory darwin leg | require darwin on `flake.lock` PRs |
| 18 | A brew formula removed (#833) | doctor | a brew existence gauge |
| 19 | Access app vanished (08-20) | daily drift (ADR-012) | — |
| 20 | cf-tunnel state/render split | guards + drift | — |
| 21 | Google re-auth lapse | drift `reauth` label | — |
| 22 | build-installers: 10 `startup_failure`s | doctor | 4 |
| 23 | Plugins enabled by click only | doctor (fleet-doctor E5) | a gauge, later |
| 24 | launchd orphans | doctor (`launchd-doctor`) | 3 |
| 25 | **Leaked or stuck agent processes** | **NONE** | optional `ps` gauge |
| 26 | **Comment-only activation that changed nothing** | **NONE** | judgment; stays agent-run |
| 27 | Managed settings skipped (#756) | check | — |
| 28 | Tart fleet key readable by login processes (open) | doctor (hygiene judgment) | — |

### Coverage

| Caught by | Count | Share |
|---|---|---|
| An automatic check, alert or guard | 13 | 46% |
| Only a doctor run | 11 | 39% |
| Nothing | 4 | 14% |

Shares are of 28 and rounded, so they sum to 99%.

### Blind spots, by shape

- **Silence that looks like health** (6, 12, 13, 15): a sender that never sends, a check over
  zero inputs. An alert on "down" never fires for a thing that was never up.
- **Caches and side effects of our own tools** (3, 16): the tool works, the effect is wrong.
- **Process state outside any declaration** (24, 25): nothing declared it, so nothing diffs it.
- **Intent vs effect** (26): only judgment sees that a change did nothing.

## 4. What each doctor is

| | `/hygiene` (nix-hygiene) | `/fleet-doctor` |
|---|---|---|
| Question | Is the desired state clean? | Does the world match it? |
| Reads | the repo at `origin/main` | repos, hosts, CI, gauges |
| Typical finding | stale doc count, dead option, comment rot | red CI, stray branch, unactivated generation |
| Output standard | SARIF 2.1.0 | health check response format |
| Composes | `nix fmt`, `nix flake check` | `/hygiene` (step D), `launchd-doctor`, `activate` |

## 5. Moves 1–6 (adopted)

Each move adds a JSON summary that `fleet-gauges` reads hourly, a Grafana series, and an alert rule
in the terranix Grafana stack (ADR-012 § 5 step 2).

| # | Move | Closes | Note |
|---|---|---|---|
| 1 | healthchecks.io check status as a gauge; alert on `new` and `down` | 6 | `new` = never pinged. A read-only hc API key, read from the Keychain at run time, never a Nix string |
| 2 | Alert on fleet-gauges' own source errors | 15, and every silent source | a source that errors is today a missing series, not a red one |
| 3 | `launchd-doctor --json` (#1062) as a gauge | 24 | |
| 4 | Workflow conclusions + SD-release asset age | 10, 22 | `startup_failure` counts as red |
| 5 | Loki redaction canary | 9, new shapes | plant a known-fake address and MAC, alert if it arrives unredacted |
| 6 | Deploy guard | 3, 16 | see below |

**Move 6, in two parts:**

- **A Bash-guard nudge** (not a block) on `deploy --targets .#nixpi` without `--hostname`. The
  guard already tells the operator to use the LAN when cloudflared restarts; this asks at the
  moment it matters.
- **`narinfo-cache-negative-ttl = 0` by default** on the Mac. It goes in
  `determinateNix.customSettings`, because `nix.settings` is dropped on this host (the comment in
  `modules/parts/checks.nix` says why). It is inert until the daemon restarts. **Cost:** every
  path that is genuinely absent from the caches is re-queried on every build instead of once an
  hour. That is a few extra HTTPS round-trips, accepted to remove incident 16's whole class.

## 6. Scheduled audits — report-only

| Doctor | Lane (ADR-010) | Cadence | Precondition |
|---|---|---|---|
| fleet-doctor `audit` | Claude Desktop local task | weekly, Monday afternoon, after the `update-flake-lock` PR | **the blocker below** |
| nix-hygiene `audit` | cloud routine | weekly or every two weeks | one proof run shows the cloud lane can run the gates |

- **Every scheduled doctor gets a declared `fleet.heartbeats` entry.** Schedules are not
  declarative (ADR-010 § 4), so a lost schedule must alert from the declared side.
- **Where findings go:** the run's JSON to Drive (the no-data rule); counts to Grafana; a GitHub
  issue only for a finding the operator accepts.
- **Scheduled runs never fix and never merge.**

**BLOCKER for the Desktop lane.** ADR-010's census (2026-11-01) listed six tasks under
`~/.claude/scheduled-tasks/`. On 2026-11-03 that directory is **empty** (zero entries, last
modified 2026-11-01). Nobody has explained why. Until it is explained — moved, deleted, or never
there — the Desktop lane is not relied on, and fleet-doctor's schedule waits.

## 7. Deterministic runs with no arguments

| Today | Decided |
|---|---|
| Both skills default to `fix` | **Default = `audit`.** `fix` must be asked for |
| Reads the checkout, whatever branch it is on | **Reads `origin/<default>`**, never the checkout |
| Prose report | Exit **0** clean, **2** findings, **1** error. A `warn` or `fail` makes it 2 |
| A section that examined nothing reads as clean | That section reports **`vacuous`**, never clean |
| Findings are sentences | **Stable finding IDs**, so runs diff into new / resolved / persisting |

## 8. Standards adopted

### SARIF 2.1.0 — `/hygiene`'s output

- **Source:** OASIS, *SARIF Version 2.1.0 Plus Errata 01*, OASIS Standard, 28 August 2023
  ([spec](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html),
  [schema](https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json)).
  The enums below were read from that schema.

| SARIF field | Allowed values (schema) | How we use it |
|---|---|---|
| `tool.driver.rules[].id` | string | one rule per nix-hygiene checklist item, e.g. `NH-D-stale-count` |
| `result.ruleId` | "the stable, unique identifier of the rule" | the rule's id |
| `result.level` | `none`, `note`, `warning`, `error` | fixed per rule, never chosen per run |
| `result.kind` | `notApplicable`, `pass`, `fail`, `review`, `open`, `informational` | `pass` = examined N > 0 inputs, no finding; **`notApplicable` = vacuous** |
| `result.partialFingerprints` | strings that "contribute to the stable, unique identity of the result" | `findingId/v1` = hash of rule id + file + construct (never a line number) |
| `result.baselineState` | `new`, `unchanged`, `updated`, `absent` | new → `new`, persisting → `unchanged`, resolved → `absent` |
| `result.locations` | physicalLocation | file + construct; a line only where one exists |

**GitHub code scanning: SARIF yes, upload no — for now.**
Checked at [Uploading a SARIF file](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github)
and [SARIF support](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning):

- The upload is `github/codeql-action/upload-sarif` (v4 in the examples) or the REST
  `code-scanning/sarifs` endpoint. Limits: 10 MB gzipped, 25,000 results per run (top 5,000 shown).
- **GitHub dedupes only on `primaryLocationLineHash`.** It ignores any other fingerprint key, so
  our `findingId/v1` would not drive its alert identity.
- **A result needs `locations[]` with a file and region to display.** Doc-truth and
  intent-vs-effect findings have no single line.
- **Free on a public repo: not stated.** The pages say only that a *private* repo needs a GitHub
  Code Security license. This repo is public. Not verified further.
- This repo has **no code-scanning analyses** today (the analyses API returns 404).

So the scheduled hygiene run writes SARIF to Drive and does not upload. Revisit when most rules
carry a real line location (§ 11).

### Health check response format — `/fleet-doctor`'s output

- **Source:** *Health Check Response Format for HTTP APIs*, `draft-inadarei-api-health-check-06`,
  2021-10-16 ([datatracker](https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check-06)).
- **It is an EXPIRED individual Internet-Draft, not an RFC.** The datatracker marks it "Expired &
  archived", with "no formal standing" in the IETF process.
- **Why it still fits:** we take its vocabulary and envelope, not an API we depend on. Nothing
  else names this shape as well, and it is small enough to freeze.

| Draft element | What it says | How we use it |
|---|---|---|
| `status` (required) | `pass`, `fail`, `warn`; aliases `ok`/`up` and `error`/`down`; case-insensitive | the run's overall status. We emit only the three base words |
| `checks` | keys `componentName:measurementName`, each value an **array** of objects | one key per fleet-doctor step, e.g. `macos:launchd-orphans` |
| check object | `componentId`, `componentType`, `observedValue`, `observedUnit`, `status`, `time`, `output`, `links`, … | `observedValue` = count; `output` = the finding ID list |
| extra keys | user-defined keys allowed; unknown keys MAY be ignored | **vacuous** = `status: warn`, `output: "vacuous"`, `observedValue: 0` |
| media type | `application/health+json` | the file's declared type |

`vacuous` rides as `warn`, so a reader that knows only the base vocabulary still never reads it as
`pass`. The draft's HTTP rule (pass/warn → 2xx–3xx, fail → 4xx–5xx) maps to our exit codes:
pass → 0, warn or fail → 2.

### Practices this rests on — considered, deferred

| Practice | Where it shows up here | Why not adopted as a framework |
|---|---|---|
| GitOps drift reconciliation | ADR-012's daily drift check; fleet-doctor's world-vs-repo question | we detect and report; a reconciler that applies on drift is out of scope |
| SRE toil elimination (Google SRE book) | moves 1–6 take repeat measurements out of agent sessions | adopted as the reason, not as a process |
| Fitness functions (*Building Evolutionary Architectures*) | each rule in § 9 is one | the flake checks already are the fitness functions |
| Policy-as-code (OPA / conftest) | the rule table in § 9 | a second policy language beside ast-grep and flake checks; deferred until a rule cannot be written in either |

## 9. Opinionated for the AI

Every rule has an **ID**, a **fixed severity**, a **detection command** and the **evidence** the
finding must carry. The output must validate against the schema. The AI's judgment goes into
**triage** — is this real, what fixes it — never into choosing what to check.

Example rule entry:

```yaml
id: NH-D-stale-count
level: warning                  # fixed; SARIF result.level
checklist: nix-hygiene § D
detect: >
  grep -rnE '\b[0-9]+ (checks|capsules|rules|hosts)\b' docs CLAUDE.md
  and compare each number with the live count from nix eval / ls
evidence:
  - file and construct where the number appears
  - the claimed number and the measured number
  - the command that measured it
vacuous_when: the grep returns zero lines
fix_hint: delete the count or point at the generated table (never restate a new count)
```

## 10. The Mac has no Time Machine destination — accepted

**Recovery = rebuild from the flake + data in Drive + Keychain values from the GCP Secret Manager
copy (ADR-004).** The backup alert is demoted to an **info** gauge.

What that does **NOT** cover, plainly:

- **Unpushed local work** — commits, branches, stashes and uncommitted files not on a remote.
- **App state outside Nix and Drive** — app preferences, local databases, browser profiles, chat
  history, anything an app keeps in `~/Library` that is not declared.
- **Keychain items never pushed** to the GCP copy.

A mitigation for the first item, if wanted later: fleet-doctor step A already reports unpushed
branches; a gauge would make it hourly.

## 11. What would reopen a decision — and the weakest assumptions

| Assumption | Why it is weak | What settles it |
|---|---|---|
| **Alerts actually reach the operator** | every move ends in an alert nobody has test-fired | test-fire each new rule once, end to end |
| A never-pinged hc check stays silent | true by design until move 1 lands; incident 6 proved it | move 1, then a deliberately unpinged test check |
| The cloud lane can run the gates | a fresh clone may lack Nix or the time budget | one proof run before scheduling hygiene |
| The Desktop lane is in use | `~/.claude/scheduled-tasks/` is empty (§ 6) | explain the empty directory |

Would reopen:

- Most hygiene rules carry a real file+line → upload SARIF to code scanning.
- The health check draft is revived or replaced by an RFC → follow the RFC.
- A rule cannot be written as an ast-grep rule or a flake check → reconsider OPA/conftest.

## 12. Alternatives that lost

| Rejected | Why |
|---|---|
| Merge the two doctors into one | they answer different questions; one skill would mix desired state with live state |
| Doctors re-measure everything each run | costs a full agent session for numbers a gauge already holds |
| A custom JSON report schema | SARIF and the health check format exist; a third shape is a second copy to drift |
| Upload SARIF to code scanning now | GitHub dedupes only on a line hash, and many findings have no line |
| Scheduled doctors that fix | an unattended fix with no reviewer; fixes stay operator-triggered |
| Time Machine to a new disk | the operator accepts rebuild-from-flake; § 10 records the cost |
