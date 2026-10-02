Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `packages/`

Core package set:

- **`grok.nix`** — xAI's `grok` CLI, one of the tree's pinned prebuilt vendor binaries. It replaces
  a per-user `curl … | bash` install that put a self-updating Mach-O in each account's
  `~/.grok/bin`, outside the store and outside git. The URL pattern was read out of xAI's own
  install.sh rather than guessed; xAI publishes NO checksum, so the `hash` is our SRI pin,
  cross-checked byte-for-byte against the copy their installer had already placed locally —
  a reproduction of a verified install rather than fresh trust in a URL. `dontFixup` and
  `dontStrip` are load-bearing: nixpkgs' default fixup rewrites Mach-O headers and would
  invalidate xAI's Developer ID signature. Unfree via a predicate naming ONE package, so a
  second unfree arrival fails rather than being waved through. The self-updater is
  deliberately defeated (read-only store, and the `$HOME/.grok/bin` PATH entry is gone) —
  updating is a version+hash bump. Per-user state still lives in `~/.grok`, which is what
  makes one shared binary correct rather than a conflict.
- **`antigravity-cli.nix`** — Google's `agy` CLI, pinned from the Darwin ARM64 archive named
  by the vendor's release manifest. It replaces the moving `curl -fsSL
  https://antigravity.google/cli/install.sh | bash` bootstrapper, so the binary is shared
  through `environment.systemPackages` and updates are reviewed as a version + hash bump.
