# Grant: Study `nix-config`'s Media Stack for Extraction into `kattakath/nix-media-cli`

> **HISTORICAL, TWICE OVER.** This brief was answered and the extraction SHIPPED on
> 2026-09-05 into [`kattakath/nix-media-cli`](https://github.com/kattakath/nix-media-cli);
> ADR-002 wave 5 then absorbed that flake BACK on 2026-09-12 as the in-tree capsule
> `modules/features/media-cli/`. nix-config still consumes it as `programs.mediaCli` — the
> option surface never moved, only the code. Kept for the reasoning, not as a plan. Its file
> inventory and line references describe nix-config *before* the extraction, so they match
> neither shape today.

**Self-contained** — this document carries every fact needed to start. No prior
conversation, memory, or session context is required. Paste it whole into a fresh
session/agent.

**Grounded as of**: `kattakath/nix-config` @ `959d747` (2026-09-05, `main`). Repo state
may have drifted since — **verify every claim below against the live repo before
acting on it**; nothing here is a substitute for grep/read.

---

## 1. Your role

You are a FAANG-grade infrastructure engineer with deep, current expertise across:

- **Nix / nix-darwin / home-manager** — flake-parts composition, module option design,
  the `follows`-diet discipline large flake.locks need, CI/CD for Nix flakes.
- **macOS and Linux systems programming** — launchd (`QueueDirectories`,
  `ProcessType`, `KeepAlive`, `StartInterval`), POSIX process groups/sessions, TCC.
- **Applied AI media pipelines** — local vision-language models (Ollama), Apple's
  Vision framework, EXIF/IPTC/XMP metadata, ffmpeg-based transcoding.

You have been engaged to **study** an existing, organically-grown media toolkit living
inside a personal Nix mono-repo, and to **design** (not yet implement) its extraction
into a clean, public, single-purpose flake: `kattakath/nix-media-cli`.

---

## 2. What `kattakath/nix-config` is

A fully declarative, **aarch64-only** fleet mono-repo (one client Mac `macos`, one live
Raspberry Pi `nixpi`, a Tart macOS guest `macvm`, a throwaway NixOS dev VM `nixvm`, a
devcontainer image). Everything is Nix — nix-darwin for `macos`/`macvm`, NixOS for
`nixpi`/`nixvm`, home-manager as the shared user profile layer across all of them. The
repo's own grounding motto (verbatim, in its `CLAUDE.md`):

> Off-the-shelf over hand-rolled.
> Proven patterns over reinvented wheels.
> Community Legos over proprietary monoliths.

Mechanized as a rule (`.claude/rules/upstream-first.md`): **grep the pinned input's own
option surface before writing custom Nix, and cite what you found** — not "consider if
one exists," an actual grep with the result quoted.

This repo has done this exact kind of extraction **twice already, successfully** — see
§6. That precedent is not theoretical; it is the bar to match.

---

## 3. The subsystem in scope — verified file inventory

All under `kattakath/nix-config`:

| File | Role |
|---|---|
| `packages/media-toolkit.nix` | `symlinkJoin` — bundles the six CLIs below onto one PATH. Packaging only; does not itself invoke anything. |
| `packages/media.nix` | `media <command>` — dispatcher subcommand wrapper over `fix-media`/`extract-audio`/`photo-describe`. |
| `packages/photo-describe.nix` | Apple Vision labels + rating + local-VLM caption → written into an image's own XMP (`XMP:Description`, `XMP:Subject`, `XMP:Rating`). |
| `packages/fix-media.nix` | Repair a file "by media class" (`--video`/`--image`) — what the Finder Quick Actions actually call. |
| `packages/fix-google-video.nix` | Re-encode VP9-in-MP4 / other editor-hostile codecs into H.264+AAC. *(naming smell — see §5)* |
| `packages/extract-audio.nix` | Pull the audio track out of a video (`--mp3`/`--copy`/`--wav`/`--flac`). |
| `packages/fix-extension.nix` | Rename files whose extension lies about their content (e.g. a JPEG named `.png`). |
| `packages/media-quick-actions.nix` | Generates the macOS Finder "Quick Action" Automator `.workflow` bundles that call into `media-enqueue`. |
| `packages/media-queue.nix` | The durable, priority-tiered, pause/resume-capable launchd work queue: `media-enqueue`, `media-worker`, `media-queue-pause`, `media-queue-resume`, `media-queue-status`, `media-queue-top`, `media-queue-power-monitor`. |
| `modules/shared/media-queue.nix` | Home Manager wiring: the `launchd.agents.*` definitions (`QueueDirectories`, `StartInterval`, load control) that actually run `media-worker`/`media-queue-power-monitor`. |

**Host gating** (verified current, commit `959d747`, 2026-09-05): the entire stack —
`media-queue.nix` import, the Finder Quick Actions activation, and the
`mediaToolkit`/`auge`/`exiftool`/`rclipCli` packages — is `isMacosHost`-only in
`modules/shared/home.nix`. `macvm` (the Tart guest) gets none of it; its disk was
measured too small for the closure (ffmpeg, exiftool, auge's Vision bindings, rclip's
OpenCLIP model). **Re-verify this gate is still in place before assuming it.**

---

## 4. Verified cross-dependency graph

Two distinct kinds of coupling exist — do not conflate them.

**(a) Functional** — one script actually shells out to another at runtime:

```
┌─────────────┐   ┌────────────────┐
│fix-extension├─┬─┤fix-google-video│
└──────┬──────┘ │ └────────────────┘
       │        │
       ▼────────┴──────────▼
┌─────────────┐   ┌────────────────┐
│  fix-media  │   │ photo-describe │
└─────────────┘   └────────────────┘
```

```
┌─────────┐   ┌─────────────┐   ┌──────────────┐
│fix-media│   │extract-audio│   │photo-describe│
└────┬────┘   └──────┬──────┘   └───────┬──────┘
     │               │                  │
     ▼               │                  │
┌─────────┐          │                  │
│  media  │◄─────────┴──────────────────┘
└─────────┘
```

`media-worker` (inside `media-queue.nix`) also shells out directly to `photo-describe`
and `fix-media` by bare name at job-dispatch time — this is why `media-toolkit` is
explicitly listed in `media-worker`'s `runtimeInputs` (a Nix-hermetic dependency, not an
ambient-PATH assumption).

