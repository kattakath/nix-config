{ pkgs, lib, ... }:
# The GLOBAL guardrail floor for Claude Code — user-scope `permissions.deny`
# that applies in EVERY repo on this Mac, not just this one.
#
# WHY THIS EXISTS. Every decision hook this fleet runs (`pretooluse-bash-guard`,
# `stop-gate`, the Write|Edit secret prompt) lives in THIS repo's
# `.claude/settings.json` — project scope. A session anywhere else (a work
# repo, `~`) got none of it, while the VS Code extension and the `claude`
# terminal profile start in `bypassPermissions` (default.nix). The MCP gateway was
# the counter-example that forced the issue: it WAS global — `mcpfinder` reached
# every session through `programs.claude-code.mcpServers`, so its config-writing
# tool was deny-listed here and callable everywhere else. Measured 2026-09-15.
#
# THAT COUNTER-EXAMPLE IS GONE; THE REASON TO BE GLOBAL IS NOT. The gateway was
# purged 2026-10-01 — ./mcp.nix deleted, the Cloudflare portal destroyed, the
# terranix stack removed in #737 — so nothing global ships an MCP server any
# more: servers arrive ONLY as Claude Code plugins (./plugin-mcp.nix,
# ./gmail-mcp.nix), which are per-session and carry no fleet-wide write tool.
# The project-scope gap in the paragraph above is untouched by that, and it was
# always the load-bearing half: a session in a work repo still gets no hook.
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
# A RULE RESTATED IN `.claude/settings.json` IS NOT DUPLICATION TO CLEAN UP.
# This file is materialised by Home Manager into ~/.claude, which the
# devcontainer deliberately does NOT mount (.devcontainer/devcontainer.json: "No
# volume for ~/.claude (deliberate — don't re-add one)"). Inside that container,
# and in any clone on a machine this HM config never touched, the checked-in
# project copy is the only floor there is. (This paragraph used to name "the two
# mcpfinder rules" as the live example. There is no such pair any more: the
# mcpfinder deny was removed 2026-09-16 for naming a tool that does not exist —
# see the body below — and the project file's four mcpfinder ALLOW entries went
# with the portal. The reason survives its example.)
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
# is darwin-only (default.nix), and the gate keeps nixpi/nixvm byte-identical.
let
  # The secret-path COORDINATES, shared with the Seatbelt fence in ./plugin-mcp.nix
  # so the two layers cannot drift. See that file for why this is data rather than
  # a second copy of the rules, and why a match-based derivation was rejected.
  secretReadPaths = import ../_lib/secret-read-paths.nix;

  # `//` is Claude's ABSOLUTE spelling and `~/` its home-relative one; `/**`
  # makes it a subtree. A Read deny also blocks Edit and Write.
  secretReadDenies =
    map (p: "Read(/${p}/**)") secretReadPaths.absolute
    ++ map (p: "Read(~/${p}/**)") secretReadPaths.underHome;
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  # The ONE failure mode this file's own commentary names as worse than a weak
  # floor: a rule list that is well-formed and EMPTY, which nothing reports. The
  # paths now arrive from another file, so make the vacuum a BUILD error instead
  # of a silent one. Cheap, and it is the condition under which deriving these
  # rules is safe at all.
  assertions = [
    {
      assertion = secretReadDenies != [ ];
      message = "modules/_lib/secret-read-paths.nix yielded no Read denies — the secret-path floor in claude-guardrails.nix would be silently empty.";
    }
  ];

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
    # Servers arrive ONLY as Claude Code plugins now (./plugin-mcp.nix,
    # ./gmail-mcp.nix) — the gateway that used to be the single source is gone.
    # The rule is unchanged by that: a runtime add lands in ~/.claude.json,
    # outside flake.lock, Cachix and every check that can see a declared server.
    # THE PREFIX IS THE WHOLE RULE. A deny naming a tool that does not exist is
    # not a weak guardrail, it is NO guardrail — and it fails silently, because
    # nothing reports a rule that never matches.
    #
    # Measured 2026-09-15 from a live session's own tool namespace: servers then
    # arrived as `mcp__plugin_hm_<server>__<tool>`. The two spellings that lived
    # here before — a bare `mcp__mcpfinder__…` and an older, longer plugin prefix
    # — matched NOTHING, so imperative MCP adoption was ungated the whole time.
    # modules/home/default.nix:660 in this same repo already had it right.
    #
    # THAT PREFIX WENT STALE TWICE, exactly as this paragraph predicted. The
    # 2026-09-22 portal collapse made the gateway ONE Claude Code server
    # (`plugin:hm:kattakath-portal`) hosting every upstream, so its tools arrived
    # as `mcp__plugin_hm_kattakath-portal__<server>_<tool>` — the upstream name
    # moved INTO the tool half and lost its `__` separator. Then the 2026-10-01
    # purge deleted that server outright, so THAT spelling can never match again
    # either: it is absent from `claude mcp list`, checked 2026-10-02.
    #
    # TWO SHAPES ARE LEFT, both measured 2026-10-02 from a live session's own tool
    # namespace rather than reasoned about:
    #   plugin-owned  `mcp__plugin_<plugin>_<server>__<tool>` — e.g.
    #                 `mcp__plugin_context7_context7__query-docs`,
    #                 `mcp__plugin_claude-code-nix_nixos__nix`.
    #   claude.ai connector  `mcp__claude_ai_<Server>__<tool>`, the server's
    #                 DISPLAY name with spaces as underscores and its case kept —
    #                 `mcp__claude_ai_cloudflare__docs`. Not a plugin, not in Nix,
    #                 and so not declarable here; it is named because a capability
    #                 that left the gateway can land in this lane.
    #
    # .claude/settings.json carried 15 allow entries on the pre-collapse spelling
    # and matched nothing until #671 re-spelled them to the portal's — and the
    # purge then killed all 15 again. They are now rewritten to the live shapes
    # above where the capability survived and DELETED where it did not. Same
    # silent failure, same file next door, twice: an allow is as dead as a deny
    # when its prefix is, it just fails the other way — a prompt, not a hole.
    #
    # To re-verify after any plugin/marketplace change, read a real tool name out of
    # a live session rather than reasoning about it; the prefix has now changed THREE
    # times and has never announced it.
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
    # The narrowing lived in settings.json instead — the four read-only tools
    # listed EXPLICITLY, so a write tool introduced by a future version pin
    # matched no allow rule and prompted. A deny cannot be written against a name
    # nobody knows yet; an allow-list does not need one.
    #
    # THOSE FOUR WENT WITH THE PORTAL and are deliberately NOT re-spelled:
    # `mcpfinder` is absent from `claude mcp list` (2026-10-02), so its live
    # prefix cannot be READ from a session, and the paragraphs above forbid
    # writing one that was merely inferred. Losing an allow fails safe — every
    # mcpfinder tool now prompts — which is why the gap is acceptable where a
    # missing deny would not be. `nix-mcp-mcpfinder` is still on PATH
    # (packages/mcpfinder-mcp.nix) for the plugin that claims it; re-add the
    # explicit four under the MEASURED `mcp__plugin_<plugin>_mcpfinder__` prefix
    # once that plugin is live, not before.
    "Bash(claude mcp add *)"
    "Bash(claude mcp add-json *)"
    "Bash(claude mcp add-from-claude-desktop *)"
    "Edit(~/.claude.json)"

    # ── Secret VALUES reaching the transcript (claude/CLAUDE.md § Redact) ──
    # Mirrors Rule 1c of the project guard at floor strength. Using a secret is
    # still fine: `secret exec`, passwordCommand wrappers, launchd.
    #
    # EDIT THIS GROUP, EDIT IT TWICE. Every rule from here down to the end of the
    # `age` block is restated verbatim in modules/darwin/claude-managed-settings.nix
    # (root-owned managed scope, the tier above this one). Deriving one list from
    # the other by string match was rejected: it yields `[ ]` the moment a rule is
    # reworded — a well-formed, completely empty floor. That is the silent vacuum
    # the mcpfinder note above and the `attribution` note below both record: a
    # rule matching nothing is not a weak floor but NO floor, and nothing reports
    # it. Nothing checks these two lists agree either.
    "Bash(secret reveal *)"
    "Bash(security find-generic-password -w*)"
    "Bash(security find-generic-password * -w*)"
    "Bash(security find-internet-password -w*)"
    "Bash(security find-internet-password * -w*)"
    # Host-decrypted agenix plaintext on macos, and the two OpenTofu state dirs
    # that hold a tunnel connector token (+ an Access service-token secret) in
    # plaintext (CLAUDE.md § Important Notes). A Read deny also blocks Edit/Write.
    #
    # THE mcp-public ENTRY STAYS, and it is NOT leftover cleanup to finish. #737
    # deleted that stack's RENDERER, not the operator's state: nothing in Nix ever
    # created or removes ~/.local/state/nix-config-mcp-public, so a state file
    # written before the teardown can still be sitting there with an Access
    # service-token secret in it. A deny whose target file can still exist is
    # still load-bearing — the rule only dies when the FILE cannot exist, which is
    # the test the mcpfinder note above applies to a tool NAME. Delete it after
    # deleting the directory, in that order, never the reverse.
    #
    # THE PATHS MOVED OUT, THE RULES DID NOT. These four `Read(...)` globs are
    # now rendered from modules/_lib/secret-read-paths.nix, because a second
    # enforcement layer needs the same coordinates in a spelling a glob cannot
    # express: the macOS Seatbelt profile that fences desktop-commander
    # (./plugin-mcp.nix) wants `(subpath "/abs/path")`. Data with two renderers,
    # not two lists — and the `assertions` at the top of this file makes an empty
    # render a build error, which is the objection the group above raises about
    # its managed-settings twin. The RENDER also widened the agenix rule from one
    # spelling to four, because `/run` is a symlink on darwin and a `Read()` glob
    # does not resolve one; that file carries the measurement.
  ]
  ++ secretReadDenies
  ++ [
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
