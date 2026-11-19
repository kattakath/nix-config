# Chrome-only browser — design (2026-11-14)

Status: **SUPERSEDED in part 2026-11-18**: one rail became two (Claude in Chrome first, then the `page-tools` plugin; see its README). Was: **DRAFT, awaiting operator approval.** Size: a project across two repos
(`kattakath/skills`, then `nix-config`) plus agent memory, landed **big-bang**: each repo in one
push, skills first.

## Intent — why

The operator's own reasons, 2026-11-14:

- **Passkeys.** ungoogled-chromium cannot use Touch ID for passkeys; Google Chrome can.
  (Already recorded in `modules/home/default.nix`: the cask lacks the entitlement, measured
  2026-09-15, and no Chromium build fixes it.)
- **Agent inconsistency.** Claude sometimes drives Claude in Chrome, sometimes Kapture, sometimes
  page-lab's CDP attach — and CDP fails when Chromium was launched without the debug port.
- **Double sessions.** Logins are kept alive in both Chromium and Chrome.
- **Lost time.** He cannot tell which browser / window / profile / desktop Claude went to.

Chrome wins because it has Touch ID passkeys, Claude in Chrome is Claude Code's shipped default
and now outperforms CDP for him, and its Claude Code settings live in `~/.claude.json`.

And, on undeclared software (operator, 2026-11-14): **anything undeclared must be purged
forcefully, without any trace.**

## Goals

1. **One visible browser: Google Chrome.** ungoogled-chromium leaves the fleet, zapped.
2. **One agent browser rail: Claude in Chrome.** The page-lab plugin is **purged totally** —
   every CDP server, script, skill, command and fleet hook-up.
3. **Userscript method survives**, ported onto Claude in Chrome: page-lab's `userscript-author`
   **and** `site-redesign` skills move to a new small plugin in `kattakath/skills`.
4. **Undeclared apps die with their traces.** `homebrew.onActivation.cleanup = "zap"`; existing
   non-Homebrew strays (Brave, Opera) are adopted then zapped; future strays are reported.
5. Every other Chromium-dependent job keeps working, re-homed (table below).
6. Agent memory flips from "drive Chromium, never Chrome" to "drive Claude in Chrome; on a
   permission wall, **ask**; never CDP".

## Non-goals

- **The headless Nix-pinned engine stays**: `playwright-driver.browsers-chromium` (Chrome for
  Testing). No window, no sessions, never acts as the operator ("that's fine", 2026-11-14). It
  serves puppeteer and listing-lens's Crawlee `PlaywrightCrawler` (listing-lens ADR-0003). Its Nix
  module is renamed off "page-lab" since page-lab is gone.
- No `~/.claude.json` writer. Measured 2026-11-14: `claudeInChromeDefaultEnabled`,
  `cachedChromeExtensionInstalled`, `hasCompletedClaudeInChromeOnboarding` are already `true`.
- No activation that deletes arbitrary `/Applications` entries (rejected: a custom destructive
  allowlist; one mistake deletes a real app). Future strays are reported, then adopt+zapped.

## Anti-goals (a failure even if it builds)

- **Claude still lands in a second browser.** Any path from Claude Code to a CDP attach, or a
  visible non-Chrome window, recreates the confusion.
- **A silent fallback.** On a Claude in Chrome per-site permission wall (why the 2026-10-26 rule
  went to Chromium), the agent **asks**; it never switches rail.
- **A soft purge.** Chromium, page-lab, or a stray browser left installed "just in case".

## Constraints

- Public repos: no client or work-account literal anywhere. The second Chrome profile is "the
  work profile".
- Upstream-first:
  - Chrome config via pinned Home Manager `programs.google-chrome` (darwin
    `supportsUserExtensions = true`; writes `External Extensions/<id>.json` with a Web Store
    `external_update_url`). Branded Chrome on macOS installs external extensions **only from the
    Web Store** — no local `.crx`.
  - Purge via pinned nix-darwin `homebrew.onActivation.cleanup` enum
    `[ "none" "check" "uninstall" "zap" ]`; `"zap"` runs `brew bundle --cleanup --zap`.
  - Searched 2026-11-14: no nix-darwin option or community tool purges non-Homebrew apps.
