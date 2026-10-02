Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `modules/parts/` — the flake engine

**ADR-002 wave 2** moved every flake output out of `flake.nix` and into one file per concern.
`flake.nix` is now **inputs plus a single `flake-parts.lib.mkFlake` call and nothing else**; the
engine is here. These are flake-parts modules and they **may reach anywhere** in the tree — that
is the asymmetry with `modules/features/`, which may not reach out.

They are discovered by **`import-tree`**, not by a hand-written `imports = [ … ]`. One regex with
an alternation covers both trees:

```nix
(import-tree.match ".*/(parts/[^/]+|features/[^/]+/flake-module)\\.nix$").addPath ./modules
```

**The `.match` is mandatory, and one alternation is mandatory too.** `import-tree`'s DEFAULT
filter is *every* `.nix` file not under `/_` (pinned `default.nix:48`), which would feed
home-manager and NixOS modules to the flake-parts module system. And `.match` accumulates with
`and` (pinned `default.nix:234`), so chaining a second `.match` **intersects** the two and loads
nothing — hence one regex, not two calls.

| File | Owns |
|---|---|
| `identity.nix` | `loginName` / `domainName` / `fullName` / `userEmail`, threaded through `specialArgs` — the `identityArgs` that used to be `let` bindings in `flake.nix`. `options.fleet` is a **submodule with a `lazyAttrsOf raw` freeformType**, so the other ~26 fleet attrs still merge across files while `identityArgs` alone is a CLOSED four-field typed submodule: a fifth field now fails here with "option … does not exist" instead of exploding in a template consumer's build, the way `publicMcpPort` did on 2026-09-16. It constrains the DECLARATION only — a consumer's `identity` arrives through `specialArgs`, outside the module type system. Shape copied from flake-parts' own top-level `flake` option. |
| `systems.nix` | flake-parts' `systems` = the two fleet arches. **`x86_64-linux` is deliberately NOT here** — adding it would silently spawn x86 checks, formatter and apps; the devcontainer reaches it with `withSystem "x86_64-linux"`. |
| `compose.nix` | `mkDarwin` / `mkNixos` / `mkHomeManagerModule` — **not translated** to flake-parts, kept verbatim as plain Nix functions in the freeform `flake` attr (ADR-001's blast-radius objection, honoured). Also threads each capsule in as a named specialArg. Its two composition seams (`extraHomeModules`, `hostedSites`) and the nixpi deploy runbook are written up in [`private-home-modules.md`](../private-home-modules.md) — the filename is historical (the private `nix-personal` flake it was named for was retired 2026-09-15); the seams and the runbook are current. |
| `hosts.nix` | `darwinConfigurations.macos`, `nixosConfigurations.{nixpi,nixvm}`. |
| `packages.nix` | `perSystem.packages` + every `apps.*`. |
| `checks.nix` | The engine's own checks, including `claude-md-budget`, `capsule-registry`, `deploy-schema`, `bedrock-gate-after-loader`, `launchd-log-rotation` (every declared launchd log reaches exactly one rotator, and never both — re-walks the composed agents itself rather than reading `logging.nix`'s own answer back), `mcp-launcher-parity` (the `nix-mcp-*` launchers this fleet builds == the servers `kattakath/skills`' plugins name, read out of the pinned input at eval time — [`modules-home.md`](modules-home.md) § `modules/home/` for the exclusions and the proof it is not vacuous), the two `determinate-daemon` halves and `nixpi-security-posture` ([`modules-nixos.md`](modules-nixos.md) § `modules/nixos/` — 22 legs, read in BOTH directions since 2026-10-01: a WIDENING of the firewall fails it, and so does REMOVING the declared LAN recovery ingress). Its one shared helper, `mkHostContract`, reports EVERY broken leg rather than the first — that behaviour, not code reuse, is the bar for reaching for it. |
| `capsules.nix` | The capsule registry and its two internal seams — `capsuleModules` and `capsuleSources` — plus `checks.<system>.capsule-registry`. |
| `terranix.nix` | The `cf-*` / `gcp-*` tofu builders. The `mcp-public-*` builders and the `mcp-worker-probe` package were deleted 2026-10-02 with that stack. |
| `devshell.nix` | `devShells` + the `git-hooks.nix` wiring. |
| `deploy.nix` | `deploy.nodes.nixpi` (deploy-rs has **no** flakeModule — grepped; this stays hand-written in the freeform `flake` attr). |
| `templates.nix` | `templates.default`. |
| `devcontainer.nix` | The image, via `withSystem "x86_64-linux"`. |
| `lib-option.nix` | The 4-line `mkOption { type = lazyAttrsOf raw; }` declarations for `flake.lib` and `flake.darwinConfigurations`, copied from flake-parts' own `nixosConfigurations.nix:11`. Without them the freeform `types.unique` default would force every seam back into ONE file — silently re-creating the monolith. |
| `touchup.nix` | What the flake does **not** export. A bare `mkFlake` also emits `legacyPackages`, `nixosModules`, `overlays` and `modules`; this repo has never exported any of them, and the decision (plus the one-line path back) is recorded there. |

## `modules/features/` — the seven capsules

**Seven capsules, but only six are absorbed satellites.** Seven satellite flakes were absorbed
in-tree by **ADR-002** and archived at origin; six remain — `vast-provision` was removed
wholesale on 2026-09-12 along with the rest of the off-fleet GPU control plane. The seventh
capsule, `cloud-cli`, has **no satellite provenance at all**: it was born in-tree 2026-09-20
(below). `checks.<system>.capsule-registry` holds `readDir modules/features` == the set
`import-tree` loaded, so this count is mechanical rather than remembered. See
[`monoflake-capsule-adr.md`](../monoflake-capsule-adr.md), and **§9 of it first** — the correction
record supersedes the design where they disagree.

### The boundary is mechanical, not a convention

| Layer | Mechanism | What it catches |
|---|---|---|
| File | `ast-grep/rules/capsule-must-not-reach-out.yml` (`files: modules/features/**`, `kind: path_expression`, severity **error**) riding the existing `checks.<system>.ast-grep` gate | a `..` path literal anywhere under a capsule — **even one that stays inside it**, which is why `tart-vms`' four module files and `media-cli`'s `package-graph.nix` sit at the capsule ROOT rather than in a nested `modules/` or `lib/` |
| Registry | `checks.<system>.capsule-registry` (`modules/parts/capsules.nix`) asserts `readDir ./modules/features` equals the set `import-tree` actually loaded | a **misnamed entry file** silently dropping a whole capsule with CI green (ADR-002 §4, S3). Verified by renaming `flake-module.nix` → `flake-modules.nix`: the check fails with that message. |
| Option | `lib.evalModules` against a stub host (`darwinStubs`, in `tart-vms`' checks) | an isolation break the two above cannot see — at the cost that the stubs **rot** (ADR-002 §7.7) |

**The gate has an INWARD hole.** `files: modules/features/**` can only see a file *inside* a
capsule reaching out; it cannot see a file *outside* naming a file *inside*. That is real —
`modules/home/default.nix` has to `callPackage` a `tart-vms` file with the **host's** pkgs — and is
why `capsuleSources` exists (below). ADR-002 §9.3.

### `flake-module.nix` is the only entry, and there are three seams out

Every capsule is entered **only** through `flake-module.nix`. From there it publishes on one of:

| Seam | Type | Used by | Why |
|---|---|---|---|
| `flake.modules.<class>.<name>` | flake-parts' own module registry (`extras/modules.nix:32-73`) | `cloudflared-connector`, `firmware-secrets` (both NixOS) | pure reuse; the `_class` stamp comes free |
| `capsuleModules.<class>.<name>` | `lazyAttrsOf raw` — a definition passed through **UNWRAPPED** (`modules/parts/capsules.nix`) | `keychain-secrets`, `media-cli`, `local-rag` (home-manager), `tart-vms` (darwin) | **measured, not stylistic.** `flake.modules`' element type is `types.deferredModule`, whose merge always wraps in `{ imports = [ … ]; }` (pinned nixpkgs `lib/types.nix`, `deferredModuleWith`), and flake-parts wraps again for any class but `generic`. For a NixOS module that is invisible. For a **home-manager** module it is not: `home.packages` is a LIST, merged in module-collection order = `buildEnv`'s `paths` order = **who wins a filename collision**. Routing `keychain-secrets` through `flake.modules` moved its four CLIs ahead of postgresql and `nix-bedrock-gate` and **changed `darwin-system`'s drvPath**, with byte-identical package derivations. |
| `capsuleSources.<capsule>.<name>` | a **path**, nothing else | `tart-vms` only (`gitlab-tart.nix`) | the inward hole above: `modules/home/default.nix` must build it with the HOST's pkgs, and publishing the path keeps `flake-module.nix` the only thing outside the capsule that names a file inside it |

`flake.modules` is deliberately **not** re-exported as a public flake output (`touchup.nix`) —
the satellites published `nixosModules.*` to strangers; in-tree the only consumer is
`hosts/nixpi.nix`.

**Two things every capsule dropped on the way in:** its own `treefmt` block and `checks.treefmt`
(this tree has exactly one `nix fmt`), and its own `formatter` / `nixConfig`.

---

### `cloudflared-connector` (wave 3, 241 lines)

The scaffold capsule — the cleanest of the seven, absorbed first precisely because the wave had
to build the boundary machinery around it.

- **Owns:** `services.cloudflaredConnector` — a boot-time, **loginless** Cloudflare Tunnel
  connector for the *remotely-managed (token)* model upstream `services.cloudflared` does not
  support (it only drives locally-managed tunnels, wanting a credentials JSON and in-repo
  ingress). The token is read from an `EnvironmentFile`, so it never reaches argv or the
  world-readable store.
- **Seam:** `flake.modules.nixos.cloudflared-connector`. Consumed by `hosts/nixpi.nix`.
- **Checks:** `checks.aarch64-linux.cloudflared-connector-module` (carried over verbatim).
- **The wave-specific guard it forced:** `checks.aarch64-linux.nixpi-firmware-names` — a rename
  inside this capsule is invisible to `nix flake check` AND to `--dry-activate` on an
  already-provisioned card, and only bites on the **next flash (~40 min)**. It pins the four
  names against the LIVE nixpi config (`firmware-file-cloudflared-token.service`,
  `firmware-file-wifi.service`, `/run/cloudflared-token`, `/run/wpa_supplicant-firmware.conf`),
  plus the two ordering edges and the `EnvironmentFile`. 9 assertions; verified it fails readably
  when the connector unit is renamed.
- `infra/cloudflare/nixpi-tunnel.nix` is the terranix half and is **untouched** by the
  absorption: the connector is the client, the tunnel is the account-side object.

### `firmware-secrets` (wave 4, 363 lines)

- **Owns:** reflash-safe secrets for headless NixOS devices. Plant a secret on the device's FAT
  **firmware** partition from another machine; a boot-time oneshot copies it into a root-only
  `/run` file **before** the consuming service starts.
- **Why it cannot be agenix:** agenix and sops-nix decrypt at activation using the machine's
  **SSH host key**, and re-flashing an SD card **mints a new host key** — so a headless Pi whose
  only remote path is a tunnel whose token *is* one of those secrets is bricked-until-console
  after one reflash. This is the fleet's answer, and `secrets/cloudflared-token.age` is
  operator-only for exactly this reason.
- **Seam:** `flake.modules.nixos.firmware-secrets`. `module.nix` is **byte-identical** to the
  satellite's `modules/firmware-provisioning.nix` (verified with `diff` after `nix fmt`).
- **Checks:** `checks.aarch64-linux.firmware-secrets-module`, carried over verbatim but taking
  `module` as an **argument** — the capsule is entered downward from `flake-module.nix`, never
  upward from a leaf, which is the shape the ast-grep rule enforces.
- **Did NOT come along:** the satellite's `apps/firmware-plant.nix`, a 61-line macOS "cp onto the
  mounted FAT volume" helper duplicating `packages/nixpi-provision.nix` — the `nixpi-provision`
  app [`nixpi-sd-flashing-runbook.md`](../nixpi-sd-flashing-runbook.md) actually tells the operator
  to run. Two copies of one procedure is two chances for the planted BASENAMES to diverge.

### `keychain-secrets` (wave 4, 1,336 lines)

- **Owns:** `local.keychainSecrets` — the `secret set/reveal/rm/ls/exec/copy/fp/bind/unbind/adopt/load`
  CLI over the macOS login Keychain, plus a home-manager loader that exports registered secrets
  into **every** shell, including the non-login bash an AI coding agent spawns for its tools.
  Nothing secret — **not even the key names** — reaches the store or git.
- **ADR-004 (2026-09-20), additive:** `local.keychainSecrets.backend.{type,project,prefix}` +
  `refsRelPath`, four new packages (`secrets-status`, `secrets-rehydrate`, `secrets-push`,
  `secrets-resolve` — `modules/features/keychain-secrets/packages/secrets-backend.nix`, config read at RUNTIME so the perSystem
  packages and the module install the same drvs) and one new check
  (`keychain-secrets-backend-inert`). With `backend.type = "none"` (the default, and what
  `macos` runs today) the loader, `home.activation` and the `darwin-system` drv were measured
  byte-identical to the pre-ADR-004 tree and no CLI is installed. README § Backend.
- **Seam:** `capsuleModules.homeManager.keychain-secrets` (the raw seam; this is the capsule whose
  measurement produced it).
- **Checks:** `keychain-secrets-module` and `keychain-secrets-clis` (the satellite's four package
  checks folded into one — **building a `writeShellApplication` RUNS SHELLCHECK**, and this
  repo's darwin CI leg builds none of its packages, so dropping them would have been ADR-002
  §7.4's "highest-cost silent loss").
- **Two cross-file contracts, now GATED rather than trusted** — this is a security surface:
  - `local.keychainSecrets.loaderRelPath` is preserved **byte-identical** (name, type,
    default), because `modules/darwin/core.nix` derives `launchd.user.envVariables.BASH_ENV` from
    it **by reference** — the only thing covering a bash spawned by a GUI app or a launchd job.
    The eval check pins that default as a **LITERAL** rather than reading the option back, so the
    assertion is not tautological.
  - `checks.aarch64-darwin.bedrock-gate-after-loader` — the **first-ever** test of the
    `mkAfter 1500` / `mkOrder 1600` ordering dependency. `modules/home/claude-bedrock-gate.nix`
    writes the same three shell-init options at 1600 and must run **after** this loader's
    `mkAfter` (= 1500), because it READS a variable the loader exports; reversed, it sees an unset
    variable, does nothing, and Claude Code silently keeps a Bedrock route it cannot reach.
    Proven to FIRE by flipping 1600 → 1400. **It lives in `modules/parts/checks.nix`, not in the
    capsule** — a capsule may not reach outside itself, and only the engine sees both halves.
- **`tests/grammar.sh`** came over verbatim (executable bit intact). It is a **live-Keychain
  functional test**, deliberately not a flake check — which is exactly why nothing else would
  have carried it.
- **`SECURITY.md` did not come as a file.** Half of it was a "report a vulnerability" pointer for
  strangers; the real half — the store is **AMBIENT**, so any process in the tree including an AI
  agent can read every exported value with `env` — is merged into
  [`secrets-and-keychain.md`](../secrets-and-keychain.md) as *The threat model*, next to the agenix
  vault it is the deliberate counterpart to.

### `tart-vms` (wave 5, 3,255 lines) — the most LIVE surface

`macos` runs three Tart-VM GitHub runners and a GitLab lane off this capsule, and both runner
modules sit in `mkDarwin`'s **base list**, so EVERY `mkDarwin` composition evaluates them —
the one exported host (`macos`) and the stranger-identity Mac that
`checks.<system>.template-consumer` composes alike, not just the host that enables them.

- **Owns:** `local.tart.githubRunners.*` (ephemeral Tart-VM-per-job runners), `local.tart.gitlabRunner`,
  `local.tart.vms.*`, `local.tart.runnerSlots` / `local.tart.runnerStateDir`, and five packages.
- **Seam:** `capsuleModules.darwin` — the RAW seam, for a reason independent of `home.packages`
  ordering: both runner modules do `imports = [ ./slots.nix ]`, and **the module system dedupes
  by PATH identity**. `deferredModule` would hand the base list two anonymous
  `{ imports = [ … ] }` wrappers instead of two deduplicable paths.
- **It imports its OWN nixpkgs** with the satellite's narrowed `allowUnfreePredicate` (exactly
  `tart` / `packer` / `tart-guest-agent`) rather than riding a blanket `allowUnfree`, so a
  **fourth** unfree package arriving via a nixpkgs bump still fails the build. The darwin modules
  keep building against the HOST's pkgs.
- **`capsuleSources.tart-vms.gitlab-tart`** — the one entry on that seam. `modules/home/default.nix`
  `callPackage`s it with the **host's** pkgs to put five `nix-gitlab-tart-*` slot shims on `PATH`;
  a derivation from this flake's perSystem pkgs would be a different drv.
- **`darwinStubs` STAYS.** It is the OPTION layer of the capsule boundary (ADR-002 §2), not
  scaffolding — deleting it deletes the isolation test. Its rot cost is stated at the check.
- **`/Users/admin` and `/Users/tester` are CORRECT** — a Cirrus GUEST image's account and an
  `evalModules` fixture. `nix-hardcoded-home-path` is severity **error**, so it was scoped first:
  a `not` clause naming three non-operator users (`admin`, `tester`, `me`), each with its reason
  in the rule header and each proved in the rule-test's `valid` list while every real operator
  home stays in `invalid`. The `claude-code-nix` plugin's `nix-home-path-lint` hook carries the same three names.
- **Checks:** five eval checks carried verbatim, five build checks folded into one
  `tart-vms-packages`, plus a NEW `tart-vms-inert` — `compose.nix` had always ASSERTED IN PROSE
  that these modules are inert in every composition, and nothing measured it.
- **`./darwin.nix` (`local.tart.vms.*`) has no consumer today and is kept on purpose:**
  [`macvm-readd-runbook.md`](../macvm-readd-runbook.md)'s step 1 *is* that module. Its re-add step is
  now a `compose.nix` line, not a re-added input.
- **Two stale `modules/…` references survive** inside `''…''` shell script bodies
  (`modules/features/tart-vms/packages/tart-runner.nix:473`,
  `modules/features/tart-vms/packages/gitlab-tart.nix:75`). Fixing them changes the script
  text → the drv → `darwin-system`, so they are **recorded** in `flake-module.nix`'s header
  rather than silently rotting.

### `media-cli` (wave 5, 4,559 lines) — the LARGEST, with the narrowest live surface

**One option** in `modules/home/default.nix` is the capsule's entire live surface.

- **Owns:** `local.mediaCli` — eleven media/photo CLIs, a durable launchd work queue
  (~1,300 lines) and four Finder right-click Services. One switch turns all of it on or off:
  `local.mediaCli.enable = false` removes the CLIs, both launchd agents, the Services and the
  companion tools together.
- **Seam:** `capsuleModules.homeManager.media-cli` — the most exposed of any capsule to
  `deferredModule` reordering, since it contributes the Mac's largest single `home.packages`
  block.
- **`package-graph.nix` is ONE copy called TWICE** — by `flake-module.nix` for the checks and by
  `module.nix` for `home.packages`. That is the whole reason the file exists. It sits at the
  capsule **ROOT** rather than under `lib/`, because from `lib/` all eleven `callPackage` lines
  would have had to be `../packages/`.
- **It builds its OWN `nix-media-queue` wrapper and sets `ProgramArguments` itself.** Upstream
  home-manager's `/bin/sh -c 'wait4path … && exec'` arg0 **silently loses TCC read access** to
  the very folders the worker exists to work on
  ([`launchd-naming.md`](../../.claude/rules/launchd-naming.md)) — which is why
  `checks.media-cli-module` asserts the arg0 is both `nix-*` **and** a store path, rather than
  being a tautology. *Upstream-first:* grepped the pinned home-manager `modules/launchd/`; the
  only knob is `waitForNixStore` (`default.nix:47-52`), which **drops** wait4path rather than
  moving it inside a named wrapper.
- **The launchd table at the top of `module.nix`** — `QueueDirectories` / `ProcessType` /
  `KeepAlive` / `RunAtLoad` / `StartInterval` — is carried over **verbatim**. It is the record
  that every queue mechanism here is launchd's own, which is what answers *"why hand-roll a job
  queue"* with *"we did not"*.
- **Checks:** six, including `media-cli-queue-state-machine` and `media-cli-inert` (an unset
  `local.mediaCli.enable` must define no agent, no session variable, no activation step and no
  package — the state `nixpi`/`nixvm` are in, since `modules/home/default.nix` imports the capsule
  unconditionally).
- **NOT re-published, on purpose** (ADR-002 §7.3): the satellite's 11 packages and 9 apps.
  Every CLI reaches the Mac through `home.packages`; a second perSystem-pkgs copy would be eleven
  `nix flake show` rows nothing consumes. `media-cli-packages` builds all eleven so the
  shellcheck coverage the satellite's CI had is kept. One-line path back in `flake-module.nix`.

### `local-rag` (wave 6, 473 lines) — the last satellite

- **Owns:** `local.rag.ollama` + `local.rag.pgvector` — a loopback-only
  Postgres + pgvector + pgsql-http and a loopback-only Ollama, wired by bootstrap SQL into an
  in-DB `public.embed(text)` `SECURITY DEFINER` function, a `public.docs` table and an HNSW
  cosine index. Ingest and retrieval are both **plain SQL**; no API key, nothing leaves the
  machine.
- **The seam the whole wave was gated on:** `modules/shared/mcp.nix`'s
  `env.DATABASE_URI = config.local.rag.pgvector.databaseUri`. **That MODULE no longer exists —
  the seam does, with two consumers, both in this repo.** `mcp.nix` was deleted 2026-10-02
  (#734); `modules/home/plugin-mcp.nix:110` now hands the URI to the plugin-lane `postgres` MCP
  launcher as `plainEnv.DATABASE_URI`, and `modules/features/local-rag/pgvector-local.nix:419`
  exports it as the `RAGDB_URI` session variable (#796) for a shell consumer that cannot read a
  Nix option. `checks.local-rag-module` still pins the URI's value as a **LITERAL**, so a
  port/role/db rename fails there instead of quietly returning zero rows, and
  `checks.mcp-launcher-parity` joins the plugin that names `nix-mcp-postgres` against the
  launcher built here — so the consumer side is gated too, in both directions. The lane itself
  is described in [`claude.md`](claude.md) § MCP after the gateway.
- **Layout:** the two modules sit at the capsule ROOT, not under `modules/`, so that
  `pgvector-local.nix`'s `imports = [ ./ollama-local.nix ]` stays a **sibling** path. That
  literal is load-bearing — it is how `local.rag.pgvector` single-sources
  `embedModel`/`embedDim` from `local.rag.ollama` even when a consumer imports only the
  postgres half.
- **Deliberately NO `programs.localRag.enable`.** ADR-002 §4 names a wrapping third switch as the
  two-switch regression the brief forbids; each module keeps gating its own
  `config = lib.mkIf (cfg.enable && isDarwin)`. `checks.local-rag-inert` is what makes that design
  honest.
- **No packages** — the satellite had none either; everything it installs is nixpkgs', reached
  through `home.packages` from inside the two modules. Nothing to shellcheck, so no `-packages`
  check was invented to look symmetrical.
- **Seam choice, measured both ways:** `capsuleModules.homeManager.local-rag`, even though this
  capsule measured drv-**identical** on both seams (it contributes nothing to `home.packages`
  directly, so `deferredModule`'s wrapper has nothing to reorder). Chosen for consistency with
  the other two home-manager capsules, and because order-insensitivity here is a property of
  today's contents rather than of the class.

### `cloud-cli` (born in-tree 2026-09-20) — the one capsule that was never a satellite

`local.cloudCli.aws`: the AWS CLI plus `aws-sso-util`, and **`~/.aws/config.example` —
placeholders only.** It NEVER writes `~/.aws/config`. That file is the human's, written by
`aws configure sso` or by copying the example, living outside Nix and git, and it is what
`modules/home/claude-bedrock-gate.nix` reads at runtime.

- **Why the real file may not be declared here, even though it holds no credential.** Account
  ids, SSO start-URL ids and regions are not secrets, but they ARE **reconnaissance** — they
  tell an attacker where to aim, and this repo is public (ADR-004 §7, inventory #1). Every
  user's shape differs (SSO admin vs IAM-less junior vs preview-only senior), so no single
  committed file could be right for anyone but its author. And sessions are SSO/OIDC-minted
  at `aws sso login`, so almost nothing needs long-lived storage anyway.
- **Upstream-first, and the option it deliberately does NOT set.** `programs.awscli` supplies
  the package — pinned `modules/programs/awscli.nix:19` declares the `package` option,
  defaulting to `awscli2`, and `:62` puts it in `home.packages`. Its `settings` option is left
  `{ }` **on purpose**, because upstream gates writing `~/.aws/config` on `settings != { }`
  (`:64`) — the exact boundary this capsule exists to keep. The example file is a plain
  `home.file`; there is no upstream "write an example" option to reach for.
- **Seam:** home-manager class, so it rides the RAW `capsuleModules` seam rather than
  `flake.modules` (`deferredModule`'s wrapper reorders `home.packages`). Its two checks —
  `cloud-cli-module` and `cloud-cli-inert` — are built on **both** systems, because
  `awscli2`/`aws-sso-util` are Linux-clean and the Pi/VM profiles must be able to enable it.
- It is the worked example of **ADR-003's "content out, governance in"** applied to a cloud
  CLI: the flake ships the TOOL and the SHAPE, the human writes the CONTENT.

## `modules/_lib/` — shared DATA, not modules

One file, and the layer exists for its shape rather than its size:

- **`modules/_lib/nix-ld-libraries.nix`** — `pkgs: with pkgs; [ … ]`. **Not a module** — a function
  returning the nix-ld runtime library list that dynamically-linked NON-Nix binaries (VS Code
  Server, prebuilt language servers, downloaded toolchains) need. **Two consumers in two
  different layers:** `modules/nixos/core.nix:133` (`programs.nix-ld.libraries`) and
  `packages/devcontainer-image.nix:98` (`NIX_LD_LIBRARY_PATH`/`LD_LIBRARY_PATH` baked into the
  distroless image). Widen HERE and both follow.

**Why `modules/_lib/` and not `modules/nixos/` — and not a top-level `lib/` either.** It sat in
`modules/shared/` until 2026-10-02 — wrong twice over, since it is neither home-manager nor a
module (ADR-009 §9b). `modules/nixos/` would be wrong too: the second consumer is `packages/`,
and that import would be `packages/ → modules/nixos/`, a layer crossing this repo fences in the
other direction. A `_lib/` layer is one ANY layer may reach into, so neither consumer crosses one.

**The NAME is a pinned-input convention, not a judgement call** — which is the correction a
one-commit stop at a top-level `lib/` earned. Measured 2026-10-02 against the pins: `blueprint`
is **not** an input of this flake (0 hits in `flake.lock`), so ADR-009 §7's citation of
blueprint's `lib/` key is cited precedent, not an option surface, and `flake-parts` has a `lib/`
in its own repo but declares no such option for consumers. The convention that **is** in a pinned
input is `import-tree`'s dendritic guide (`docs/src/content/docs/guides/dendritic.mdx`,
§ *"The `/_` Convention"*): *"Use underscore-prefixed directories for helper code that shouldn't
be auto-imported"*, worked example `modules/_lib/helpers.nix`. Following the pin beats a local
argument that reached a similar place.

**Nothing here is auto-imported, and the underscore does the work MECHANICALLY.** The `.match`
regex does **not** replace import-tree's default filter — it **accumulates** with it: `.match`
sets `filterf` (pinned `default.nix:234`), only the unused `.initFilter` sets `initf` (`:245`),
so `initialFilter` stays `nixFilter` (`:66`) and `:68` is
`pathFilter = compose (and filterf initialFilter) toString`. Two independent exclusions apply,
either alone sufficient — which is what makes a file *inside* `./modules` safe rather than a new
hazard:

1. `nixFilter = andNot (hasInfix "/_") (hasSuffix ".nix")` (pinned `default.nix:64`). The path
   relative to the walked root (`:84`) is `/_lib/nix-ld-libraries.nix` — `hasInfix "/_"` matches,
   so the library drops it.
2. `flake.nix:447` is `import-tree … .addPath ./modules` with
   `.match ".*/(parts/[^/]+|features/[^/]+/flake-module)\\.nix"`. `builtins.match` must match the
   WHOLE relative path, and `/_lib/nix-ld-libraries.nix` has neither a `parts/<file>` nor a
   `features/<name>/flake-module` component.

**Measured, because the plausible wrong answer is "the regex does it, the underscore is
decorative".** A probe at `modules/_lib/parts/probe.nix` **does** satisfy the regex
(`builtins.match` → `[ "parts/probe" ]`, non-null) and was still never loaded — `flake.probeMarker`
set from it came back as no such attribute. Only mechanism 1 explains that. 2026-10-02.

So it is imported by hand, by the two consumers above. `treefmt` still formats it (its walk starts
at `flake.nix` and `modules/_lib/` is in no `global.excludes` entry) and `ast-grep scan` still
lints it (`sgconfig.yml` scopes RULES, not scanned paths). CI watches it: `modules/_lib/**` is a
path filter in `build-devcontainer.yml`, `warm-nixpi-cache.yml` and `build-installers.yml` — none
of those three has a bare `modules/**` filter (every entry names a specific subdirectory), so the
glob is load-bearing in all three rather than redundant anywhere. `build-devcontainer.yml` never
matched this file at all while it lived under `modules/shared/`, so widening the list did **not**
republish the image (fixed when it moved out).

