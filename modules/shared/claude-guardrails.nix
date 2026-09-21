{ pkgs, lib, ... }:
# The GLOBAL guardrail floor for Claude Code — user-scope `permissions.deny`
# that applies in EVERY repo on this Mac, not just this one.
#
# WHY THIS EXISTS. Every decision hook this fleet runs (`pretooluse-bash-guard`,
# `stop-gate`, the Write|Edit secret prompt, the mcpfinder deny) lives in THIS
# repo's `.claude/settings.json` — project scope. A session anywhere else (a work
# repo, `~`) got none of it, while the VS Code extension and the `claude`
# terminal profile start in `bypassPermissions` (home.nix). The MCP gateway, by
# contrast, IS global: `mcpfinder` is wired into every session through
# `programs.claude-code.mcpServers`, so its config-writing tool was deny-listed
# here and callable everywhere else. Measured 2026-09-15.
#
# UPSTREAM FIRST. `programs.claude-code.settings` is `jsonFormat.type`
# (home-manager efa3ccb, modules/programs/claude-code/options.nix) — freeform,
# so ANY settings.json key passes through untyped, and module-system list
# merging concatenates `permissions.deny` across modules, so this file ADDS to
# whatever else sets it. Its own example block shows `permissions.deny`. No
# hook, no script, no activation step: Claude Code enforces deny rules itself,
# in every permission mode — `bypassPermissions` skips PROMPTS, and a deny is
# not a prompt.
#
# NOT ONLY DENIES. `settings.attribution` below is the other half of the same
# floor: a policy that lived as prose in claude/CLAUDE.md and therefore had to
# be re-won every session against a harness default that asserts the opposite.
# A setting is won once. The SCOPE RULE below governs both halves.
#
# WHAT A DENY RULE IS NOT. Claude Code's docs are explicit that a Bash deny
# "isn't a security boundary around the program": it matches the command text
# Claude writes (compound commands and `$(…)` included) but not `/usr/bin/x` or
# `sh -c 'x'`. This is a FLOOR against the common, accidental shape — the
# project-scoped superhook guard stays the deeper, tested layer in this repo.
#
# THE TWO mcpfinder RULES ARE ALSO IN `.claude/settings.json`, ON PURPOSE — that
# is not duplication to clean up. This file is materialised by Home Manager into
# ~/.claude, which the devcontainer deliberately does NOT mount (.devcontainer/
# devcontainer.json: "No volume for ~/.claude (deliberate — don't re-add one)").
# Inside that container, and in any clone on a machine this HM config never
# touched, the checked-in project copy is the only floor there is.
#
# SCOPE RULE for adding an entry: it must be a FLEET-WIDE policy already written
# down somewhere (claude/CLAUDE.md, mcp-scout, CLAUDE.md § Security), and wrong
# in every repo. Repo-specific policy (Cloudflare scoping, nixpi builds) stays in
# that repo's `.claude/`. Escape hatch for the operator: run it yourself — a
# `!`-prefixed command in the prompt, or a normal terminal.
#
# Paths: `~/` anchors at $HOME and `//` at the filesystem root. A single leading
# `/` in USER settings anchors at ~/.claude, not `/` — the classic miswrite.
#
# Top-level `lib.mkIf isDarwin`, matching ./claude-brain.nix: programs.claude-code
# is darwin-only (home.nix), and the gate keeps nixpi/nixvm byte-identical.
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  # ── AI attribution on git artifacts: OFF, as a SETTING (claude/CLAUDE.md
  #    § Git authorship) ──────────────────────────────────────────────────────
  # That section forbids a `Co-Authored-By: Claude` trailer on commits and a
  # "Generated with Claude Code" footer on PR/issue bodies. Claude Code injects
  # a session-start reminder asserting the opposite and claiming to supersede
  # earlier guidance, so the prose rule was an argument the model had to win on
  # every session — and § Git authorship already records the recurring cost of
  # merely FLAGGING that conflict each time (2026-09-12). This states the same
  # policy where the harness reads it, instead of where a model must recall it.
  #
  # UPSTREAM FIRST: grepped the pinned home-manager (efa3ccb,
  # modules/programs/claude-code/options.nix) — there is NO typed
  # `programs.claude-code.settings.attribution` option, and none is needed:
  # `settings` is `inherit (jsonFormat) type`, so the attrs below reach
  # settings.json verbatim through `pkgs.formats.json`.
  #
  # VERIFIED AGAINST THE SCHEMA, not from memory — by this file's own standard
  # a key that matches nothing is not a weak setting but NO setting, and it
  # fails silently. `attribution` is a real top-level key in
  # json.schemastore.org/claude-code-settings.json, `additionalProperties:
  # false`, with exactly three sub-keys — `commit` (string), `pr` (string),
  # `sessionUrl` (boolean) — and it is documented at
  # code.claude.com/docs/en/settings-reference § Git and attribution. It landed
  # in claude-code 2.0.62; this fleet runs 2.1.260. Checked 2026-09-21. That
  # schema is not an outside opinion: home-manager stamps its URL into the
  # rendered file as `"$schema"`, so it is the contract this very settings.json
  # declares it satisfies.
  #
  # ALL THREE OR NOTHING. Upstream, verbatim: "Once you set `commit` or `pr`,
  # Claude Code ignores the deprecated `includeCoAuthoredBy` setting and uses
  # its default text for whichever of the two you left unset." So a lone
  # `commit = ""` does not merely leave the PR footer alone — it also REVIVES
  # that footer for anyone who was relying on `includeCoAuthoredBy = false`.
  # `sessionUrl` is a separate `Claude-Session` trailer emitted ONLY from a
  # cloud or Remote Control session, i.e. never visibly from this terminal,
  # which is exactly why it must be declared rather than noticed in a PR later.
  #
  # NOT `includeCoAuthoredBy = false`: deprecated since 2.0.62, blind to
  # `sessionUrl`, and ignored outright once `attribution` is set. It is also
  # the key the pinned home-manager's own `settings` EXAMPLE still shows — the
  # example is stale, the schema is not.
  programs.claude-code.settings.attribution = {
    commit = "";
    pr = "";
    sessionUrl = false;
  };

  programs.claude-code.settings.permissions.deny = [
    # ── Imperative MCP adoption (mcp-scout: "installation IS declaration") ──
    # The gateway is the single MCP source; a runtime add lands in ~/.claude.json,
    # outside flake.lock, Cachix and the public ⊆ hosted assertion (ADR-003 §5).
    # THE PREFIX IS THE WHOLE RULE. A deny naming a tool that does not exist is
    # not a weak guardrail, it is NO guardrail — and it fails silently, because
    # nothing reports a rule that never matches.
    #
    # Measured 2026-09-15 from a live session's own tool namespace: servers
    # arrive as `mcp__plugin_hm_<server>__<tool>`. The two spellings that lived
    # here before — a bare `mcp__mcpfinder__…` and an older, longer plugin prefix
    # — matched NOTHING, so imperative MCP adoption was ungated the whole time.
    # modules/shared/home.nix:660 in this same repo already had it right.
    #
    # To re-verify after any plugin/marketplace change, read a real tool name out
    # of a live session rather than reasoning about it; the prefix has changed
    # once already and will not announce the next change.
    #
    # THE TOOL-NAME HALF WAS DEAD TOO, and d39fc80 only fixed the prefix. Read
    # from a live session's namespace 2026-09-16: the pinned @mcpfinder/server
    # registers FOUR tools — browse_categories, get_install_config,
    # get_server_details, search_mcp_servers — and `add_mcp_server_config` is not
    # among them. So this deny named a tool that does not exist, which by this
    # file's own header is not a weak guardrail but NO guardrail; meanwhile
    # .claude/settings.json pre-approved the whole server by wildcard, sitting
    # wider than the thing nominally narrowing it.
    #
    # It is gone rather than re-spelled, because there is no write tool to name.
    # The narrowing now lives where it can actually hold: settings.json lists the
    # four read-only tools EXPLICITLY, so a write tool introduced by a future
    # version pin is not matched by anything and prompts instead of being
    # auto-approved. A deny cannot be written against a name nobody knows yet;
    # an allow-list does not need one.
    "Bash(claude mcp add *)"
    "Bash(claude mcp add-json *)"
    "Bash(claude mcp add-from-claude-desktop *)"
    "Edit(~/.claude.json)"

    # ── Secret VALUES reaching the transcript (claude/CLAUDE.md § Redact) ──
    # Mirrors Rule 1c of the project guard at floor strength. Using a secret is
    # still fine: `secret exec`, passwordCommand wrappers, launchd.
    "Bash(secret reveal *)"
    "Bash(security find-generic-password -w*)"
    "Bash(security find-generic-password * -w*)"
    "Bash(security find-internet-password -w*)"
    "Bash(security find-internet-password * -w*)"
    # Host-decrypted agenix plaintext on macos, and the two OpenTofu state dirs
    # that hold a tunnel connector token (+ an Access service-token secret) in
    # plaintext (CLAUDE.md § Important Notes). A Read deny also blocks Edit/Write.
    "Read(//run/agenix/**)"
    "Read(~/.local/state/nix-config-cf-tunnel/**)"
    "Read(~/.local/state/nix-config-mcp-public/**)"
    "Read(~/.aws/sso/cache/**)"
    # `agenix -d FILE` was the one shape in this family still open, and it is
    # the bluntest of them: it prints an age ciphertext's PLAINTEXT straight
    # into the transcript. Fleet-wide policy already forbids it in two places —
    # claude/CLAUDE.md § Redact names "`.age` plaintext" outright, and
    # CLAUDE.md § Security says "Never display a secret value" — and it is
    # wrong in every repo, so it belongs at this floor and not in a `.claude/`.
    # Verified against the PINNED agenix (ryantm/agenix b027ee2,
    # pkgs/agenix.sh): `-d|--decrypt` sets DECRYPT_ONLY and takes FILE, and the
    # dispatch line appends `-o -`, so the cleartext goes to stdout by
    # construction. `-i/--identity` may PRECEDE it, hence both flag positions —
    # the same reason `security find-generic-password` needs two entries above.
    # No space before `*`, so `-d*` also matches a bare `agenix -d`.
    "Bash(agenix -d*)"
    "Bash(agenix --decrypt*)"
    "Bash(agenix * -d*)"
    "Bash(agenix * --decrypt*)"
    # agenix is NOT on PATH — it exists only in this repo's devShell
    # (modules/parts/devshell.nix), so the one-shot spelling is a `nix develop
    # -c` away and the four rules above never see it. Claude Code strips a
    # FIXED wrapper list before matching (timeout/time/nice/nohup/stdbuf,
    # `command`/`builtin`, `noglob`, flagless `xargs`) and upstream states that
    # environment runners — `direnv exec`, `devbox run`, `mise exec`, `npx`,
    # `docker exec` — are deliberately NOT in it. `nix develop -c` is one of
    # those, so it needs its own pair rather than inheriting the plain ones.
    "Bash(nix develop * agenix -d*)"
    "Bash(nix develop * agenix --decrypt*)"
    # `age -d` matters MORE than `agenix -d`, on the same logic that made
    # `security find-generic-password -w` non-negotiable above: agenix is only
    # a wrapper, while `age` itself is brew-installed on this Mac
    # (hosts/macos.nix brews) and therefore on PATH in every repo, no devShell
    # required. `age --decrypt -i <key> <file>` prints the identical plaintext.
    "Bash(age -d*)"
    "Bash(age --decrypt*)"
    "Bash(age * -d*)"
    "Bash(age * --decrypt*)"
    # DELIBERATELY NOT COVERED, named so the gap is a decision and not a miss:
    #   · `agenix -e FILE` under `EDITOR=cat`. `-e` is the SANCTIONED editing
    #     path (CLAUDE.md § Security), so denying it breaks the documented
    #     workflow to buy back an evasion one env var reopens anyway.
    #   · `* agenix -d*` — a LEADING wildcard would cover every runner at once,
    #     and is rejected on measured cost: the project guard's Rule 1c matched
    #     a literal string anywhere rather than at command position and blocked
    #     its OWN commit message within a minute of being written, then blocked
    #     the fix. A deny rule has no command-position anchor to reach for.
    #   · `/opt/homebrew/bin/age -d`, `sh -c 'agenix -d …'`, and `nix run
    #     github:ryantm/agenix -- -d` — the by-path / by-subshell class the
    #     header already names as out of reach, plus a spelling this fleet has
    #     no reason to produce (agenix is a devShell package here, not an app).
    #   · The ciphertexts themselves. `secrets/*.age` is committed to a PUBLIC
    #     repo, so reading one leaks nothing; the value exists only after a
    #     decrypt, which is the verb these rules name. No `Read(secrets/**)`.
    # And NO catch-all `Read(**)`. A blanket Read deny disables Bash
    # auto-approve across the board — it trades one narrow leak for a
    # permanently noisier session everywhere, which is how a floor gets turned
    # off wholesale by an irritated operator. The four narrow `Read(...)` path
    # denies above are the shape that holds; a fifth broad one would undo them.

    # ── Irreversible remote actions an unattended agent must not take ──
    # A merge is a production trigger in more than one repo this Mac works on
    # (e.g. a `main` with no required reviewers). Review and merge stay human.
    "Bash(gh pr merge *)"
    # Both flag positions. `--force-with-lease` stays allowed on purpose: it is
    # the safe way to update an agent's own rebased PR branch, and protected
    # branches are already force-push-proof server-side (GitHub rulesets).
    "Bash(git push --force *)"
    "Bash(git push -f *)"
    "Bash(git push * --force)"
    "Bash(git push * -f)"
  ];
}
