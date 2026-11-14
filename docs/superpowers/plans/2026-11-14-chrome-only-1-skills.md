# Chrome-only, part 1 — `kattakath/skills` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `page-lab` plugin with a browser-rail-free `userscript-lab` plugin (Claude in Chrome only) and move gif-meme off CDP, in one push to `kattakath/skills` main.

**Architecture:** Port the *method* (skill text + method references) of page-lab's `userscript-author` and `site-redesign` into `plugins/userscript-lab`; keep the one browser-free script, `userscript-meta-lint.sh`; delete every CDP script, MCP server, picker, gate and test. Verification inside the skills becomes "install in Violentmonkey + Claude in Chrome `javascript_tool` / `read_page` / `read_console_messages` checks".

**Tech Stack:** Claude Code plugin layout (`.claude-plugin/plugin.json`, `skills/*/SKILL.md`), bash, Python CI scripts in `scripts/`, GitHub Actions `validate.yml`.

**Spec:** `kattakath/nix-config` `docs/superpowers/specs/2026-11-14-chrome-only-browser-design.md`. Part 2 (`2026-11-14-chrome-only-2-nix-config.md`) lands after this one.

## Global Constraints

- Plugin name **`userscript-lab`**; skills keep their names: `userscript-lab:userscript-author`, `userscript-lab:site-redesign`. Part 2 references exactly these.
- Lint moves to `plugins/userscript-lab/scripts/userscript-meta-lint.sh`. Part 2 references exactly this path.
- **No CDP anywhere in the new plugin:** zero occurrences of `chrome-devtools`, `chrome-lab`, `kapture`, `9222`, `evaluate_script`, `take_snapshot`, `--remote-debugging`, `PAGE_LAB_CHROME`.
- **The lost guarantee is stated, never implied:** both skills say verbatim: "No trusted-event or `document-start` proof is available on this rail: Claude in Chrome runs after load, in an untrusted context. Verify by installing in Violentmonkey and checking with Claude in Chrome; say which checks ran."
- On a Claude in Chrome per-site permission wall: **ask the operator**; never suggest another browser or CDP.
- No client / work-account literal in any file or commit message (public repo).
- No AI attribution in commits.

## Review Focus

1. **A userscript repo's CI that curls the old lint path** (`plugins/page-lab/scripts/userscript-meta-lint.sh`) breaks silently on the next run → Task 1 sweeps both forges and fixes each consumer.
2. **A skill still telling the agent to call a CDP tool** — the agent would attempt a server that no longer exists → Task 2's grep gate.
3. **`validate.yml` steps that run page-lab tests** fail once the dir is gone → Task 4.
4. **An installed-but-removed page-lab** stays cached in `~/.claude/plugins` after the marketplace drops it → Task 5 checks the installed list after update.
5. **gif-meme on a site that hides its file input** — `upload_image` / `file_upload` may not reach it → Task 3 runs one real upload and records the result in `upload-flows.md`.

---

### Task 0: Worktree

- [ ] **Step 1:** `git -C ~/Developer/github.com/kattakath/skills fetch origin && git -C ~/Developer/github.com/kattakath/skills worktree add "$S/skills-chrome" -b chrome-only origin/main` (`S` = a fresh `mktemp -d` under the session scratchpad). All later paths are relative to this worktree. The main checkout is 16 behind — never edit it.

### Task 1: Lint consumer sweep (before moving anything)

**Files:** none in this repo; edits land in each consumer repo found.

- [ ] **Step 1:** Find consumers on both forges:
  `gh search code 'userscript-meta-lint' --limit 100` and, for each GitLab project of the operator, `glab api "projects/<id>/search?scope=blobs&search=userscript-meta-lint"`. Also `grep -rl userscript-meta-lint ~/Developer` (local clones).
  Expected: a list of `repo path` lines. nix-config's three hits are handled in part 2.
- [ ] **Step 2:** For each non-nix-config consumer, record repo + file + the URL/path it uses in a scratch file; these change in Task 5 Step 3 (after the new path exists on `main`).

### Task 2: `userscript-lab` plugin

**Files:**
- Create: `plugins/userscript-lab/.claude-plugin/plugin.json` (`name: "userscript-lab"`, `version: "1.0.0"`, description: "Author Violentmonkey userscripts and redesign whole sites with a measure-first method, verified through Claude in Chrome. Includes the Greasy Fork readiness linter.")
- Create (git mv from `plugins/page-lab/`): `skills/userscript-author/` (SKILL.md + `references/{patterns,probes,gm-api,greasyfork}.md`), `skills/site-redesign/` (SKILL.md + `references/{keep-list,theming,topbar,relocation,hardening,overlays,rules}.md`), `scripts/userscript-meta-lint.sh`, `icon.png`, `README.md`.
- Delete with page-lab (Task 4): `site-redesign/references/{acceptance,survey}.md`, `skills/userscript-author/references/tools.md`, everything under `scripts/` except the lint, `references/*` (routes, facts, cdp-extras, pick-protocol, gate, report-format, supervised-driving, sites), `commands/`, `.mcp.json`, `tests/`.

**Interfaces:**
- Produces: skill ids `userscript-lab:userscript-author`, `userscript-lab:site-redesign`; lint at `plugins/userscript-lab/scripts/userscript-meta-lint.sh` (same CLI as before).

