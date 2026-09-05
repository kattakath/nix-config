# Study: extracting the media stack into `kattakath/nix-media-cli`

The answer to [`nix-media-cli-extraction-grant.md`](nix-media-cli-extraction-grant.md).
Grounded at `959d747` (2026-09-05, `main`); every claim below was re-verified against
the tree, and the corrections in § 1 are the ones the grant got wrong.

## Verdict

| Question | Answer |
|---|---|
| Is the stack extractable? | **Yes** — 3,014 lines, 10 files, one seam into `home.nix` |
| Is it a *good idea* right now? | **Only half of it.** The 6 media CLIs extract cleanly. The queue does not — see § 5 |
| Naming scheme | **Flat `media-<verb>`**, keeping `media` as the umbrella — matches `nix-vast-provision`'s `vast-<verb>` precedent |
| `imagine` umbrella | **Rejected.** Three independent reasons, § 3 |
| Purge `google` from `fix-google-video` | **Yes** — verified: nothing in the script is Google-specific |
| Multi-system (`aarch64-linux`)? | **No.** The grant assumed 3 portable CLIs; only **1** actually is — § 1 |
| Split the queue into its own generic flake? | **Not yet, but shape for it** — § 5 |

---

## 1. Corrections to the grant

The grant is mostly accurate. These five items are wrong or incomplete, and two of them
change the design.

| # | Grant said | Verified reality | Impact |
|---|---|---|---|
| 1 | §9: "`fix-extension`, `fix-google-video`, `extract-audio` have zero macOS dependency (pure ffmpeg/exiftool)" | **False for two of three.** `fix-extension` calls `/usr/bin/mdls` + BSD `/usr/bin/stat -f`; `fix-google-video` calls `/usr/bin/stat -f`, `/usr/bin/SetFile`, `/usr/bin/GetFileInfo` and moves originals to `~/.Trash`. `photo-describe` calls `/usr/bin/sips`. **Only `extract-audio` is portable.** | **Kills the multi-system plan.** The flake is `aarch64-darwin` only, like `nix-vast-provision` |
| 2 | §7: "12 commands" | **13 binaries.** The table merges `media-queue-pause` and `media-queue-resume` into one row | Cosmetic |
| 3 | §4: implies every CLI is a flake app | **Only 3 of 8 media packages export an app**: `extract-audio`, `fix-google-video`, `photo-describe`. `fix-extension`, `fix-media`, `media`, `media-queue`, `media-toolkit`, `media-quick-actions` have none | Real inconsistency to fix during extraction (§ 4) |
| 4 | §3: the stack "is `isMacosHost`-only in `modules/shared/home.nix`" | True, but **two-layer**: `modules/shared/media-queue.nix` gates itself on `isDarwin`; the `macvm` exclusion is the `isMacosHost` guard at the *import site* (`home.nix:529`) plus the `home.packages` block at `home.nix:715` | The extracted HM module should keep `isDarwin` internal and let the consumer do host gating |
| 5 | §5: "`media` … `media-toolkit` … no naming rule distinguishing a CLI from a Nix package name" | `packages/media.nix`'s own header **already answers this**, in writing — it explains why each name is *not* folded into the dispatcher (launchd `arg0` TCC, absolute store paths in `.workflow`, the `--print0` composition seam) | The umbrella question is already half-settled; don't re-litigate it, extend it |

Also worth recording: the `MAINPID` orphan-adoption design from the pending plan file
**is already implemented** (`packages/media-queue.nix:212, 435-460, 566+`). That plan is
complete, not outstanding.

---

## 2. Verified state map

### The 10 files, 13 binaries

| File | Binaries | Lines | Portable? |
|---|---|---|---|
| `packages/media-toolkit.nix` | *(symlinkJoin of 6)* | 82 | n/a |
| `packages/media.nix` | `media` | 85 | ✅ |
| `packages/photo-describe.nix` | `photo-describe` | 613 | ❌ `sips`, `auge` |
| `packages/fix-media.nix` | `fix-media` | 89 | ✅ |
| `packages/fix-google-video.nix` | `fix-google-video` | 230 | ❌ `stat -f`, `SetFile`, `~/.Trash` |
| `packages/extract-audio.nix` | `extract-audio` | 111 | ✅ **the only truly portable one** |
| `packages/fix-extension.nix` | `fix-extension` | 359 | ❌ `mdls`, `stat -f` |
| `packages/media-quick-actions.nix` | *(3 `.workflow` bundles)* | 233 | ❌ Automator |
| `packages/media-queue.nix` | 7 queue CLIs | 1,077 | ❌ launchd |
| `modules/shared/media-queue.nix` | *(HM `launchd.agents`)* | 135 | ❌ launchd |