**(b) Packaging** — Nix `symlinkJoin` bundling only, no runtime call:

```
┌───────────────┐
│ media-toolkit │
│               ├─────────────┐
│(bundles all 6)│             │
└───────┬───────┘             │
        │                     │
        ▼                     ▼
┌───────────────┐   ┌───────────────────┐
│  media-queue  ├──►│media-quick-actions│
└───────────────┘   └───────────────────┘
```

Leaves (no functional dependents): `fix-extension`, `fix-google-video`, `extract-audio`.

---

## 5. Known naming smells — resolve with judgment, do not leave as-is

- **`fix-google-video` is named for a symptom, not the operation.** It re-encodes
  editor-hostile video codecs (VP9-in-MP4, etc.) — files that happen to often come
  from Google Photos exports, but the tool itself is generic. A tool's own CLI
  identity should never be permanently branded with one specific downstream
  product's name. It should almost certainly just be `video` (or `video-fix`,
  `transcode`, per whatever scheme you land on in the point below) — verify no
  behavior in the script is actually Google-specific before renaming (it should not
  be; confirm by reading the file).
- **Three incompatible naming schemes coexist in one toolkit**: `fix-*` prefix
  (`fix-media`, `fix-google-video`, `fix-extension`), bare nouns (`media`,
  `photo-describe`, `extract-audio`), and `media-queue-*` prefix (the six queue
  tools). Pick ONE scheme for the whole extracted flake.
- **"media" is heavily overloaded within this exact toolkit**: `media` (a CLI),
  `media-toolkit` (a package bundle), `media-queue` (a queue system), and
  `media-quick-actions` (Finder integration) are four different abstraction levels
  all sharing one word, with no naming rule distinguishing "this is a CLI" from
  "this is an internal Nix package name" from "this is a subsystem."