- **`acpx.nix`** — the headless client for **ACP** (Zed's Agent *Client* Protocol), which is
  the rail `claude`, `grok` and `agy` already share; it drives one from another with a real
  permission policy (`--permission-policy`, `--deny-all`, `--allowed-tools`, `--max-turns`,
  `--timeout`). Shares the `environment.systemPackages` lane with the two vendor CLIs above
  but is the opposite shape: MIT, built from source. Three packaging traps are in its header
  and all three were measured — upstream ships **pnpm-lock.yaml only** so `buildNpmPackage`
  cannot consume it (`fetchPnpmDeps` + `pnpmConfigHook` instead), **`fetcherVersion = 2` was
  removed in the 26.11 release**, and `pnpmConfigHook` does **not** bring `pnpm` with it the
  way the deprecated `pnpm.configHook` did. It pins `nodejs_22` itself: `engines.node` is
  `>=22.13` and the fleet default `nodejs` is 20.x, so inheriting fails at import rather than
  with a version message. Rationale, and the two interop paths that are CLOSED, are
  [`ADR-007`](../agent-interop-adr.md).
- **`fal.nix`** — fal.ai as two binaries, because the vendor ships two different things:
  `fal` (their own CLI — a serverless runtime, `fal run`/`fal deploy`) and `fal-gen` (ours, a
  thin wrapper over `fal-client`, since the vendor ships NO inference CLI). Both are ephemeral
  `uv run --with` environments, the same shape as the media-cli capsule's `fidelity-enhance`,
  because none of fal's dependency tree is in nixpkgs. Reads `FAL_KEY` from the login Keychain
  and never prints it. Rejected on the way here: `buildPythonApplication` (hand-packaging a
  serverless runtime's whole tree) and the registry's community fal MCP servers (all
  single-source, confidence 0.40, no update date — not enough for a long-running process
  holding an API key). **This is CLOUD inference**, unlike the rest of the media stack, which
  runs against the local ollama daemon.
- **`devcontainer-image.nix`** — MULTI-ARCH devcontainer OCI image (arm64+amd64,
  `dockerTools.streamLayeredImage`), published to GHCR as a manifest list; arch-parameterized
  loader path inside. It is a **CI/Codespaces artifact, not a local-Mac path**: the `vscode`
  user is pinned to uid/gid 1000 (`updateRemoteUserUID: false`, because fakeNss's
  `/etc/passwd` is read-only), so on a Linux host every file it writes into a mounted workspace
  is owned by uid 1000 — not the Mac account (`ismail` 501).
- **`nixpi-provision.nix`** — macOS-only: the four
  `nixpi-flash`/`nixpi-provision`/`nixpi-wifi-creds`/`nixpi-vault-token`
  `writeShellApplication` flake apps that flash the SD card and plant the token+Wi-Fi onto its
  FIRMWARE partition — the executable companion to the `modules/features/firmware-secrets/`
  capsule's `local.firmwareProvisioning`.
- `key-recovery.nix` — **removed 2026-09-15**, with its `key-backup`/`key-recover` apps and
  the iCloud kit. Early-days scaffolding: key custody is the operator's choice, and this
  fleet's posture is that a lost machine's keypair stays lost, because every agenix secret is
  re-issuable by the vendor that minted it. What it did now lives in `bootstrap.sh` (clone +
  the `loginName` guard + activate) and [`new-mac-runbook.md`](../new-mac-runbook.md) (the
  rotate-don't-transport checklist).
- **`activate.nix`** — macOS-only: `activate`, a `darwin-rebuild switch` that re-execs under
  `sudo -H` (Touch ID) instead of dying with "system activation must now be run as root", and
  names the flake dir + `branch@rev` (with `(DIRTY)`) before elevating. Needs no `--flake` or
  `#attr` because `modules/parts/hosts.nix` plants `/etc/nix-darwin/flake.nix`, which
  `darwin-rebuild` resolves, and the attr defaults to `LocalHostName` (= `macos`).
  `sudo darwin-rebuild switch` works too, but names nothing it is about to build.

  **It always builds the MAIN checkout, never the worktree you are sitting in — and that is
  CLAUDE.md § Build & Commands' "MERGING IS STEP 1 OF 2".** The planted link is a **STRING**
  path to the main checkout, so `activate` builds THAT tree's CURRENT branch: never a
  `.claude/worktrees/*` one, and never `main` by default either. From a worktree session, work
  that is already merged on `origin/main` is therefore **ABSENT** from the build until the main
  checkout holds it — `git -C <main checkout> merge --ff-only origin/main` comes FIRST, or you
  rebuild the same generation and the fix reads as failed. Measured cost of skipping it: **70
  min on #725, three activations on #732.** The TELL is a **MISSING `Activating <name>` line**,
  so DIFF the step list against the previous run rather than scanning it for errors — there is
  no error to find. This is why the command prints `branch@rev`: READ that line.

  **The one FALSE alarm in that diagnosis.** A missing plugin or skill is NOT by itself
  evidence of a stale tree. Activation installs only **STORE-PATH** marketplaces; an `https`
  marketplace's plugins arrive at the **NEXT session start**, not at switch time. Only a
  MISSING `extraKnownMarketplaces` entry in `~/.claude/settings.json` actually points at a
  stale tree.
- **`spotlight-launchers.nix`** — macOS-only: from-scratch `.app` bundle generator (original
  in-Nix SVG/icns icons via librsvg+libicns), in two makers. `mkLauncherApp` gives the Android
  emulator a Spotlight-visible, focus-or-launch identity (consumed by
  `modules/home/default.nix`'s `home.file."Applications/Android Emulator.app"`).
  `mkCommandApp` emits **one bundle per fleet operation** — the three `commandApps`
  (`Nix Activate`, `Nix Flake Check`, `Nix Open Repo`) planted by
  `modules/home/spotlight-actions.nix`. Three `shape`s: `terminal` opens a **Ghostty**
  window running the command (`--wait-after-command=true -e /bin/zsh -lc …`) so `activate`'s
  Touch ID sheet and the build log are both visible; `shell` opens an ordinary interactive
  Ghostty window via its own `--working-directory`; `quiet` runs straight from the launcher
  (no consumer today). The working tree resolves through `/etc/nix-darwin/flake.nix` — the
  same link `darwin-rebuild` follows — and travels as an **argv element**, never an exported
  variable: measured 2026-09-23 on Ghostty 1.3.1, a second `open -n` opens a window in the
  EXISTING process, which does not inherit the launcher's environment.
  Both Ghostty shapes share one `ghosttyLook` list: `--background=#6b4300` — the darkest stop
  of the mark's own `goldDeep` gradient, **8.65:1** against the theme's `#FFFFFF` ink (the
  obvious brighter golds fail AA: `#b57b12` is 3.62:1) — plus the same mark again as a
  `bottom-right` corner watermark at `opacity 0.35`. `background-image-fit = none` is
  load-bearing there: it is the only fit that does NOT scale to the window, so the mark stays
  a corner mark instead of the full-bleed backdrop `contain` (the default) would give. The
  image is a 256px PNG rasterised into the store, because Ghostty's `background-image` takes
  **PNG or JPEG only** and will not read the `.svg`. All of it is per-window on the command
  line, so `local.terminalTheme`'s `#300A24` ground is untouched everywhere else.
  All three wear ONE shared `.icns`, the operator's gold chevron
  (`packages/fleet-mark.svg`, a verbatim copy of `~/Pictures/icon.svg`); the non-square
  434.94 x 448 canvas is rewritten to a centred 560 x 560 viewBox **in Nix**, behind an
  `assert`, so the committed file stays refreshable with a plain `cp`.
  **Started at nine, cut to three the same day** — `Nix Deploy nixpi` (deploy-rs failed even
  after a successful Cloudflare Access login) and `Nix Launchd Doctor` (`launchd-doctor` is
  not on a login shell's PATH) were both BROKEN; update-inputs / rollback /
  determinate-status / search-packages / a `code`-based editor bundle were dropped as unused.
  The package header records each, so none returns as an oversight.
  **Not Spotlight's "Actions" lane** — that is App Intents (Swift + signing) or Shortcuts.app
  (iCloud sqlite; the `shortcuts` CLI has no `import`), and a Shortcuts shell script launched
  from Spotlight needs a hand-granted Full Disk Access on `Spotlight.app`. Neither is
  declarable, so the Applications lane is the only one a flake can own.
- `macvm-tart.nix` — removed 2026-09-05 with the `macvm` guest; the generic Tart machinery
  it wrapped lives on in the in-tree `modules/features/tart-vms/` capsule (absorbed from
  `nix-tart-vms` by ADR-002 wave 5),
  and the re-add path is [`macvm-readd-runbook.md`](../macvm-readd-runbook.md).

The no-Nix stage-1 `bootstrap.sh` (the `curl … | bash` entrypoint) lives at the **repo root** —
it is shellchecked as the `bootstrap-lint` derivation (`checks.<system>.bootstrap-lint`), so
the `curl … | bash` bytes are gated exactly like every in-flake script.

Smaller, single-purpose CLIs:

- **`android-phone.nix`** — macOS-only: deterministic wired/wireless ADB operator
  (`list|pair|connect|disconnect|unpair|tcpip|wireless|mirror|doctor`) plus scrcpy mirroring
  for a PHYSICAL Android device; hardens around two live-reproduced adb bugs, an mDNS-cache
  staleness and duplicate-transport device listings. Its operator knowledge is also a GLOBAL
  skill — `android-phone` in the pinned
  [`kattakath/ai`](https://github.com/kattakath/ai).
- **The media packages are NOT here — they are in the `media-cli` capsule.**
  `media-quick-actions.nix`, `media-queue.nix`, `media-toolkit.nix`, `media-describe.nix`,
  `media.nix`, `media-fix.nix`, `media-fix-extension.nix`, `media-extract-audio.nix` and
  `media-transcode.nix` — plus the two media-*adjacent* tools `obs-fb-setup.nix` and
  `fidelity-enhance.nix` — left for `kattakath/nix-media-cli` on 2026-09-05 (which is where
  the `photo-describe` → `media-describe` renaming happened) and came back on 2026-09-12 as
  `modules/features/media-cli/packages/`, with their reasoning intact in their own headers.
  This repo consumes them as `local.mediaCli` (see § `modules/home/` above). There is no
  `nix run .#media-describe`: the capsule publishes **no** packages or apps, on purpose — the
  CLIs reach the Mac through `home.packages` and a second perSystem-pkgs copy would be eleven
  `nix flake show` rows nothing consumes. The one-line path back is in the capsule's
  `flake-module.nix` header.

  The two adjacent tools are **opt-in** in that module
  (`fidelityEnhance.enable`, `obsFacebookSetup.enable`) and deliberately stay OUT of the
  `media-toolkit` bundle: that bundle is what the queue worker and the Finder Services put
  on their `PATH`, so every member becomes a runtime dependency of the queue, and a
  uv/Python environment plus a Keychain read have no business there.
- **The four Keychain CLIs are not here either — and never were.** `secret`, `set-secret`,
  `remove-secret` and `pb-conceal` live in **`modules/features/keychain-secrets/packages/`**,
  inside the capsule whose home-manager module installs them, because a capsule owns its own
  derivations (ADR-002 § anatomy). The flake still exports the first three on darwin
  (`nix run .#secret`), with the same `meta.description` strings as before — those are
  declared once in `modules/parts/packages.nix`'s `apps`, which points at
  `config.packages.<name>`. `pb-conceal` is installed by the module but deliberately not
  published.
- **`jobspy.nix`** — a reproducible `uv`-ephemeral wrapper CLI around the `python-jobspy`
  library for scraping job boards.
- **`jsonresume.nix`** — dual-engine `jsonresume <download|print|validate|markdown|text>`
  wrapper (`resumed` for PDF/validate, `resume-cli` where `resumed` falls short); see the
  `jsonresume-tailor` skill.
- **`mermaid-ascii.nix`** — packages `AlexanderGrooff/mermaid-ascii`, not in nixpkgs, for the
  diagrams-as-ASCII convention.
- **`metube.nix`** — MeTube from source; nixpkgs has no package for it. The Angular UI must
  land at `ui/dist/metube/browser`, the path `app/main.py` actually serves. Python deps come
  from nixpkgs rather than `uv sync`: the app is a handful of imports and the lockfile would
  pull a SECOND yt-dlp. `deno`, `ffmpeg` and `aria2` are on PATH because yt-dlp looks them up
  by name. Consumed by `modules/darwin/metube.nix`.
- **`yt-dlp-web-ui.nix`** — yt-dlp-web-ui v4 from source, because every easier route is
  broken: the upstream flake's `systems` list is x86_64-linux only, its Nix still calls
  `buildGo123Module` and passes the `-host`/`-port` flags v4 removed (`main.go` takes only
  `-conf`), the published release binaries are Linux ELF, and Docker Hub has no `:v4` tag
  while `latest` ships a yt-dlp too old for YouTube. v4 `//go:embed`s the UI, so the frontend
  is built and copied into the tree before `go build`. Consumed by
  `modules/darwin/yt-dlp-web-ui.nix`.
- **`page-lab-pick.nix`** — the `page-lab` plugin's two-way element picker as a fleet CLI. It
  exists for ONE reason: Node 20 here has no global `WebSocket`, so the raw-CDP client must
  either re-exec with `--experimental-websocket` or run on Node 22+ — pinning `nodejs_22`
  removes the flag from the fleet path entirely. Not the only way to run the picker (the
  plugin's `scripts/pick-element.mjs` under `node` still works); this is the reproducible
  entry point. Deliberately **not** a launchd agent and never automatic: arming a picker
  swallows the next click on every armed tab, so it stays an explicit act with a visible
  start and a guaranteed disarm. Its plugin tree is the pinned `kattakath/ai` flake input,
  passed in by `modules/parts/packages.nix` with no default, so a missing pin is an eval
  error rather than a silent fallback.
- **`claude-otel-doctor.nix`** — health check for the `local.claudeOtel` collector (launchd
  agent, OTLP port, events-file freshness). See
  [`claude-code-observability-runbook.md`](../claude-code-observability-runbook.md).
- **`resend-cli.nix`** — the official Resend CLI, not yet in nixpkgs so `npx`-wrapped and
  version-pinned same as `mcp-wordpress`/`telegram-mcp`; injects `RESEND_API_KEY` from the
  login Keychain at run time — wired only via `home.packages`, no matching flake app. The
  lookup is by Keychain **service** `resend.com:api`, not by the env name, so set it with
  `pbpaste | secret set --env RESEND_API_KEY resend.com:api`.
- **`design-tokens/`** / **`email-signature/`** — small self-contained build-script-backed
  packages for their respective assets.

## Userscripts — REMOVED from the fleet entirely (2026-09-14, commit `535f1ef`)

**The fleet declares zero userscripts, and gates none.** That commit deleted the
`kattakath-userscripts` input, every `local.ungoogledChromium.userScripts.scripts` entry and
`checks.<system>.userscripts`; nix-personal (`c013aa5`) deleted `modules/userscripts.nix`, its
own `gitlab:ismailkattakath/userscripts` input and both `checks.userscripts-lint` /
`checks.userscripts-meta` the same day. The scripts are **published to Greasy Fork** (Sleazy
Fork for adult-site scripts) instead — the last one out, `google-photos-icon-nav`, is
`greasyfork.org/scripts/595764`.

**Why publication beat declaration, stated as the trade it is.** A fork-installed copy carries
`@updateURL` and **self-updates**; a Nix-materialised `file://` copy structurally cannot, because
the old pipeline *banned* `@downloadURL`/`@updateURL`/`@installURL` outright — pointed at this
repo they would have let a push to `main` mutate an installed script with no activation. So every
change cost a `@version` bump, a `flake update`, an `activate` and a manual install click, and the
end state was still a script that never updated itself. Publishing inverts that: one upload, and
every install everywhere follows. What was given up is the declarative guarantee — a fresh Mac no
longer ends up with the scripts installed, and the linter no longer runs in this repo's CI (it
still lives in the `page-lab` plugin, and Greasy Fork enforces its own rules at upload).

**The option is deliberately KEPT, with zero scripts.**
`local.ungoogledChromium.userScripts` (`enable` + the `attrsOf (nullOr path)` `scripts` attrset)
stays in [`modules/home/chromium.nix`](../../modules/home/chromium.nix) — see § `chromium.nix`
above for the materialisation and the reason Chromium allows nothing more declarative.
Violentmonkey is still sideloaded by `enable`; `scripts` is simply empty, and
`xdg.dataFile` is gated on non-empty so an empty attrset writes nothing. It costs nothing and
keeps the seam available if a script ever has to be fleet-pinned again (a private one, say, that
must not go to a public fork).

**The authoring METHOD is unchanged and lives in the plugin.** The portable
[`page-lab` plugin](https://github.com/kattakath/ai/tree/main/plugins/page-lab)
owns the probes, the patterns, the Greasy Fork rulebook and the metadata linter; it **measures
the live page** before it writes a selector, routing on the diff between the state the site
already gives you and the state you want:

| Diff verdict | What it means | What to write |
|---|---|---|
| **DOM-DIFFERS** | a selector/attribute *can* force it | set the attribute or class the site itself sets |
| **DOM-IDENTICAL** | the switch is a **pure CSS media query** — no selector can force it | lift that condition's rules and re-serve them in a **band** |
| **STATE-B-UNREACHABLE** | the state does not exist; you are constructing UI | every invented selector carries its own measured line in the file's WHY block |

The project skill [`userscript-author`](../../.claude/skills/userscript-author/SKILL.md) is now
only the *delivery* half — publish, then install — and no longer touches Nix.

**The worked example, kept because the lesson outlives the file.**
`google-photos-icon-nav` makes `photos.google.com` render **its own** narrow-viewport icon rail
at every window width, handing the reclaimed width to the photo grid. *The measurement was the
design:* the DOM is *identical* either side of the responsive breakpoint — same tags, same
classes, same attributes — so the switch is a **pure CSS media query** and nothing a selector can
force. The script therefore lifts Google's own `@media` blocks out of their wrapper and replays
them unconditionally, selected by `conditionText` within an **800–1200px band** (never a
hardcoded pixel; all blocks sharing a width are accumulated, widest wins) and re-applied from a
`document.head` **`childList`** MutationObserver — not from history hooks, and never with
`subtree`, which over this ~1.8 MB DOM would fire thousands of times a scroll. Consequence: the
file contains **not one Google class name**, so the JSCompiler churn (`RSjvib`, `JBVD2d`, …) that
breaks every hand-written Photos userscript cannot break it; an unreadable cross-origin sheet
degrades it to a **no-op**, which is the correct failure. Two page properties still shape it: the
grid is **JS-virtualised** — tile geometry *and* thumbnail request sizes derive from the measured
pane width — so the CSS must be followed by a synthetic `resize`, coalesced in one `rAF`; and only
the pane **wrapper** may ever be shifted, because it is the `position:absolute` containing block
for the main pane, which sits at `left:0` inside it, so moving both would double the offset.