`media` and `fix-media` are marked portable only because they are pure dispatchers — they
inherit their dependencies' portability, which is ❌.

### Functional dependency graph (re-verified)

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

`media` dispatches to `fix-media` / `extract-audio` / `photo-describe`.
`media-worker` dispatches to `photo-describe` / `fix-media` — **in exactly three lines**
(`media-queue.nix:769-771`), with `media-toolkit` on its `runtimeInputs`.

### Durable state the extraction must not break

| Path | Written by | Rename cost |
|---|---|---|
| `~/Library/Application Support/nix-media-queue/{queue-high,queue,queue-low,staging,failed}` | `media-enqueue`, `media-worker` | **Migration required** if renamed |
| `~/Library/Logs/nix-media-queue.log` | launchd `StandardOutPath` | Log continuity |
| launchd `arg0` = `nix-media-queue` | `modules/shared/hm-launchd` | **TCC-load-bearing** — `.claude/rules/launchd-naming.md` |
| `~/Library/Services/*.workflow` | `home.activation.mediaServices` | Regenerated; free |
| `XMP:Description` / `Subject` / `Rating` in every described photo | `photo-describe` | **Permanent and irreplaceable** — never re-derive |

The `nix-media-queue` names are **not** part of the renaming question. They are runtime
state and a TCC identity, and there is no benefit to churning them.

---

## 3. Renaming proposal

### Scheme: flat `media-<verb>`, `media` stays the umbrella

Justified against the grant's own comparison point: `nix-vast-provision` shipped
`vast-rent`, `vast-repo-check`, `vast-account-vars-set`, … — **one domain prefix,
verb-first, no dispatcher**. This stack already has a dispatcher (`media`) with a written
rationale, so the scheme here is *that precedent plus the umbrella it already grew*.

| Today | Proposed | Why |
|---|---|---|
| `media` | `media` | Unchanged. It is the domain word; a dispatcher named for its domain is the standard shape (`git`, `nix`, `docker`) |
| `photo-describe` | `media-describe` | `photo-` is a fourth prefix owned by one tool — and the tool handles screenshots and receipts too, so "photo" is already inaccurate |
| `fix-media` | `media-fix` | Verb after domain. Also kills the `media`/`fix-media`/`media-toolkit` three-way confusion |
| `fix-google-video` | **`media-transcode`** | Purges the vendor name. **Verified safe**: the script's codec allowlist is `h264\|hevc\|prores\|mpeg4\|mjpeg` — it re-encodes *any* editor-hostile codec (VP9, AV1). Nothing in the logic touches Google. The Takeout story belongs in the header comment, which is where it already is |
| `fix-extension` | `media-fix-extension` | Stays addressable — it is a composition seam (`--only`/`--print0`) for two other CLIs |
| `extract-audio` | `media-extract-audio` | |
| `media-enqueue`, `media-worker`, `media-queue-*` (7) | unchanged | Already compliant |

After: **13/13 binaries share one prefix**, and the functional graph reads as one family.

```
┌───────────────────┐                                            
│       media       ├───┬───────┐                                
└─────────┬─────────┘   └───────┼─────────────────────┐          
          │                     │                     │          
          ▼                     ▼                     ▼          
┌───────────────────┐   ┌───────────────┐   ┌───────────────────┐
│   media-describe  │ ┌─┤   media-fix   │   │media-extract-audio│
└─────────┬─────────┘ │ └───────┬───────┘   └───────────────────┘
          │           │         │                                
          ▼───────────┘         ▼                                
┌───────────────────┐   ┌───────────────┐                        
│media-fix-extension│   │media-transcode│                        
└───────────────────┘   └───────────────┘                        
```

### What the rename actually costs

`packages/media.nix`'s header names three consumers that "hardcode those names". Checked:

| Consumer | Survives a rename? |
|---|---|
| Finder `.workflow` bundles baking absolute `/nix/store` paths | **Yes, free** — they are generated by `media-quick-actions.nix` from the same derivations, so they follow automatically |
| `nix run .#photo-describe` | **Breaking** — a flake output rename. Mitigate with alias outputs for one release |
| The operator's own notes / muscle memory | **Breaking, unmitigable.** This is the real cost, and it is yours to accept or decline |

