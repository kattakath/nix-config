---
name: fleet-doctor
description: >
  Fleet-wide consistency sweep across every repo in the fleet manifest:
  stray branches/worktrees, unmerged PRs, red CI, Nix store garbage,
  launchd drift, terranix drift, heartbeats, nixpi unit health, nixpi
  cache warmth, and unactivated host generations (macos). Use when asked to "clean up the fleet", "sync everything",
  "is everything in sync", "garbage collect and activate", or after a
  multi-repo change (identity rename, secret rotation, cross-repo pin bump)
  that needs to land and propagate everywhere. Composes git-purity,
  pr-title, nix-hygiene (for nix-config itself), and the existing
  activate/GC tooling — not a replacement for any of them.
---

# fleet-doctor

**Problem this solves:** a change that starts in `nix-config` (e.g. a rename,
a secret rotation, a shared-input bump) has downstream effects across every
repo in the fleet manifest, both hosts, and the Nix store — branches to
clean up, PRs to land, pins to bump, generations to GC, hosts to
re-activate. Doing that by hand, repo by repo, is what this skill replaces.

## Fleet manifest

`.claude/skills/fleet-doctor/fleet-repos.txt` — one repo per line, relative
to `~/Developer`. This is the fleet — **not** every repo on disk; the file's
own header says what qualifies, and each orbit line carries its reason.
Add a line there when a new fleet repo is created; nothing else in this skill
needs to change.

**The seven extracted satellites are gone from this list, on purpose.** ADR-002
absorbed each one into `nix-config` as a `modules/features/<name>/` capsule and
archived its repo, so sweeping it would report stale branches nobody can merge.
A satellite still on disk is a working copy that outlived its remote — do not
re-add it.

**`[redacted]` is RETIRED (2026-09-15).** Every value it held is folded directly into
this repo (`hosts/macos.nix`, `modules/parts/identity.nix`). The cross-repo pin-bump step
existed only to serve it and collapsed with it; the letter it held is now **D. Nix-config's
own hygiene**, and there is no step G. **Host re-activation did NOT collapse** — it is step
F below. The checklist runs A, B, C, D, E, E2–E9, F.

`activate` did NOT go with it. The CLI that was retired was [redacted]'s
freshness-gated one; this repo grew its own the same day (`packages/activate.nix`,
114c9a4) and it is the activation command CLAUDE.md names — a self-elevating
`darwin-rebuild switch` that works from any directory and prints the flake dir and
branch@rev before it builds. Step F below already runs it.

## Modes

1. **`audit`** — **the default** (ADR-013 § 7). Read-only: every `FD-*` rule over the whole
   manifest, fix nothing. Two runs at the same subject SHA check the same things.
2. **`fix`** — only when asked. Audit, then apply everything in the **auto-fix** table below
   without asking per-repo (the command invocation itself is the explicit ask — same
   convention as `/hygiene fix`). Still stops and asks before anything in the **always
   confirm** table.
3. **`scope <repo|host>`** — explicit narrowing only: one manifest entry (repo name) or one
   host (`macos`). Every check outside it reports `status: warn`, `output: "skipped: scope"`.

## Subject, rules and output

**Subject = nix-config's `origin/<default>`.** `git fetch origin` first and record its SHA. The
manifest and every repo-DECLARED fact (E5's declared plugins, E8's unit list, F's expected
system) are read at that SHA, from a detached snapshot, never from the checkout this session
is on. The WORLD (branches on disk, launchd, hosts, CI) is what gets compared against it.

```bash
git fetch origin
sha=$(git rev-parse "$(git symbolic-ref --short refs/remotes/origin/HEAD)")
snap="${TMPDIR:-/tmp}/fleet-doctor-$sha"
git worktree add --detach "$snap" "$sha"     # the steps below read "$snap/…"; remove it after
```

**Rules = the catalogue**, [`../doctors/rules.json`](../doctors/rules.json): every `FD-*` entry
fixes the `statusOnFinding` (`warn`|`fail`), the `checkKey` it reports under, its `detect`
method, the `evidence` and its `vacuousWhen`. Each step below names its rules.

**Output = health+json** (the expired `draft-inadarei-api-health-check-06` vocabulary, ADR-013
§ 8), checked by `doctor-report` (`nix run .#doctor-report --`):