- **Seriously evaluate — but do not reflexively adopt — a single umbrella brand
  like `imagine <subcommand>`.** This was raised as a candidate during scoping.
  Real, already-present collision risk: this exact repo's own
  `packages/fidelity-enhance.nix` already refers to **"Grok Imagine"** (xAI's
  separate image-generation product) as a tool this fleet's *own* AI-image workflow
  judges output *from*. Branding this metadata/transcoding toolkit "imagine" risks
  operator confusion with a product this same repo already name-drops for an
  unrelated purpose. Before adopting: check real namespace collision (GitHub
  org/repo squatting on `imagine`-prefixed names, nixpkgs package-name collision,
  npm, any existing brand overlap) and present the tradeoff explicitly — accept or
  reject with reasoning, never silently.
- **Directly comparable in-ecosystem precedent to weigh against any dispatcher or
  umbrella-brand scheme**: `kattakath/nix-vast-provision` (already shipped, see §6)
  settled on a **flat `vast-<verb>` prefix for every CLI** — `vast-rent`,
  `vast-repo-check`, `vast-account-vars-set`, `vast-ssh-key-set`, `vast-init-repo`,
  `vast-template-apply`. One consistent domain prefix, verb-first, **no**
  subcommand-dispatcher layer. Justify whichever scheme you choose against this
  precedent explicitly — it is the most relevant prior art inside this exact fleet,
  not a generic external example.

---

## 6. OSS extraction pattern — verified against two already-shipped sibling flakes

Both inspected via `gh api` on 2026-09-05. **Re-verify against the live repos before
copying anything** — they may have changed.

**`kattakath/nix-vast-provision`** (MIT, org-owned, aarch64-darwin only):
top-level contents — `.github/`, `.gitignore`, `CODE_OF_CONDUCT.md`,
`CONTRIBUTING.md`, `LICENSE`, `README.md`, `SECURITY.md`, `flake.lock`, `flake.nix`,
`packages/`.

**`kattakath/nix-keychain-secrets`** (same scaffolding, **plus** a `modules/` dir):
same files as above, plus `modules/keychain-secrets.nix` — a home-manager module
exposing `programs.keychainSecrets` (camelCase option name), gated
`stdenv.isDarwin` internally so it's a clean no-op on non-Darwin hosts in a mixed
fleet, exported as `homeManagerModules.default`.

**Common `flake.nix` shape** (from `nix-vast-provision`, read in full):

```nix
inputs = {
  flake-parts.url = "github:hercules-ci/flake-parts";
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
};
nixConfig = {
  extra-substituters = [ "https://kattakath.cachix.org" ];
  extra-trusted-public-keys = [
    "kattakath.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw="
  ];
};
```

The public substituter + trusted key are committed in plaintext (they are a public
cache **read** credential, not a secret) — any consumer gets cached binaries with
zero setup. The **write** token is never in the repo.

**`.github/workflows/ci.yml`** (verified full content):

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
  merge_group:   # REQUIRED — a merge-queue entry emits neither push nor pull_request
concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }
jobs:
  checks:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: cachix/cachix-action@v17
        with: { name: kattakath, authToken: ${{ secrets.CACHIX_AUTH_TOKEN }} }
      - run: nix run nixpkgs#nixfmt-rfc-style -- --check $(find . -name '*.nix')
      - run: nix flake show
      - run: nix flake check -L
