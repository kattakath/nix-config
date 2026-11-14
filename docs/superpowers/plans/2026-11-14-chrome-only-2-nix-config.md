# Chrome-only, part 2 — `nix-config` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Google Chrome the fleet's only visible browser, purge ungoogled-chromium and every page-lab hook-up, and zap undeclared apps with their traces — one push to `main`, then `activate`.

**Architecture:** A new HM module declares Chrome's extensions via upstream `programs.google-chrome`; `chromium.nix` and `page-lab.nix`'s plugin half are deleted; the pinned Chrome for Testing survives as `pinned-chrome.nix` feeding puppeteer; `homebrew.onActivation.cleanup = "zap"` removes the cask and traces; fleet-doctor reports future non-Homebrew strays.

**Tech Stack:** nix-darwin, Home Manager (`programs.google-chrome`), Homebrew via nix-darwin, flake-parts checks.

**Spec:** `docs/superpowers/specs/2026-11-14-chrome-only-browser-design.md`. **Precondition:** part 1 (`2026-11-14-chrome-only-1-skills.md`) landed and `claude plugin list` shows `userscript-lab@kattakath`, no `page-lab`.

## Global Constraints

- Every `.nix` edit: `git add -A` before any eval; `nix fmt` before commit.
- Upstream-first citations in each new module header: HM `modules/programs/chromium.nix` (`supportsUserExtensions` true on darwin; `External Extensions/<id>.json`), nix-darwin `modules/homebrew.nix` (`cleanup` enum incl. `"zap"`).
- Extension ids (Web Store, verify each against its live listing page before commit): Violentmonkey `jinjaccalgkegednnccohejagnlnfdag`, iCloud Passwords `pejdijmoenmkgeppbflobdenhhabjlaj`, Claude in Chrome `fcoeoabgfenejglbffodgkkbkcdhcgfn`, AMOLED theme `faeadnfmdfamenfhaipofoffijhlnkif`, MeTube Downloader `fbmkmdnlhacefjljljlbhkodfmfkijdh`, **uBlock Origin Lite** and **Advanced Font Settings** — ids not known, read from the listing.
- No Kapture, no full uBO, no local `.crx`, no native-messaging replant.
- Skill references: `userscript-lab:userscript-author`, `userscript-lab:site-redesign`; lint path `plugins/userscript-lab/scripts/userscript-meta-lint.sh`.
- No client / work-account literal (the second Chrome profile is "the work profile"); no `path:N` line cites in repo files; comments say why, one sentence of history max.
- Commit subjects per `.claude/rules/pr-title.md`; no AI attribution.

## Review Focus

1. **Bookmarks and installed userscripts in profiles that `zap` will delete** (Chromium, Brave, Opera) — Task 1 exports them before `activate`.
2. **`adopt` refusing because the installed app version ≠ cask version** — Task 6 Step 4 falls back to `brew install --cask --force` over the app.
3. **A check that reads `programs.chromium` or the page-lab overlay** throws at eval once the module is gone → Task 3/4 build every touched check.
4. **Puppeteer launching a browser that no longer exists** (`/Applications/Chromium.app`) → Task 4 test asserts the var points into `/nix/store`.
5. **The committed spec/plans failing `docs-indexed`** → Task 0 Step 3 builds that check first.

---

### Task 0: Worktree + docs gate

- [ ] **Step 1:** `git worktree add "$S/nc-chrome" -b chrome-only main` (local `main` carries spec commit `6d002946`; rebase onto `origin/main` before push).
- [ ] **Step 2:** `git add -A && nix build --no-link .#checks.aarch64-darwin.docs-indexed` → Expected: success. If it fails on `docs/superpowers/**`, add the spec and both plans to `docs/map/docs-index.md` with one-line annotations, re-run → success. Commit with the docs change.

### Task 1: Pre-zap exports (operator-confirmed)

