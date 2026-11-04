# ADR-012 — Closing the declarative gaps: what is left, the tool for each, and drift detection

**Status:** **DECIDED 2026-11-03** (the order in § 5 is the operator's, chosen click-to-select).
Steps 1, 2, 3's GitHub half and 4 have **shipped** (§ 5); GitLab stays manual (§ 5 step 3).
Step 5 has shipped too. Each step is its own PR.

**Question.** ADR-005 put Cloudflare and GCP under terranix. What fleet state is *still* set by
hand, which of it can be declared — ideally in Nix — and what keeps the declared parts from
quietly drifting, so that AI-assisted maintenance gets cheaper and more deterministic?

## 1. Verdict

- **The hosts are declared; the gap is SaaS configuration added since ADR-005.** Grafana Cloud
  (ADR-011), GitHub rulesets and the merge queue, and Gmail filters hold the largest undeclared
  state. All three have a maintained declarative tool.
- **The cheapest win is not a new tool: a drift check.** Every stack has a `*-plan` app. None runs
  on a schedule, so drift is found by accident, inside an AI session, at full context cost.
- **Some state cannot be declared** (§ 4). It stays a runbook, and this ADR says so on purpose.

## 2. Method

Three read-only research passes on 2026-11-03: an inventory of undeclared state (repo docs, agent
memory, live read-only API sweeps), a tooling survey (each tool checked at its release page or
registry, plus the pinned nixpkgs `providers.json`), and a determinism and AI-cost survey (repo
greps and counts). The inventory itself carries per-account facts, so it stays out of this repo
(the no-data rule); this ADR keeps only the shapes and the decisions.

Baseline, measured that day: 53 flake checks on `aarch64-darwin` and 28 on `aarch64-linux`; all
45 external GitHub Actions `uses:` SHA-pinned; about 25 activation shims, of which the 4 spot-checked
each carry an upstream-first rationale.

## 3. Gaps that can be declared

| # | State set by hand today | Tool | Tool health (checked 2026-11-03) | Lane |
|---|---|---|---|---|
| 1 | Grafana Cloud: alert rules, contact point, notification policy, custom datasources, the custom dashboard, synthetic probes | `grafana/grafana` | v4.53.0, 2026-10-28 ([repo](https://github.com/grafana/terraform-provider-grafana)); nixpkgs ships 4.50.0, used via `opentofu.withPlugins` (the rule below) | terranix |
| 2 | GitHub: rulesets, merge queue, Actions variables, repo settings, across the fleet repos | `integrations/github` | v6.13.0, 2026-07-08 ([registry](https://registry.terraform.io/providers/integrations/github)); current in nixpkgs | terranix |
| 3 | Gmail filters and labels | [gmailctl](https://github.com/mbrt/gmailctl) (Jsonnet; `diff`, `test`, `apply`) | v0.13.0, 2026-09-28; in nixpkgs | package + wrapper |
| 4 | GitLab project settings | `gitlabhq/gitlab` | v19.5.0, 2026-10-16 ([mirror](https://github.com/gitlabhq/terraform-provider-gitlab)); nixpkgs 19.4.1 | terranix |
| 5 | One Homebrew cask installed outside `hosts/macos.nix` — **closed**, see § 5 step 1 | `homebrew.casks` | — | nix-darwin |

Rules that apply to every row:

- **Secrets stay out of state where the provider allows it.** The GitHub provider documents that
  a secret value is *not* hidden from state. Declare rulesets and variables first; Actions secrets
  either stay manual or use `encrypted_value`. State is encrypted either way (ADR-005).
- **New stacks take their providers from `opentofu.withPlugins`.** `provider-pins.nix` resists that
  for the existing stacks because it would force an upgrade under live state; a new stack has no
  state to upgrade.
- **gmailctl's filter file is data** (addresses, senders), so it lives in Drive, reached through an
  env var. The repo ships only the package and a wrapper.
- **Import first, then edit.** Each stack starts with `import` blocks for the live objects, and must
  plan clean (no changes) before its first edit lands.

### Gmail and ADR-005 § 3.3

ADR-005 keeps Workspace a runbook because its Terraform provider is archived, and that provider
would sit on the identity account every other login derives from. gmailctl is a different,
maintained tool that touches Gmail filters only, never the identity root. This is the narrow
reopening ADR-005 § 7 allows, not a reversal: the directory, Drive and sharing stay a runbook.

## 4. State that cannot be declared (confirmed)

| State | Why not | What stays |
|---|---|---|
| TCC privacy grants | Apple applies the PPPC payload only through MDM on a supervised Mac ([Apple](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web)); since macOS 11 `profiles` cannot install configuration profiles (`man profiles`); the pinned nix-darwin has no profile option | `docs/macos-settings-surface.md` |
| Keychain values | Values never enter Nix, by design | the `secret` CLI + the GCP copy (ADR-004) |
| claude.ai routines, environments, connectors | No IaC exists. The community Anthropic providers cover only the Admin API (workspaces, keys, limits); the routines API can read and fire a routine, not manage one | a read-only snapshot of each routine's config to Drive is the most that is possible |
| Workspace directory, Drive sharing | ADR-005 § 3.3; the continuation provider has one release | `docs/workspace-runbook.md` |
| Slack | The provider is archived (2025-12-05) | manual |
| Neon | The community provider is archived (2026-09-11); the official one lists no registry versions yet | **revisit** when it publishes |

## 5. Decided order

1. **Drift detection, run on the Mac, not in CI.** A daily user launchd agent (the `fleet-gauges`
   pattern) runs each stack's plan with `-detailed-exitcode` (0 = clean, 2 = drift) and pushes one
   gauge per stack to Grafana. Why the Mac: every stack's state is
   encrypted with one Keychain passphrase; a CI drift job would need a copy of it in GitHub. In the
   same PR: pin the three unpinned inputs (`kapture-mcp@latest`, the devcontainer `:latest` tag,
   the bootstrap installer URL) and declare the stray cask.
   **SHIPPED.** The agent is `nix-terranix-drift` (runbook: `docs/map/infra.md` § Drift
   detection). Alerting is the `nix-config-terranix-drift` heartbeat, not a Grafana rule.
   Grafana keeps the history through `fleet-gauges`; no Grafana drift rule is planned, the
   heartbeat is the alert.
   How the three inputs were settled, after measuring each one:
   - `kapture-mcp`: kattakath/skills #107 already pinned it (2.6.1). Only a stale comment was left here.
   - Devcontainer `:latest`: left as is. This repo is the publisher, and a `:<sha12>` pin would
     need a write-back updater (reason recorded in `devcontainer.json`).
   - Installer URL: left as is. A versioned `/nix/tag/vX` URL exists, but a pin goes stale on a
     fresh Mac and `determinate-nixd upgrade` owns versions after that. `bootstrap.sh` now prints
     the release it resolves to.
   - The cask: nothing left to declare. `escrcpy` was declared by #941, and every installed cask
     is in `homebrew.casks`.
2. **Grafana into terranix** (row 1), owned by the ADR-011 owner. Now is the cheapest time: the
   object count is still small.
   **SHIPPED** (#1056): 12 objects adopted by an import-only apply, and the re-plan reads No
   changes. The export needed 13 hand-fixes (empty durations and a contact-point field it omits).
3. **GitHub rulesets and variables** (row 2), then **GitLab** (row 4).
   **GitHub half SHIPPED** (#1059): `infra/github/stack.nix`, runbook in `docs/map/infra.md`.
   37 objects adopted by an import-only apply, and the re-plan reads No changes. Actions secrets
   and `github_repository` stay out (the stack header says why).
   **GitLab: DECIDED manual (2026-11-03).** The GitLab projects belong to the separate persona.
   Declaring them anywhere would risk linking the two identities, and their settings change
   rarely, so they stay out of IaC.
4. **gmailctl** (row 3).
   **SHIPPED:** `packages/gmail-filters.nix`, runbook in `docs/workspace-runbook.md` § 7. The
   live filters were imported to Drive and the first `diff` read clean. The first `apply` waits
   for the operator. Drift coverage is left out: `gmailctl diff` exits 0 even when it prints
   changes (checked with a positive control), so it does not fit the tofu exit-code classes.
5. **Determinism tooling:** generate the host and check tables from `nix eval` with a check that
   the committed text matches the render; `--json` output on `launchd-doctor` and `activate`;
   `plan -out` then `apply` of that saved plan; `scripts/drv-snapshot.sh --compare` in CI on
   refactor PRs.
   **SHIPPED, one PR per item:**
   - Generated tables: **SHIPPED** (#1065). The host and app tables live in
     `docs/map/entry-points.md` and are checked by `hosts-documented`. Checks are not rendered,
     because a check that reads its own checks set recurses.
   - `--json`: **SHIPPED** (#1062).
   - Saved plans: **SHIPPED** (#1064). The plan is bound to its stack and render, and the wrapper
     asks for the confirmation, because tofu applies a plan file without asking.
   - drv-snapshot in CI: **SHIPPED** (#1061, with fixes in #1066 and #1067). It runs on the
     `no-build-change` label and is advisory. #1066 fixed the base capture: a shallow clone has
     no `revCount`. #1067 compares `actionlint` by name only, because it reads `.github/`. #1067's
     own run, 41683056398, compared every output and found them all IDENTICAL: ACCEPTED.

## 6. Alternatives that lost

| Rejected | Why |
|---|---|
| Drift detection in GitHub Actions | needs the state passphrase in GitHub; § 5 step 1 keeps it in the Keychain |
| Google Workspace via the TrogonStack provider | one release, 0 stars, and it would sit on the identity root |
| impermanence on nixpi | more writes to an SD card that has already proven fragile |
| devenv, Renovate, sops-nix | each duplicates a tool this repo already owns (the flake-parts devShell, update-flake-lock, agenix per ADR-004) |
| GitLab under terranix, here or in a persona-side repo | either one risks linking the persona to the real name; the settings change rarely |
| disko + nixos-anywhere for the `nixos` VM | works today via `nixos-vm create`; revisit only if that breaks |

## 7. What would reopen a decision

- The official Neon provider publishes registry versions → declare the agentic-jobseek project.
- Anthropic ships IaC or a management API for routines → declare them.
- The Mac moves under MDM → TCC grants become declarable.
- **Weakest assumption, now measured:** that importing the live GitHub and Grafana objects is
  cheap. It was: GitHub needed 0 hand-fixes over 2 sample repos, and Grafana needed 13.