### Rejected: the `imagine` umbrella

Three independent reasons, any one sufficient:

1. **Semantic mismatch.** "Imagine" means *generate*. This toolkit generates nothing —
   `media-toolkit.nix`'s own membership rule excludes `fidelity-enhance` precisely
   because it "judges images, generating and transforming nothing". A generative verb
   over a repair-and-metadata toolkit misnames the whole thing.
2. **Live collision in this repo.** `packages/fidelity-enhance.nix` already references
   **Grok Imagine** (xAI's image-generation product) as an upstream in the fleet's
   *actual* AI-image workflow. Two unrelated things called "imagine" on one Mac.
3. **Already decided, in writing.** `media.nix`'s header argues at length that a
   dispatcher which *replaces* the underlying names is "a breaking change bought for a
   shorter help listing". `imagine` is that same proposal wearing a new word.

---

## 4. Repo design — `kattakath/nix-media-cli`

Matches the verified scaffolding of `nix-vast-provision` and `nix-keychain-secrets` in
kind; it diverges only where this toolkit genuinely differs.

```
nix-media-cli/
├── flake.nix                  flake-parts; systems = [ "aarch64-darwin" ]
├── flake.lock
├── packages/                  the 8 derivations
├── modules/media-cli.nix      programs.mediaCli → the launchd agents
├── .github/workflows/         ci.yml · flakehub-publish.yml · auto-merge.yml
├── LICENSE · README.md · CONTRIBUTING.md · CODE_OF_CONDUCT.md · SECURITY.md
└── .gitignore
```

| Element | Decision |
|---|---|
| `systems` | **`aarch64-darwin` only.** § 1 item 1 kills multi-system; `nix-vast-provision` sets the same precedent |
| `nixConfig` | `extra-substituters = [ "https://kattakath.cachix.org" ]` + the public key, committed in plaintext (a read credential, not a secret) |
| CI Cachix push | `secrets.CACHIX_AUTH_TOKEN`, a **GitHub Actions repo secret** — set once out of band. Not the login-Keychain `secret` CLI, which covers local/interactive use only |
| FlakeHub | OIDC `id-token: write` + `flakehub-push@v6`, `rolling: true` — no stored token |
| auto-merge | CI-bot **GitHub App** token via `actions/create-github-app-token`, never `GITHUB_TOKEN` (which would silently stop `flakehub-publish` from firing) |
| Branch ruleset | `protect-main`: squash-only, required `checks` status, `merge_queue` / `ALLGREEN`. **Needs an org-owned repo** — hence `kattakath/`, not a personal account |
| **Every package gets an app** | Fixes correction #3. All 8 exported as both `packages.*` and `apps.*` |
| HM module | `programs.mediaCli.enable`, gated `stdenv.isDarwin` **internally**, exported as `homeManagerModules.default`. Owns the two `launchd.agents` and the `~/Library/Services` activation |
| Model override | `programs.mediaCli.visionModel` — today the model name is only overridable per-invocation (`--model`), not per-fork. Answers the grant's §9 question: **yes, expose it** |

Consumption side, matching the existing `.follows` diet:

```nix
media-cli.url = "github:kattakath/nix-media-cli";
media-cli.inputs.nixpkgs.follows = "nixpkgs";
media-cli.inputs.home-manager.follows = "home-manager";
media-cli.inputs.flake-parts.follows = "firmware-secrets/flake-parts";
```

```
┌───────────────────┐                       
│nix-media-cli flake├─────────────┐         
└─────────┬─────────┘             │         
          │                       │         
          ▼                       ▼         
┌───────────────────┐   ┌──────────────────┐
│ packages: 13 CLIs │   │homeManagerModules│
└─────────┬─────────┘   └─────────┬────────┘
          │                       │         
          ▼                       │         
┌───────────────────┐             │         
│nix-config home.nix│◄────────────┘         
└───────────────────┘                       
```

---

## 5. Should the queue be its own flake?

**Not yet — but do not weld it shut either.**

The case *for*: `media-queue.nix` is 1,077 lines and only **3 of them** are media-specific
(`:769-771`, the class→binary dispatch), plus `media-toolkit` on `media-worker`'s
`runtimeInputs`. Everything else — three priority tiers, dead-letter after `MAX_TRIES`,
`SIGSTOP`/`SIGCONT` pause on the job's process group, `MAINPID`-style orphan adoption
across worker restarts, stranded-retry reclaim, Low Power Mode deferral — is a generic
*durable, priority-tiered, pausable launchd job queue*. That is a genuinely reusable
primitive with no equivalent in nixpkgs.

The case *against*, which wins today:

- **One consumer.** A parameterised queue needs a job-definition interface, and designing
  one against a single caller produces an interface shaped like that caller.
- **The motto cuts both ways.** `CLAUDE.md` is explicit that "a broker-based job queue, a
  bespoke supervision daemon, or any other heavy framework is *also* a violation … when
  it's bigger than the problem warrants". A generic queue framework for one media toolkit
  on one Mac is exactly that.
- **Its value is its scar tissue.** The tier demotion rules, the `setsid` session
  requirement, the `pgrep -P` false-positive history — all of it was earned against *this*
  workload. Genericising it before a second workload exists would abstract over evidence
  that does not exist yet.

**Recommendation:** extract the queue into `nix-media-cli` alongside the CLIs, but isolate
the dispatch into a single named shell function (`dispatch_job()`) with a header comment
naming it as the seam. When a second workload appears, that function is the whole
interface, and the split becomes mechanical.

---

## 6. Staged migration plan

One PR per logical change, off `main`, per [`pr-title.md`](../.claude/rules/pr-title.md).
Every stage is independently revertible; no stage leaves the Mac without working CLIs.

| # | Repo | Title | What | Revert |
|---|---|---|---|---|
| 1 | nix-config | `packages` | **Rename in place**, ahead of any extraction: `fix-google-video`→`media-transcode` and the other four, with alias outputs kept for one release. Add the 5 missing `apps.*` | `git revert` |
| 2 | nix-config | `packages, darwinConfigurations` | Isolate `media-worker`'s dispatch into `dispatch_job()` (§ 5). Pure refactor, no behaviour change | `git revert` |
| 3 | nix-media-cli | *(new repo)* | Scaffold only — `flake.nix`, CI, FlakeHub, auto-merge, ruleset, LICENSE. **No packages yet.** Prove the pipeline is green before anything depends on it | Delete the repo |
| 4 | nix-media-cli | `packages` | Copy the 8 derivations verbatim (post-rename). CI must build all 8 | `git revert` |
| 5 | nix-media-cli | `modules` | Add `modules/media-cli.nix` (`programs.mediaCli`), port the `launchd.agents` and the `~/Library/Services` activation, add `visionModel` | `git revert` |
| 6 | nix-config | `flake, darwinConfigurations, packages, docs` | **The swap.** Add the input with its `.follows` pins, import `homeManagerModules.default`, delete the 10 local files. Verify `flake.lock` stays at 60 nodes | `git revert` — the deleted files come back with it |
| 7 | nix-config | `packages, docs` | Drop the stage-1 aliases | `git revert` |

**Stage 6 is the only risky one**, and its risk is not the Nix: it is the queue's live
state directory. Before merging it, confirm `~/Library/Application Support/nix-media-queue`
is empty (`media-queue-status` shows no running/queued/failed job) so no in-flight batch
is orphaned across the agent reload.

---

## 7. Open questions and risks

| | Question / risk | Why it is not resolvable here |
|---|---|---|
| Q1 | Is the muscle-memory cost of renaming 5 CLIs worth the consistency? | **Yours alone.** The machine cost is near zero (§ 3); the human cost is not measurable by me |
| Q2 | Does `media-transcode` overclaim? It transcodes video only, never audio or images | Alternatives: `media-fix-video`, `media-reencode`. `media-fix-video` is the most honest but reintroduces `fix-` as an infix |
| Q3 | Does `auge` (Apple Vision, aarch64-darwin only) belong *in* the flake, or stay a nixpkgs dep of the consumer? | Depends on whether `photo-describe` should be usable outside this fleet at all |
| R1 | **CI cannot catch a build failure the way this repo's CI is shaped.** `home.nix:321-329` records a measured case: `rclip` evaluated green through `nix flake check` *and* the CI build leg, then broke `activate` on the real Mac | The new repo's CI must `nix build` every package, not just evaluate — the one place its CI must be *stricter* than nix-config's |
| R2 | Extracting to a public repo publishes the `photo-describe` prompt and the Ollama model choice | Both are already public in this repo; no new exposure. Recorded for completeness |
| R3 | `media-quick-actions.nix` bakes absolute `/nix/store` paths into `.workflow` bundles copied (`cp -RL`) into `~/Library/Services` | Already true today; the extraction does not change it. But a GC after an uninstall leaves dead menu items, which no stage above fixes |