| Field | Rule |
|---|---|
| `status` | `pass`, `warn` or `fail` only — the worst check's |
| `releaseId` | the subject SHA |
| `checks["<component>:<measurement>"]` | an ARRAY of check objects, one key per `FD-*` rule; `componentId` names the instance (repo, label, slug) |
| check object | `ruleId`, `status`, `observedValue` = finding count, `inputsExamined`, `output` = the finding IDs, space-separated |
| finding ID | `doctor-report fingerprint <ruleId> <subject> <construct>` (e.g. `FD-B-red` + `kattakath/skills#12` + the check name). **Except `FD-D-hygiene`**: `doctor-report hygiene-for` wraps the hygiene SARIF's IDs (step D) |
| vacuous | `inputsExamined: 0` → `status: warn`, `observedValue: 0`, `output: "vacuous"` — never `pass` |

`doctor-report skeleton fleet-doctor <sha>` starts the file; `validate` checks it (every rule's
key present, statuses consistent; given step D's SARIF as a second file, FD-D must match it);
`verdict` exits **0** pass, **2** warn or fail, **1** invalid;
`publish fleet-doctor <file>` files it under
`${DOCTOR_REPORT_DIR:-${XDG_STATE_HOME:-~/.local/state}/nix-config-doctors}/fleet-doctor/` with a
`latest` symlink; `diff <old> <new>` lists new / resolved / persisting finding IDs. Composed step
D's own SARIF is filed separately under `hygiene/`.

## Fix policy — read this before running `fix`

| Auto-fix (no per-repo prompt in `fix` mode) | Always confirm first |
|---|---|
| `git fetch --prune` (read-only) | Merging any PR, for any reason |
| Reporting host disk usage (per-volume, see step E) — collection is automatic now | Deleting a branch/worktree with commits not on its remote/default branch |
| — | Committing/pushing anything that isn't this skill's own mechanical fix (stray WIP is reported, never committed) |
| Deleting a **local-only branch already merged into the repo's default branch** | Force-push, `git reset --hard`, `git clean -f`, any destructive git op |
| Re-running `nix fmt` / the repo's own format-fix on a repo already being touched | Reactivating a host when the guest/host is unreachable — report as skipped, don't retry-loop |
| Re-activating macos (`activate`) when its composing repos moved | Disk operations of any kind (`diskutil`, partitioning) |
| Nixpi: **read-only reports only** (disk usage, E8's unit status) — no GC/activation/restart without an explicit ask (it's the live server; see `docs/nixpi-sd-flashing-runbook.md`) | Rotating secrets/tokens, editing `secrets/*.age`, anything with `secret set` |
| E6–E9 (drift, heartbeats, nixpi units, cache warmth): **report only**, in every mode | Any `*-apply` (E6's remedy is a re-login or a reasoned plan, never an apply), `hc-checks-apply`, re-running a workflow |
| — | `sudo nix-collect-garbage -d` on the host — determinate-nixd collects in the background on macos (on nixpi its collector is `disabled` and the weekly `nix.gc` timer collects — `modules/nixos/core.nix`), and `-d` drops **every** old generation, leaving no rollback target |

These map onto the global Git Safety Protocol (never commit unless asked,
never force-push, never merge without explicit confirmation) — `fix` mode
never overrides that; it only pre-authorizes the specific mechanical,
easily-reversible fixes listed above, matching how this fleet was actually
brought into sync by hand in the session this skill was extracted from.

## Checklist (run in order)

### A. Per-repo: branches, worktrees, sync — `FD-A-*`

Read the manifest, then for each repo run one consolidated pass rather than
one tool call per repo:

```bash
while read -r repo; do
  [ -z "$repo" ] && continue
  case "$repo" in \#*) continue ;; esac
  d="$HOME/Developer/$repo"
  [ -d "$d" ] || { echo "MISSING: $repo (not cloned locally)"; continue; }
  echo "=== $repo ==="
  git -C "$d" fetch --prune -q
  git -C "$d" status --porcelain          # dirty? never auto-touch this
  git -C "$d" branch                      # local branches — flag anything but the default
  git -C "$d" worktree list               # more than one entry is a finding
  def=$(git -C "$d" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##')
  git -C "$d" rev-list --left-right --count "origin/${def:-main}...${def:-main}" 2>/dev/null
done < "$snap/.claude/skills/fleet-doctor/fleet-repos.txt"
```

Findings: any local branch that isn't the default and has no unique commits
ahead of its remote counterpart → auto-fix (delete). Any branch/worktree
with unique unmerged commits, or any dirty `git status`, → report only.

### B. Per-repo: open PRs — `FD-B-*`

```bash
gh pr list --repo <owner>/<repo> --state open   # ${repo#github.com/} of a manifest line \
  --json number,title,isDraft,mergeStateStatus,statusCheckRollup,autoMergeRequest
```

Multiple open PRs are **normal** — each change gets its own PR, and the merge queue lands them
([`auto-merge-and-merge-queue.md`](../../../docs/auto-merge-and-merge-queue.md) §3).

Findings are: a PR whose title doesn't follow
[`pr-title.md`](../../rules/pr-title.md), a stale PR with no activity, one
sitting on red CI, or one **never armed** — `autoMergeRequest == null` AND
`isInMergeQueue == false` (GraphQL only — `gh pr view --json` rejects that field) on a non-draft PR means `auto-merge.yml` did not arm it and it will
sit open forever. (GitHub clears `autoMergeRequest` once the PR is enqueued, so a queued PR
reads null too: nix-config #1036, 2026-11-02.) How drafting interacts with arming (it DROPS it; `ready_for_review` re-arms): see
[`pr-title.md`](../../rules/pr-title.md) § CORRECTED 2026-10-02.

Read `autoMergeRequest.enabledBy.login`, not just the field's presence: it must
be `app/ismailkattakath-ci`. Anything armed by `github-actions` means something
used `GITHUB_TOKEN` — which merges SILENTLY and stops every `push: main`
workflow from firing, the failure that doc calls its single most important
detail. That is a finding even though the PR looks healthy.

Report CI status per PR; never merge here regardless of mode — see the confirm
table above.

### C. Per-repo: latest CI run — `FD-C-red-run`

```bash
gh run list --repo <owner>/<repo> --limit 1 --json workflowName,conclusion,createdAt,headBranch
```

A red/failed latest run is a finding, not an auto-fix — diagnosis is
repo/workflow-specific (see this session's Cachix-name and
`update-flake-lock` fixes as examples of "why generic auto-fix doesn't
work here"). Suggest a fork to investigate if the user wants it fixed now.

### D. Nix-config's own hygiene — `FD-D-hygiene`

If nix-config itself is in scope, compose the **nix-hygiene** skill
(`.claude/skills/nix-hygiene/SKILL.md`) rather than re-deriving its
checklist here — run it in the same mode (`audit`/`fix`) fleet-doctor was
given, **at the subject SHA**. Never hand-copy its findings: derive the check object.

```bash
doctor-report hygiene-for "$sha" [<hygiene.sarif>]   # default: the hygiene `latest`
# 0 → the FD-D-hygiene check object; put it in checks["nix-config:hygiene"] as printed
# 3 → that SARIF is for ANOTHER SHA: either run /hygiene at "$sha" and call it again, or
#     report the object it printed — warn, inputsExamined 0,
#     "skipped: hygiene run is for <sha12>, subject is <sha12>". Never its findings.
# 1 → the SARIF is invalid
```

Its `output` WRAPS the SARIF's own IDs: `FD-D-hygiene/<findingId/v1>` per failing result
(e.g. `FD-D-hygiene/NH-D-stale-count/1a2b…`) and `FD-D-hygiene/<NH rule>/vacuous` per
`notApplicable` rule. The NH id stays readable, and stripping the prefix gives the SARIF's ID,
so a fleet-doctor `diff` and a hygiene `diff` move together. Then
`doctor-report validate <health.json> <hygiene.sarif>` proves the pair agrees: it rejects an
FD-D whose findings come from a hygiene run for another subject.

### E. Garbage collection — `FD-E-disk-free`

**macos collects itself now.** `determinateNix.determinateNixd.garbageCollector.strategy
= "automatic"` (2026-09-15, `modules/parts/compose.nix`) hands background collection to
determinate-nixd, and `customSettings.auto-optimise-store = true` hard-links duplicates as
paths land. So this step is a **report**, and a hand-run collection is only for "I want the
space back now" — not routine upkeep.

```bash
# host — per VOLUME. NOT `df -h /nix`: on APFS, df's "Used" is the whole shared
# container (measured 2026-10-21: df said 792G "used" on /nix while the Nix Store
# volume held 34.9 GB; the Data volume held 782 GB, so a GC freed only 2.1 GiB).
diskutil info /nix | grep -E 'Volume Used Space|Container Free Space'
diskutil info /System/Volumes/Data | grep 'Volume Used Space'
sudo nix-collect-garbage -d     # only on an explicit ask; the background collector
                                # otherwise handles this, and `-d` drops EVERY old
                                # generation, leaving no rollback target

# nixpi — report only, never collect without an explicit ask (live server)
```

### E2. Determinate Nix version drift (macos) — `FD-E2-nix-version`

The Mac's Nix is upgraded by `sudo determinate-nixd upgrade`, NOT by `activate` — the
`determinate` flake input only pins the NixOS hosts' Nix. Nothing else reports the drift
(found 2026-09-21: 3.22.4 running while 3.22.5 was advised). Report it; upgrade only in
`fix` mode:

```bash
determinate-nixd status 2>&1 | grep -m1 -i 'now available' || echo "determinate-nixd: current"
sudo determinate-nixd upgrade     # fix mode only; restarts the daemon (seconds)
```

### E3. launchd units: declared vs loaded, exits, log growth (macos) — `FD-E3-*`

`nix flake check` proves what the config **says**. Nothing proved what launchd actually
**did** — which is how `activate-agenix` and both `github-runner-macos-*` daemons sat outside
the system domain for ~21h on 2026-09-22, taking `/run/agenix` and five CI lanes with them,
across four activations that each reported success. Report only; every remedy needs root:

```bash
nix run .#launchd-doctor -- --json    # {"scope":N,"sections":{…},"rc":N}; rc 1 = findings, exit code unchanged
nix run .#launchd-doctor              # the same findings as text, for a human (LAUNCHD_DOCTOR_WARN_KB tunes the log threshold)
```

Parse the JSON (#1062): `rc`, then every array under `sections.*` — each element carries a
`kind`. One code path renders both (`packages/launchd-doctor.nix` header), so the table below,
keyed by the printed section, is also the key to the JSON. Read the section, not the row count:
`loaded` alone carries two kinds. The expected `ok … agenix boot race` row is text-only — it
is not a finding, so the JSON omits it.

| JSON `sections.<key>` → `kind` | Printed section |
|---|---|
| `loaded` → `not-loaded`, `nonzero-exit` | `--- loaded ---` |
| `orphaned` → `orphaned` (or `skipped`: no generation manifest to compare) | `--- orphaned plists ---` |
| `logSize` → `log-over-threshold` | `--- log size ---` |
| `disabled` → `disabled` | `--- launchd disabled-DB … ---` |
| `strayLogs` → `candidate` | the `~/Library/Logs` orphans section |
| `powerAssertions` → `unbounded` | `--- unbounded power assertions ---` |

| Printed section | Finding | Urgency | Remedy |
|---|---|---|---|
| `--- loaded ---` | `NOT LOADED` | **act now** — a fleet unit is silently absent | `sudo launchctl bootstrap <domain> <plist>`; `modules/darwin/launchd-reconcile.nix` makes the next activation do it. The doctor offers that remedy **only** when a current generation declares the unit — otherwise it points you at `ORPHANED` instead of resurrecting something deliberately retired |
| `--- loaded ---` | `EXIT <n>` | investigate — loaded but failing every spawn | read the unit's log; `exit 78` is the boot/mount race, not a crash |
| `--- loaded ---` | `ok … expected agenix boot race` | **none** — a runner daemon that exited 1 once at boot and is now running with `runs = 2` | nothing; left unfixed on purpose (`launchd-naming.md` § A CRASH is retried). Any other shape stays `EXIT <n>` |
| `--- orphaned plists ---` | `ORPHANED` | **act now after any rename/removal** — a plist installed that NO current generation declares | `launchctl bootout <domain>/<label> ; rm <plist>`. nix-darwin's removal loop is **single-transition** (pinned `modules/system/launchd.nix:150-161`), so an orphan it missed at that one generation boundary stays orphaned **permanently** and keeps running — re-activating never clears it. Check it on the first `activate` after a rename — e.g. `metube`/`yt-dlp-web-ui` moving to Home Manager on 2026-09-22 renamed `org.nixos.*` → `org.nix-community.home.*`. An orphan that exits 0 is invisible everywhere else |
| `--- log size ---` | a log over `LAUNCHD_DOCTOR_WARN_KB` | **investigate — NOT routine since 2026-09-22** | every declared launchd log now reaches a rotator (`modules/darwin/logging.nix`): `system.newsyslog` rename+create for the jobs that re-exec, hourly `logrotate --copytruncate` for the long-lived `KeepAlive` ones, which newsyslog by design can never reclaim. An oversized log therefore means a **broken rotator**, not physics — check the two ticks are in their domains (`launchctl print gui/$UID/org.nix-community.home.file-rotation-logs`, `sudo launchctl print system/org.nixos.file-rotation-logs-system`), then their own logs and state files (`~/.local/state/logrotate/agents.state`, `/var/lib/logrotate/daemons.state`) |
| `--- launchd disabled-DB (fleet labels reading 'disabled') ---` | a fleet label launchd has DISABLED | **not** cosmetic: its `bootstrap` fails with **error 119** | run the `remedy: launchctl enable …` line the doctor prints, before blaming the plist |
| the `~/Library/Logs` orphans section (`packages/launchd-doctor.nix`, section (e)) | a log no installed unit writes | cosmetic | litter from a removed feature; delete only when sure the feature is gone |
| `--- unbounded power assertions ---` | `UNBOUNDED` — a `caffeinate` with no utility, `-t` or `-w` | **act now** — on a `pmset sleep 1` host the Mac never sleeps again | kill that pid, then give its caller a `-w`/`-t`/utility. Not a launchd unit; it lives here since #760 made the CI runners hold a wake assertion per job (the `-w` form, deliberately not flagged) |

**Never bootstrap in `fix` mode without asking.** It is under **always confirm**: starting a
daemon the operator deliberately booted out is exactly the wrong move, and
`/etc/nix-darwin/launchd-hold/<label>` is the supported way to keep one down. That hold
answers `NOT LOADED` only — an `ORPHANED` unit must never be bootstrapped at all.

### E4. One owner per stdio MCP server (macos) — `FD-E4-mcp-twin`

Claude Code never dedups stdio servers, so a server two plugins both name spawns twice and
the model picks either copy. The fleet removes known twins with NAME denies
(`programs.claude-code.settings.deniedMcpServers`, `modules/home/default.nix`). A name deny
fails SILENTLY if upstream renames the server key, and this step is the guard. Report only:

```bash
claude mcp list 2>/dev/null | grep -cE '^plugin:(aws-core|aws-serverless|cloudflare|slack|neon):'   # must print 0
claude mcp list 2>/dev/null | grep -c  '^plugin:[^:]*:aws-mcp:'               # must print 0
claude mcp list 2>/dev/null | grep -c  '^claude\.ai AWS MCP:'                  # must print 1 (the one AWS path)
```

The first line asks whether the server-denied plugins (every `serverName` in
`deniedMcpServers`; keep this list in step with it) start ANY server, not whether a
name is gone: a renamed server key would slip past a name check but still shows up here.
Non-zero means a deny no longer matches, so read `claude mcp list` and update the
`serverName` entry.

### E5. Enablement drift: clicked but undeclared plugins (macos) — `FD-E5-undeclared-plugin`

A `/plugin` toggle writes only the live `~/.claude/settings.json`, so a plugin turned on by
click is lost on a fresh Mac. Until 2026-11-01, 27 of 50 enabled plugins lived only there.
Report every live-`true` id that neither Nix (`local.claudePlugins.declared` + the always-on
three) nor the operator's overlay declares:

```bash
nix eval --json "$snap#darwinConfigurations.macos.config.home-manager.users.$USER.programs.claude-code.settings.enabledPlugins" > /tmp/declared.json
jq -rn --slurpfile nix /tmp/declared.json \
  --slurpfile ov <(jq '.enabledPlugins // {}' ~/.config/nix-config/claude-settings.overlay.json 2>/dev/null || echo '{}') \
  --slurpfile live <(jq '.enabledPlugins' ~/.claude/settings.json) \
  '(($nix[0]|keys)+($ov[0]|keys)|unique) as $d
   | $live[0] | to_entries[] | select(.value and ((.key|IN($d[]))|not)) | .key'   # must print nothing
```

Each line is a finding. Declare it (catalogue entry + `declared` key in the same commit), or
switch it off. A dependency that Claude Code auto-enabled
(e.g. `google-workspace-mcp` under `workspace-gtd`) shows up here too: declare it as well.

### E6. Terranix drift (macos) — `FD-E6-*`

The daily `terranix-drift` agent (`modules/home/terranix-drift.nix`) plans every `*-plan`
stack and writes a summary. Read it; never re-run the plans to "check":

```bash
f="${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-terranix-drift/summary.json"
jq -r '"finished \(.finished | todate)", (.stacks[] | "\(.stack)\t\(.status)\t+\(.add) ~\(.change) -\(.destroy)")' "$f"
```

| `status` | Finding? | Remedy (report only) |
|---|---|---|
| `clean` | no | — |
| `drift` | yes | name the stack and counts; the fix is a **reasoned** `nix run .#<stack>-plan` read by a human (or the `terranix-infra-reviewer` agent). **Never apply.** |
| `reauth` | yes | a lapsed Google login — the run's own log ends with the re-login command; relay it |
| `error` | yes | read that stack's `<stack>.log` beside the summary (0600, counts only in the summary) |

A `finished` older than ~a day is itself a finding: the agent did not run. Its heartbeat
(`nix-config-terranix-drift`, step E7) should agree.

### E7. Heartbeats (healthchecks.io) — `FD-E7-*`

```bash
secret exec K=hc:healthchecks.io:api -- sh -c 'curl -fsS -H "X-Api-Key: $K" https://healthchecks.io/api/v3/checks/' \
  | jq -r '.checks[] | "\(.slug)\t\(.status)\t\(.last_ping // "never")\t\(.n_pings)"'
```

- **`down`** is a finding: name the slug and its last ping.
- **`new`** (never pinged) is a finding **only if** its job has had a scheduled run since the
  ping was wired. Trace it: the slug's schedule in `fleet.heartbeats`
  (`modules/parts/heartbeats.nix`), its pinger workflow in the `pingers` map of the
  `heartbeat-workflow-parity` check (`modules/parts/checks.nix`), then
  `gh run list --repo kattakath/nix-config --workflow <file> --limit 1 --json conclusion,createdAt,event`.
  A `schedule` run after the wiring commit with the check still `new` means the ping is broken.
  A weekly job wired yesterday is not.
- `up`, `grace` and `paused` are not findings.

### E8. nixpi units (read-only) — `FD-E8-*`

One SSH call, short timeout, no prompts. An unreachable Pi is a finding — report it as
skipped, never retry-loop (and see the nixpi liveness-probing memory before calling the
tunnel down):

```bash
units=$(nix eval --raw --file "$snap/modules/_lib/nixpi-units.nix" longRunning --apply 'builtins.concatStringsSep " "')
ssh -o BatchMode=yes -o ConnectTimeout=10 ismail@nixpi.kattakath.com \
  "systemctl --failed --no-legend --plain; systemctl is-active $units"
```

Any `--failed` line, or a `longRunning` unit not `active`, is a finding. The `oneshot` list in
the same file is inactive between runs by design — never flag it as down. Restarting a unit is
under **always confirm**.

### E9. nixpi cache warmth — `FD-E9-*`

The Pi must only substitute, so its closure must be warm on Cachix:

```bash
gh run list --repo kattakath/nix-config --workflow warm-nixpi-cache.yml --branch main --limit 1 \
  --json conclusion,status,headSha,createdAt,url
```

A non-`success` conclusion is a finding (name the run URL). `in_progress` is not. The workflow
is **path-filtered**, so a `headSha` behind `origin/main` is normal after docs-only commits —
it is a finding only if a nixpi-closure path (its `paths:` list) changed after that sha.
Never test warmth with a `--dry-run` of the nixpi toplevel: it negative-caches the 404s for 1h.

### F. Host re-activation — `FD-F-*`

**Audit** reports `FD-F-*` only. **Fix** re-activates, and only if repos touched in this run
actually compose macos (i.e. their `flake.lock`/`flake.nix` changed) or the user asked for it
directly:

```bash
# macos — from anywhere. `activate` (packages/activate.nix) self-elevates via
# Touch ID, names the flake dir + branch@rev + (DIRTY) before it builds, and
# warns if /run/current-system has drifted from the system profile.
activate
```

**Read the `branch@rev` line it prints — do not let it scroll past.** The
`/etc/nix-darwin/flake.nix` link is a fixed path to the **main checkout**, so
`activate` builds whatever branch *that* tree currently holds — never a
`.claude/worktrees/*` tree, and never the default branch by default. A session
working inside a worktree therefore activates another tree's branch state,
silently and with a clean exit.

So before believing an activation: confirm the main checkout actually contains
what you landed, comparing against the **remote-tracking** ref
(`origin/<default>`) — a local `main` can itself be behind. If it is behind,
that is a **finding**: moving another tree's branch, or committing its dirty
files, stays in the **always confirm** column and is never an auto-fix.

**Then verify the outcome, rather than trusting the clean exit.** For anything
newly *declared* (a Claude plugin or skill in `modules/home/default.nix`, say),
the built config is what enables it, so read the activated state back — the
`enabledPlugins` and `extraKnownMarketplaces` keys of `~/.claude/settings.json`
— and compare to what the repo declares.

**An absent plugin is a THREE-way split, not a stale tree by default.** Since
2026-09-30 `home.activation.claudeCodePlugins` is narrowed to store-path
marketplaces (`isStorePath`, i.e. `hasPrefix "/nix/store/"` — the `repin` option was
deleted 2026-09-30), so what activation touches is a strict subset of what is declared:

| Case | What activation does | Absent plugin means |
|---|---|---|
| **store-path** marketplace (today only `xai-grok-build`) | runs one `plugin marketplace add` (no install) — see `home.activation.claudeCodePlugins` | the **tree was stale**, OR activation failed |
| **https** marketplace | **nothing** — no `marketplace add`, no `plugin install` | **normal** until the next session start; Claude Code clones and downloads it itself |
| marketplace missing from `extraKnownMarketplaces` | n/a — the declaration never reached settings | this, and only this, **proves a stale tree** |

So check the marketplace ENTRY before the plugin. And do not expect activation to
have moved an https marketplace's sha: it no longer refreshes any of them —
**Claude Code does**, in the background, and only for a marketplace carrying
`autoUpdate` (today just `kattakath`). A fresh sha proves nothing about your
change, and a stale one proves nothing about the tree.

## Report format (always end with this)

The health+json file is the report; this block points at it and reads from it.

```markdown
## Fleet-doctor report
- **Mode:** audit | fix · **Subject:** nix-config origin/<default> @ <sha>
- **Run:** <published .json path> · status pass | warn | fail · `doctor-report verdict` → 0 | 2 | 1
- **Diff vs previous:** N new · N persisting · N resolved (`doctor-report diff`)
- **Vacuous / skipped checks:** <checkKeys>, or none
- **Scope:** full fleet (N/N repos) | scoped to …
- **Branches/worktrees:** clean | findings: …
- **Open PRs:** none | repo #n — title — CI status — action (report only)
- **CI:** all green | repo — workflow — conclusion — needs investigation
- **GC:** host freed X | guest freed Y (or skipped, VM down) | nixpi: N free (report only)
- **Determinate Nix (macos):** current | X.Y.Z advised, running A.B.C — upgraded | report only
- **launchd (macos):** rc 0 | rc 1 — <section>: <kind> <label>, … (report only)
- **Terranix drift:** all clean (finished <time>) | <stack> drift +a ~c -d / reauth / error — remedy (report only)
- **Heartbeats:** all up | <slug> down since <last_ping> | <slug> new after a scheduled run
- **nixpi units:** none failed, longRunning all active | <unit> failed/inactive | skipped (unreachable)
- **nixpi cache:** warm-nixpi-cache green (<sha>) | red — <run URL> | stale — closure path changed since <sha>
- **Hosts:** macos re-activated (branch@rev built) | skipped (why) | NOT activated — main checkout behind origin
- **Verdict:** CLEAN | FIXED (list what) | NEEDS ATTENTION (why, and what needs a human decision)
```

## Compose with existing automation

```
/fleet-doctor [fix] [scope]         → this skill (audit by default)
/hygiene [fix] [scope]               → nix-config's own LEAN/DRY pass (composed by step D)
doctor-report validate|diff|publish  → the output contract both doctors share
/eval                                → nix-config eval only, no cross-repo scope
gh pr list / gh run list             → what this skill's B/C steps wrap
```

A lightweight SessionStart nudge (`.claude/hooks/fleet-doctor-digest.js`)
reminds you to run this when it's been a while — see that file for the
threshold. It never runs checks itself, only reads a local timestamp.