```

`CACHIX_AUTH_TOKEN` here is a **GitHub Actions repository secret** (`gh secret set`
once, out of band) — a different mechanism from nix-config's own login-Keychain
`secret`/`set-secret` CLI convention used for LOCAL/interactive secrets. **Do not
conflate the two.** If a local, interactive Cachix push is ever needed from a dev
machine (outside CI), follow the fleet's own established pattern —
`secret exec CACHIX_AUTH_TOKEN -- cachix authtoken` (the value never crosses
stdout), never a hardcoded
value — but the CI push path above needs the GH Actions secret regardless.

**`.github/workflows/flakehub-publish.yml`**: OIDC (`permissions: id-token: write`),
`DeterminateSystems/flakehub-push@v6`, `rolling: true`, fires on every push to `main`
— no long-lived FlakeHub token stored anywhere.

**`.github/workflows/auto-merge.yml`**: arms GitHub's merge queue on the operator's
own non-draft PRs, using a **CI-bot GitHub App installation token**
(`actions/create-github-app-token`) rather than the default `GITHUB_TOKEN` — a PR
auto-merged with the default token does not trigger downstream workflows, which
would silently kill `flakehub-publish.yml`. Requires the same CI bot App already
installed fleet-wide, plus `vars.CI_BOT_CLIENT_ID` / `secrets.CI_BOT_APP_PRIVATE_KEY`
configured on the new repo specifically.

**Branch ruleset** (`protect-main`, read via `gh api .../rulesets`): deletion +
non-fast-forward blocked; PR required, squash-only merge method; required status
check named `checks`; a `merge_queue` rule (`SQUASH`, `ALLGREEN` grouping). **GitHub
merge queues require an org-owned repo** — this is stated as the explicit reason
these extractions live under the `kattakath` org rather than a personal account.

**Consumption side, verified in `nix-config`'s own `flake.nix`/`home.nix`**:

```nix
# flake.nix
keychain-secrets.url = "github:kattakath/nix-keychain-secrets";
keychain-secrets.inputs.nixpkgs.follows = "nixpkgs";
keychain-secrets.inputs.home-manager.follows = "home-manager";
keychain-secrets.inputs.flake-parts.follows = "firmware-secrets/flake-parts";
...
inherit (keychain-secrets.packages.${system}) set-secret remove-secret secret;
```

```nix
# modules/shared/home.nix — imports list
keychain-secrets.homeManagerModules.default
```

The `.follows` pins protect `flake.lock`'s deliberate 60-node diet (documented in
`docs/repo-map.md`) — a new `nix-media-cli` input should follow the identical
pattern.

---

## 7. Verified CLI surface (as of `959d747`)

| Command | Usage | Notes |
|---|---|---|
| `photo-describe` | `photo-describe [--dry-run] [--overwrite] [--no-caption] [--model NAME] [--min-score N] <file-or-dir>...` | Default model `huihui_ai/qwen3-vl-abliterated` via Ollama (`OLLAMA_HOST`, default `127.0.0.1:11434`). Directories walked recursively. |
| `fix-media` | `fix-media <--video\|--image> <file-or-dir>...` | Calls `fix-extension`+`fix-google-video` internally. |
| `fix-google-video` | `fix-google-video [--keep] <video-file>...` | *(rename candidate, §5)* |
| `extract-audio` | `extract-audio [--mp3\|--copy\|--wav\|--flac] <video-file>...` | |
| `fix-extension` | `fix-extension [--dry-run] [--only image\|video\|audio] [--print0] <file-or-dir>...` | |
| `media` | `media <command> [args...]` | Dispatcher over `fix-media`/`extract-audio`/`photo-describe`. |
| `media-enqueue` | `media-enqueue <--video\|--image\|--describe> [--priority high\|normal\|low] <file-or-dir>...` | Writes a job, returns immediately. |
| `media-worker` | *(launchd-invoked only)* | Drains the queue; retry/backoff; orphan adoption across worker restarts (MAINPID pattern); low-power defer. |
| `media-queue-pause` / `media-queue-resume` | *(no args)* | SIGSTOP/SIGCONT the in-flight job's process group. `-resume` refuses while macOS Low Power Mode is active. |
| `media-queue-status` | *(no args)* | One-shot snapshot: per-tier pending counts, pause reason, orphan state, live progress. |
| `media-queue-top` | *(no args)* | `media-queue-status`, live-refreshed via `viddy` (nixpkgs' "modern watch") — added 2026-09-05, PR #450. |
| `media-queue-power-monitor` | *(launchd `StartInterval` only)* | Auto-pause/resume on Low Power Mode, every 20s. |

---

## 8. Lifecycle questions the study must answer per component (verify, don't assume)

For **every** file/CLI above:

1. **Install path** — plain `home.packages` entry, or a Home Manager module import
   with its own `launchd.agents.*`?
2. **Invoker** — interactive terminal, a Finder Quick Action (Automator `.workflow`),
   launchd's `QueueDirectories`/`StartInterval`, or another script in this same
   toolkit?
3. **State touched** — XMP tags written, queue directories, log files
   (`~/Library/Logs/nix-media-queue.log`), scratch files, Ollama HTTP calls.
4. **Failure mode** — retry-with-backoff? dead-letter (`failed/`)? silent no-op?
5. **Host scope** — `macos` only, or does it (still) run on `macvm` too? (Verified
   `isMacosHost`-only as of `959d747` — confirm this hasn't drifted.)

---

## 9. What "the future of these" means — questions to actually answer, not just describe the present

- **Is `media-queue` generic enough to be its OWN, even smaller flake**, separate
  from the media-specific CLIs? Its `common`/`ensure_dirs`/tier-priority/pause-resume
  machinery is a genuinely generic "durable, priority-tiered, pausable macOS launchd
  job queue" primitive — nothing in its core loop is media-specific except *which
  binary* `media-worker` dispatches to. If it can be parameterized over "what a job
  is," a `nix-launchd-job-queue` (or similarly named) flake with far broader
  applicability than media might be the better extraction, with `nix-media-cli`
  consuming *it* rather than owning queue logic itself. Investigate concretely
  (read `media-worker`'s dispatch site) before concluding either way.
- **Should `photo-describe`'s vision-model choice become a fork-friendly override**,
  the way `nix-vast-provision` exposes `orgName`/`repoName`/`userName` as
  `callPackage` override points? Today the model name is a hardcoded default
  (overridable per-invocation via `--model`, but not per-fork via Nix).
- **Does any part of this belong on `aarch64-linux`?** `fix-extension`,
  `fix-google-video`(-renamed), and `extract-audio` have zero macOS dependency
  (pure ffmpeg/exiftool). Only `photo-describe` (Apple Vision via `auge`) and the
  launchd/Finder integration are inherently Darwin-only. Consider whether the flake
  should ship `systems = ["aarch64-darwin" "aarch64-linux"]` with the
  Darwin-specific pieces gated inside, mirroring how `nix-config` itself already
  gates macvm's package list.
- **Exact nix-config-side before/after.** Draft the literal diff: which files under
  `packages/` get deleted entirely, what the new flake input block looks like (with
  its `.follows` set), and what `modules/shared/home.nix`'s `imports`/`home.packages`
  sections look like after the swap to `github:kattakath/nix-media-cli`.

---

## 10. Deliverables

1. **Verified current-state map** — every file, every cross-dependency (re-verify
   §4's two graphs against the live repo, don't just trust this document), every
   CLI's flags (re-verify §7), every lifecycle answer from §8.
2. **A renaming proposal** — one consistent scheme for the whole toolkit. Every
   old→new name pair justified against §5 and §6's `vast-*` precedent. Explicitly
   rule the `imagine` umbrella idea in or out, with reasoning — not silence.
3. **A repo design for `kattakath/nix-media-cli`** — directory layout; `flake.nix`
   outputs (`packages`/`apps`/`homeManagerModules`/`checks`); CI/publish/branch-
   protection wiring matching §6's precedent in *kind*, adapted only where this
   toolkit's actual needs genuinely differ (e.g., multi-system per §9).
4. **A staged migration plan** — the exact nix-config-side diff, split into an
   incremental, revertible sequence of PRs (never one big-bang rewrite), per this
   repo's own one-PR-per-logical-change convention
   (`.claude/rules/pr-title.md`).
5. **Open questions / risks** — anything not resolvable with confidence, flagged
   explicitly rather than guessed past.

---

## 11. Ground rules for whoever executes this study

- **Verify, don't assume.** Every file reference, CLI flag, and dependency edge in
  this document must be re-grepped/re-read against the live repo — it may have
  drifted since `959d747` (2026-09-05).
- **Cite sources for every Nix-ecosystem claim**, per this repo's own
  `.claude/rules/upstream-first.md`: grep the pinned input before proposing
  anything, quote the result line (`✅ upstream option X exists → using it`, or
  `✅ grepped <input>/modules for <terms> — no option exists → custom, because
  <reason>`).
- **This is a study + design deliverable, not an implementation task.** Do not
  create the new GitHub repo, do not delete files from `nix-config`, do not open
  PRs, until the design has been reviewed and explicitly approved by the repo
  owner.
- **Output format**: verdict first, tables over prose, ASCII diagrams (rendered via
  `mermaid-ascii -p 0 -x 1 -y 2` or similar, per this repo's own `CLAUDE.md`
  diagram convention) for anything structural — never raw mermaid source dumped as
  a non-answer.