- Extensions declared through `External Extensions` install into **every** Chrome profile,
  work profile included (builder's call: acceptable; all are generic).
- `zap` removes Chromium's profile (`~/Library/Application Support/Chromium`: sessions, history,
  cookies) **irreversibly**. Operator accepted, 2026-11-14.
- `darwinConfigurations` change → `activate` is the darwin check (no darwin CI on push).

## How profile targeting works (found, no config)

`list_connected_browsers` lists extension instances **connected to the current claude.ai
account**. Measured 2026-11-14: both Chrome profiles have the extension installed; the personal
session sees exactly one, `inUse: true`; `switch_browser` reports no other. Each profile's
extension login **is** the routing key. Breaks only if one account is signed in to two profiles
(the tools then ask) or a profile's extension is re-signed to the other account.

## Approaches

**Landing** (operator chose big-bang):

| | Phased | **Big-bang (chosen)** | Soft purge |
|---|---|---|---|
| What | Rewire, delete in a 2nd push | Rewire + delete in one push per repo | Rewire, keep Chromium |
| Lose | Two pushes | Unverified rows break with no fallback | Keeps the second browser |

**Agent browser tooling** (operator: purge page-lab, look for off-the-shelf first):

| Candidate | Verdict | Evidence |
|---|---|---|
| **Claude in Chrome** (built-in) + Anthropic's `claude-in-chrome` skill | **Adopted** for drive / diagnose | has console, network, `javascript_tool`, `gif_creator` |
| `chrome-devtools-mcp`, `browser-use`, `playwright` (official marketplace) | Rejected | CDP or own browser = a second rail |
| danielrosehill `userscript-development` | Rejected for userscripts | read all 8 skills: 390 lines, 4 commits, 0 stars; Tampermonkey + GitHub-raw publishing (operator uses Violentmonkey + Greasy Fork); bails on any `GM_*`; `test-userscript` calls `playwright_evaluate`, not a Claude in Chrome tool |
| **Port own `userscript-author` + `site-redesign`** | **Chosen** | 1,384-line measured method with ~5 CDP mentions; `site-redesign` ~1,800 lines |

**Undeclared apps** (operator chose zap + adopt-then-zap):

| | **Zap + adopt-then-zap (chosen)** | Zap + enforce on activate | Zap only |
|---|---|---|---|
| Future strays | reported by fleet-doctor; fix = adopt+zap | custom activation deletes | ignored |
| Risk | one manual step per stray | allowlist bug deletes a real app | strays persist |

## Work, by repo

### 1. `kattakath/skills` (lands first)