- [ ] **Step 1:** Violentmonkey in Chromium: list installed scripts (name + Greasy Fork URL) from its extension storage or its Export ZIP into `$S`; hand the list to the operator. They live on Greasy Fork, so the list is enough to reinstall.
- [ ] **Step 2:** `buku --ai` imports bookmarks from the Chromium, Brave and Opera profiles (dedup is buku's). Report the bookmark count before/after.
- [ ] **Step 3:** AskUserQuestion: "Exports done (N scripts, M bookmarks). Anything else to keep from Chromium/Brave/Opera before zap deletes their profiles?" — `Nothing, proceed (Recommended)` / `Wait`.

### Task 2: Chrome extensions module

**Files:** Create `modules/home/google-chrome.nix`; Modify `modules/home/default.nix` (import + `local.googleChrome.enable = isMacosHost;`).

**Interfaces:** Produces option `local.googleChrome.enable` (bool, default false).

- [ ] **Step 1: Test** — `nix eval --json .#darwinConfigurations.macos.config.home-manager.users.ismail.programs.google-chrome.extensions --apply 'map (e: e.id)'` → Expected now: error (option unset / module absent).
- [ ] **Step 2:** Write the module: `programs.google-chrome = { enable = true; package = null; extensions = [ { id = …; } … ]; }` (the cask installs Chrome), gated `lib.mkIf (cfg.enable && isDarwin)`.
- [ ] **Step 3:** Re-run Step 1 → Expected: exactly the 7 ids from Global Constraints.
- [ ] **Step 4:** `nix build --no-link .#darwinConfigurations.macos.system` → success. Commit: `darwinConfigurations: declare Chrome extensions via programs.google-chrome`.

### Task 3: Delete ungoogled-chromium

**Files:** Delete `modules/home/chromium.nix`, `modules/home/chromium-extensions/`. Modify `modules/home/default.nix` (import, `local.ungoogledChromium.enable`, the passkey comment → one sentence), `hosts/macos.nix` (`"ungoogled-chromium"` cask, `local.ungoogledChromium.debugLauncher`, related comments), `modules/home/default-browser.nix` (comments), `modules/parts/checks.nix` (`malayalam-crx-parity` and the Violentmonkey-sideload check — delete).

- [ ] **Step 1: Test** — `grep -rnI 'ungoogled\|ungoogledChromium\|nix-chromium-debug\|malayalam-crx\|chromium-extensions' --exclude-dir=.git --exclude-dir=superpowers modules hosts packages` → Expected now: hits.
- [ ] **Step 2:** Make the deletions/edits.
- [ ] **Step 3:** Re-run Step 1 → Expected: no output. `git add -A && nix fmt && nix build --no-link .#darwinConfigurations.macos.system && nix flake check --all-systems --no-build` → success.
- [ ] **Step 4:** Commit: `darwinConfigurations, checks: remove ungoogled-chromium, its module and checks`.

### Task 4: page-lab out; pinned Chrome for Testing kept

**Files:** `git mv modules/home/page-lab.nix modules/home/pinned-chrome.nix` (option `local.pinnedChrome.enable`; drop the profiles overlay and `PAGE_LAB_CHROME`; set `home.sessionVariables.PUPPETEER_EXECUTABLE_PATH` to the existing `chromeExecutable`). Modify `modules/home/default.nix` (import, enable, remove the old `/Applications/Chromium.app` `PUPPETEER_EXECUTABLE_PATH`, page-lab plugin enablement wherever `page-lab@kattakath` appears → `userscript-lab@kattakath`), `modules/home/metube.nix` (`cookiesfrombrowser = [ "chrome" ]`, comment → "Chrome Safe Storage"). Delete `packages/page-lab-pick.nix`; Modify `modules/parts/packages.nix`, `modules/parts/hosts.nix`, `modules/parts/compose.nix` comment, `modules/home/terranix-drift.nix` + `house-style.nix` comments. `modules/home/claude-guardrails.nix` + `modules/_lib/secret-read-paths.nix`: remove the `.local/state/page-lab` deny.

- [ ] **Step 1: Test** — `nix eval --raw .#darwinConfigurations.macos.config.home-manager.users.ismail.home.sessionVariables.PUPPETEER_EXECUTABLE_PATH` → Expected now: `/Applications/Chromium.app/...` (the failing state).
- [ ] **Step 2:** Make the edits.
- [ ] **Step 3:** Re-run Step 1 → Expected: starts with `/nix/store/` and ends `Google Chrome for Testing`. `grep -rnI 'page-lab\|pageLab\|PAGE_LAB\|page_lab' --exclude-dir=.git --exclude-dir=superpowers modules packages hosts flake.nix` → no output.
- [ ] **Step 4:** `kattakath-skills` pin: `nix eval --json .#darwinConfigurations.macos.config.home-manager.users.ismail.local.pluginMcp.servers --apply builtins.attrNames`; if any `@kattakath` launcher remains, keep the input and rewrite flake.nix's "PINNED FOR TWO THINGS" comment to the one remaining use; else remove the input (`nix flake lock`, shape-only) and `mcp-launcher-parity`'s pin use.
- [ ] **Step 5:** `nix build --no-link .#checks.aarch64-darwin.mcp-launcher-parity .#darwinConfigurations.macos.system && nix flake check --all-systems --no-build` → success. Commit: `darwinConfigurations, packages, checks: drop page-lab; pinned Chrome for Testing feeds puppeteer; MeTube reads Chrome`.

### Task 5: Agent surface — skills, commands, docs, memory

**Files:** `.claude/skills/userscript-author/SKILL.md`, `.claude/commands/userscript.md`, `.claude/skills/mcp-scout/SKILL.md`, `docs/map/{modules-home,claude-code,packages,docs-index}.md`, `docs/{agent-resource-externalization,macos-settings-surface,mcp-gateway,scheduled-runs-adr,externalization-boundary-adr,structural-boundaries-adr,open-design,monoflake-capsule-adr}.md`, `CLAUDE.md`; `modules/parts/checks.nix` lint-path reference. Memory dir: `drive-chromium-not-chrome.md` + `MEMORY.md` line, and the memories naming page-lab/CDP (Outlook via page-lab, LinkedIn trusted events, userscript fleet workflow, DevTools sourcePath, emulator Firefox).

- [ ] **Step 1:** Rewrite: method skill is `userscript-lab:userscript-author`; lint path per Global Constraints; browser rail = Claude in Chrome; on a permission wall ask, never CDP. Live-doc mentions of page-lab/Chromium → current truth or deleted (history: one sentence where it prevents a wrong action).
- [ ] **Step 2:** Memory: rewrite `drive-chromium-not-chrome` as `drive-claude-in-chrome` (rule: Claude in Chrome only; each profile's extension login routes the account; ask on a wall; never CDP), update `MEMORY.md`; mark each CDP-dependent memory superseded or rewrite it.
- [ ] **Step 3: Test** — `grep -rnIi 'page-lab\|chromium' --exclude-dir=.git . | grep -v 'superpowers/' ` → Expected: only pinned Chrome for Testing / listing-lens context or one-line history notes; review each hit. `wc -c CLAUDE.md` < 40000. `nix build --no-link .#checks.aarch64-darwin.{docs-indexed,line-refs-cite-constructs,claude-md-budget}` → success.
- [ ] **Step 4:** Commit: `claude, docs: Claude in Chrome is the browser rail; userscript-lab replaces page-lab`.

### Task 6: Zap undeclared apps

**Files:** Modify `modules/darwin/homebrew.nix` (`cleanup = "zap"`, comment rewritten), `hosts/macos.nix` comments mentioning `cleanup = "uninstall"`, `.claude/skills/fleet-doctor/SKILL.md` (new step).

- [ ] **Step 1: Test** — `nix eval --raw .#darwinConfigurations.macos.config.homebrew.onActivation.cleanup` → Expected now: `uninstall`.
- [ ] **Step 2:** Set `"zap"`; re-run → `zap`. Build macos system → success.
- [ ] **Step 3:** fleet-doctor step "undeclared apps": list `/Applications/*.app` minus artifacts of `brew list --cask` (`brew info --json=v2 --installed`), minus `masApps`, minus `/Applications/Nix Apps`, minus Apple-signed system apps; report each with its matching cask token if one exists (`brew search --cask`); fix = `brew install --cask --adopt <token>` then `activate`. Report-only; never deletes.
- [ ] **Step 4:** Commit: `darwinConfigurations, claude: zap undeclared casks; fleet-doctor reports non-Homebrew apps`.

### Task 7: Land + activate

- [ ] **Step 1:** Leak gates: `nix develop -c gitleaks git --log-opts="origin/main..HEAD" --redact --no-banner` + Drive `client-literals.txt` over diff and messages → no findings.
- [ ] **Step 2:** `git fetch && git rebase origin/main && git push origin HEAD:main`; `git -C ~/Developer/github.com/kattakath/nix-config merge --ff-only origin/main`.
- [ ] **Step 3:** `brew install --cask --adopt brave-browser opera` (fallback on version mismatch: `--force`), so the next activation's zap sees them as undeclared.
- [ ] **Step 4:** AskUserQuestion confirm: "activate now: zap deletes Chromium, Brave, Opera and their profiles irreversibly" — `Activate (Recommended)` / `Wait`. Then `activate`.
- [ ] **Step 5: Verify** — `ls /Applications | grep -iE 'chromium|brave|opera'` → empty; `ls ~/Library/Application\ Support | grep -iE 'chromium|BraveSoftware|com.operasoftware'` → empty; Chrome's `chrome://extensions` lists the 7; new Claude Code session shows no `page-lab` tools/skills and does show `userscript-lab`.
- [ ] **Step 6:** Operator clicks (state them): Violentmonkey "Allow User Scripts"; Advanced Font Settings → Malayalam = Noto Sans/Serif Malayalam; reinstall scripts from Task 1's list. Then one MeTube age-gated fetch and one `resumed` PDF render succeed.
- [ ] **Step 7:** AskUserQuestion confirm deleting `~/.local/state/page-lab` (dedicated-profile cookies) — `Delete (Recommended)` / `Keep`; run `rm -rf` on yes.