- [ ] **Step 1: Write the gate first** — `plugins/userscript-lab/tests/no-cdp.sh`: exits 1 and prints offending lines if `grep -rnE 'chrome-devtools|chrome-lab|kapture|9222|evaluate_script|take_snapshot|remote-debugging|PAGE_LAB_CHROME|\.\./\.\./references/' plugins/userscript-lab` matches anything; exits 1 if either SKILL.md lacks the Global Constraints guarantee sentence; exits 0 otherwise.
- [ ] **Step 2:** `bash plugins/userscript-lab/tests/no-cdp.sh` → Expected: FAIL (dir does not exist yet / no SKILL.md).
- [ ] **Step 3:** `git mv` the files listed above; write `plugin.json`.
- [ ] **Step 4:** Edit both SKILL.md files and their kept references:
  - Tool mapping: `evaluate_script` → `mcp__claude-in-chrome__javascript_tool`; `take_snapshot` → `read_page`; console → `read_console_messages`; network → `read_network_requests`; screenshots/proof → `computer` screenshot or `gif_creator`; page open → `tabs_create_mcp` + `navigate`.
  - Replace every "measure on the live page" CDP recipe with the Claude in Chrome equivalent; replace acceptance-runner steps with the guarantee sentence + "install in Violentmonkey (one-time 'Allow User Scripts' toggle on Chrome 138+), reload, check with `javascript_tool`".
  - Inline the few facts the skills still need from the deleted `../../references/*` (one or two lines each) rather than keeping those files.
  - Description frontmatter keeps the triggers ("make <site> do X", "write a userscript", "redesign <site>") and drops "diagnose live pages" (Claude in Chrome's own skill owns that).
- [ ] **Step 5:** `bash plugins/userscript-lab/tests/no-cdp.sh` → Expected: exit 0. `bash plugins/userscript-lab/scripts/userscript-meta-lint.sh <any .user.js in a local userscript repo>` → same output as the old path.
- [ ] **Step 6:** Commit: `userscript-lab: new plugin — userscript-author + site-redesign on Claude in Chrome, lint moved from page-lab`.

### Task 3: gif-meme off CDP

**Files:** Modify `plugins/gif-meme/skills/gif-meme/SKILL.md`, `references/upload-flows.md`, `plugins/gif-meme/README.md`, `.claude-plugin/plugin.json` (minor version bump).

- [ ] **Step 1:** Replace the "chrome-devtools MCP attached on 9222" prerequisite and every `lsof … 9222` / CDP upload step with Claude in Chrome: `tabs_create_mcp` → `navigate` to the upload page → `file_upload` (or `upload_image`) on the input `find` returns.
- [ ] **Step 2:** Run one real upload of a small test GIF to Tenor through Claude in Chrome. **Stop before the final publish click and ask the operator** (it is a public post). Record in `upload-flows.md`: whether the hidden input was reachable, which tool worked, date measured.
- [ ] **Step 3:** `grep -rnE '9222|chrome-devtools|page-lab' plugins/gif-meme` → Expected: no output. README dependency column for gif-meme: "Claude in Chrome".
- [ ] **Step 4:** Commit: `gif-meme: upload through Claude in Chrome, not CDP`.

### Task 4: Remove page-lab; CI, index, marketplace

**Files:** Delete `plugins/page-lab/`. Modify `.claude-plugin/marketplace.json` (remove `page-lab` entry ~line 455; add `userscript-lab` with `"source": "./plugins/userscript-lab"`), `README.md` (page-lab row → userscript-lab row; line 89's rulebook path), `CLAUDE.md` (line 102 mention), `.github/workflows/validate.yml` (lines 233–239 page-lab steps → one step `bash plugins/userscript-lab/tests/no-cdp.sh`), `INDEX.md` (regenerated).

- [ ] **Step 1:** `git rm -r plugins/page-lab` and make the edits above.
- [ ] **Step 2:** `python3 scripts/build-index.py` then `python3 scripts/build-index.py --check` → Expected: exit 0.
- [ ] **Step 3:** `python3 -I scripts/check-version-bump.py origin/main` and `python3 -I scripts/check-pins.py` → Expected: exit 0.
- [ ] **Step 4:** Run every remaining `validate.yml` `run:` step locally that touches changed plugins (marketplace validation, "Scripts parse") → Expected: pass.
- [ ] **Step 5:** `grep -rnI 'page-lab' --exclude-dir=.git .` → Expected: only history notes in `docs/` (or none). Re-run `no-cdp.sh`.
- [ ] **Step 6:** Commit: `page-lab: removed — replaced by userscript-lab; validate.yml, marketplace, index, README`.

### Task 5: Land

- [ ] **Step 1:** Leak gates: `gitleaks git --log-opts="origin/main..HEAD" --redact --no-banner` (via nix-config's `nix develop -c`), then the Drive `client-literals.txt` patterns over `git diff origin/main..HEAD` and `git log origin/main..HEAD --format=%B` → Expected: no findings.
- [ ] **Step 2:** `git fetch && git rebase origin/main && git push git@github.com:kattakath/skills.git HEAD:main` (SSH: `validate.yml` changed; the gh token lacks `workflow` scope). `ci-watch` reports only red.
- [ ] **Step 3:** Update each lint consumer from Task 1 to the new path (one commit + push per repo, leak gates first). For GitLab pushes, start a background `glab ci view`-style watcher (ci-watch is GitHub-only).
- [ ] **Step 4:** `claude plugin marketplace update kattakath`, then confirm `claude plugin list` shows `userscript-lab@kattakath` and no `page-lab@kattakath` (uninstall page-lab if it lingers). Part 2 may start once this holds.