| Change | Status |
|---|---|
| New plugin (name: builder's call, e.g. `userscript-lab`) holding ported `userscript-author` + refs (`patterns`, `probes`, `gm-api`, `greasyfork`) and `site-redesign` + refs | decided |
| Retarget every CDP tool mention to Claude in Chrome (`evaluate_script` → `javascript_tool`, `take_snapshot` → `read_page`, etc.) | decided |
| `site-redesign`'s **trusted-event / `document-start` verification**: re-prove what Claude in Chrome can do; where it cannot, say so in the skill rather than claim the old guarantee | **verify** |
| Delete `plugins/page-lab` entirely; marketplace entry removed | decided |
| gif-meme: upload through Claude in Chrome `upload_image` / `file_upload`, not CDP 9222 | **verify** one real upload |
| Any other plugin naming page-lab / Chromium / 9222 (grep: `android-phone`'s android-chrome is a *phone* CDP — out of scope unless it routes desktop) | builder sweeps |

### 2. `nix-config` (lands second)

| Job / file | New state | Status |
|---|---|---|
| `ungoogled-chromium` cask (`hosts/macos.nix`) | removed; `zap` removes the app + traces | decided |
| `modules/home/chromium.nix`, `local.ungoogledChromium`, `nix-chromium-debug`, `debugLauncher`, `chromium-extensions/` | **deleted** | decided |
| `homebrew.onActivation.cleanup` (`modules/darwin/homebrew.nix`) | `"uninstall"` → `"zap"` | decided |
| Brave, Opera (not Homebrew-installed: absent from `brew list --cask`, no pkg receipt) | one-time `brew install --cask --adopt brave-browser opera`, then `activate` zaps them | decided (confirmed step) |
| Future undeclared apps | new fleet-doctor step: list `/Applications` entries not owned by a declared cask, `masApps`, `Nix Apps`, or Apple; report, never delete | decided |
| Chrome extensions — new `programs.google-chrome` module: Violentmonkey (MV3, Chrome 138+ needs one manual "Allow User Scripts" click), **uBlock Origin Lite** (replaces MV2 uBO; operator accepted), iCloud Passwords, Claude in Chrome, Advanced Font Settings (replaces repo malayalam crx; set `Mlym` once, Chrome Sync carries it), AMOLED theme, MeTube Downloader | each Web Store id **verified** before commit | decided |
| Kapture extension | dropped | decided |
| iCloud Passwords native-host replant | dropped — macOS ships it for Chrome | decided |
| `checks.malayalam-crx-parity` + the Violentmonkey-sideload check | deleted, or re-pointed at the Chrome list (builder's call) | decided |
| `modules/home/page-lab.nix` | renamed (e.g. `pinned-chrome.nix`); exports the CfT path once; profiles overlay deleted | decided |
| `PUPPETEER_EXECUTABLE_PATH` | references that one exported CfT path, never a copy | decided |
| MeTube `cookiesfrombrowser` | `["chrome"]` | decided |
| `packages/page-lab-pick.nix`, `/pick` | deleted | decided |
| `kattakath-skills` flake input | kept only if a consumer remains (`mcp-launcher-parity`?); else removed | builder checks |
| page-lab refs in `.claude/skills/userscript-author`, `/userscript`, `mcp-scout`, `secret-read-paths.nix`, `claude-guardrails.nix`, `house-style.nix`, `terranix-drift.nix`, `parts/{hosts,compose,packages,checks}.nix`, `docs/**`, `CLAUDE.md` | rewritten to the new plugin / Claude in Chrome, or deleted | decided |
| Chromium mentions in comments | rewritten, not appended: one-sentence why (passkeys) where history matters; no `path:N` cites | decided |

### 3. Agent memory

Rewrite `drive-chromium-not-chrome` (rail = Claude in Chrome; ask on a wall; never CDP). Sweep
memories that assume page-lab/CDP (Outlook via page-lab, LinkedIn trusted events, userscript
fleet workflow, DevTools sourcePath, emulator Firefox) — rewrite or mark superseded.

## Left to the builder

- New plugin name and file layout; module names.
- Whether old checks die or are re-pointed.
- Commit subjects per `pr-title.md` (nix-config: `darwinConfigurations, checks, packages,
  claude, docs: …`).

## Verification

Before each push:
1. skills: the repo's own plugin tests / lint; grep proves no `page-lab`, `chrome-devtools`,
   `kapture`, `9222` left outside history notes.
2. nix-config: `git add -A && nix fmt`; `nix build --no-link .#darwinConfigurations.macos.system`;
   `nix flake check --all-systems --no-build`; touched `checks.*`; `grep -rniI 'chromium\|page-lab'`
   — every hit is the pinned CfT, listing-lens, or a one-line history note; `wc -c CLAUDE.md`.
3. Leak gates on both: gitleaks over `origin/main..HEAD` + Drive `client-literals.txt`.

After push (`git -C <main checkout> merge --ff-only origin/main`, then `activate`):
- `/Applications/Chromium.app`, Brave, Opera and their `~/Library` traces are gone.
- Chrome lists every declared extension; Malayalam renders in Noto.
- One gif-meme upload, one MeTube age-gated fetch, one puppeteer PDF succeed.
- A new Claude Code session exposes **no** `page-lab` tools or skills; the new userscript plugin
  loads.
